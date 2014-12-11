package MT::ConvertDB::CLI;

use MT::ConvertDB::ToolSet;
use Term::ProgressBar 2.00;
use List::Util qw( reduce );
use List::MoreUtils qw( none part );
use MooX::Options;
use Term::Prompt qw( prompt );
use Sub::Quote qw( quote_sub );
use vars qw( $l4p );

has mode_handlers => (
    is      => 'ro',
    default => sub {
        {
            show_counts   => 'do_table_counts',
            # find_orphans  => 'do_find_orphans',
            check_meta    => 'do_check_meta',
            resave_source => 'do_resave_source',
            migrate       => 'do_migrate_verify',
            verify        => 'do_migrate_verify',
            test          => 'do_test',
        }
    }
);

option mode => (
    is      => 'ro',
    format  => 's',
    doc     => 'REQUIRED run mode: show-counts, resave-source, find-orphans, check-meta-types, migrate, verify, test',
    longdoc => '',
    coerce  => quote_sub(q( $_[0] =~ tr/-/_/; $_[0] )),
    default => 'init_only',
    required => 1,
);

option old_config => (
    is      => 'ro',
    format  => 's',
    doc     => 'Path to config file for current database. Can be relative to MT_HOME',
    longdoc => '',
    default => './mt-config.cgi',
);

option new_config => (
    is       => 'ro',
    format   => 's',
    required => 1,
    doc      => 'REQUIRED: Path to config file for new database. Can be relative to MT_HOME',
    longdoc  => '',
);

option classes => (
    is        => 'ro',
    format    => 's@',
    autosplit => ',',
    default   => sub { [] },
    doc       => 'Classes to include. Can be comma-delimited or specified multiple times',
    longdoc   => '',
);

option skip_classes => (
    is        => 'ro',
    format    => 's@',
    autosplit => ',',
    default   => sub { [] },
    doc       => 'Classes to skip (e.g. MT::Log). Can be comma-delimited or specified multiple times',
    longdoc   => '',
);

option skip_tables => (
    is        => 'ro',
    format    => 's@',
    autosplit => ',',
    default   => sub { [] },
    doc       => 'Tables to skip (without the "mt_" prefix, e.g. log ). Can be comma-delimited or specified multiple times',
    longdoc   => '',
);

option dry_run => (
    is      => 'rw',
    doc     => 'DEBUG: Marks new database as read-only for testing during migrate mode',
    longdoc => '',
    default => 0,
);

option no_verify => (
    is      => 'ro',
    doc     => 'Skip verification of data. Only valid with migrate mode',
    longdoc => '',
    default => 0,
);

option migrate_unknown => (
    is      => 'ro',
    doc     => 'Migrate all unknown metadata. Only valid under check_meta mode',
    longdoc => '',
    default => 0,
);

option remove_orphans => (
    is      => 'ro',
    doc     => 'Remove found orphans. Only valid under check_meta mode',
    longdoc => '',
    default => 0,
);

option remove_obsolete => (
    is      => 'ro',
    doc     => 'Remove obsolete metadata as defined by the RetiredFields plugin. Only valid under check_meta mode',
    longdoc => '',
    default => 0,
);

has classmgr => ( is => 'lazy', );

has cfgmgr => ( is => 'lazy', );

has class_objects => ( is => 'lazy', );

has progressbar => (
    is        => 'lazy',
    predicate => 1,
);

has total_objects => (
    is        => 'rw',
    predicate => 1,
    default   => 0,
);

has table_counts => (
    is        => 'lazy',
    clearer   => 1,
    predicate => 1,
);

sub _build_classmgr {
    my $self  = shift;
    my %param = ();
    $param{include_classes} = $self->classes      if @{ $self->classes };
    $param{exclude_classes} = $self->skip_classes if @{ $self->skip_classes };
    $param{exclude_tables}  = $self->skip_tables  if @{ $self->skip_tables };
    use_module('MT::ConvertDB::ClassMgr')->new(%param);
}

sub _build_cfgmgr {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    my %param = (
        read_only => ( $self->dry_run ? 1 : 0 ),
        new       => $self->new_config,
        old       => $self->old_config,
    );
    use_module('MT::ConvertDB::ConfigMgr')->new(%param);
}

sub _build_class_objects {
    my $self = shift;
    [
        grep { !( $_->class->datasource ~~ $self->skip_tables ) }
        grep { !( $_->class ~~ $self->skip_classes ) }
                @{ $self->classmgr->class_objects() }
    ];
}

sub _build_progressbar {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    $self->table_counts() unless $self->has_table_counts;

    my $p = Term::ProgressBar->new(
        {   name  => 'Progress',
            count => $self->total_objects,
            ETA   => 'linear'
        }
    );
    $p->max_update_rate(1);
    $p->minor(0);
    ###l4p $l4p->info(sprintf('Initialized progress bar with %d objects: ',
    ###l4p              $self->total_objects), l4mtdump($p));
    $p;
}

sub _build_table_counts {
    my $self       = shift;
    my $cfgmgr     = $self->cfgmgr;
    my $classmgr   = $self->classmgr;
    my $class_objs = $self->class_objects;

    my $total = 0;
    my $cnts  = {};
    for my $which (qw( old new )) {
        my $db = $which eq 'old' ? $cfgmgr->olddb : $cfgmgr->newdb;
        foreach my $classobj (@$class_objs) {
            my $ds = $classobj->class->datasource;
            unless ( $cnts->{$ds}{$which} ) {
                $cnts->{$ds}{$which} = $db->table_counts($classobj);
                $total += $cnts->{$ds}{$which}{total};
            }
        }
    }
    $self->total_objects($total);
    $cnts;
}

sub run {
    my $self       = shift;
    my $cfgmgr     = $self->cfgmgr;
    my $classmgr   = $self->classmgr;
    my $class_objs = $self->class_objects;
    ###l4p $l4p ||= get_logger();

    $self->dry_run(1) unless $self->mode eq 'migrate';

    try {
        local $SIG{__WARN__} = sub { $l4p->warn( $_[0] ) };

        if ( $self->mode eq 'init_only' ) {
            $self->progress( 'Class initialization done for '
                    . $self->total_objects
                    . ' objects. '
                    . 'Exiting without --mode' );
            p($self);
        }
        else {
            my $handle   = $self->mode_handlers;
            my $methname = $handle->{$self->mode}
                or die "Unknown mode: ".$self->mode;
            my $meth = $self->can($methname);
            $self->$meth();
        }
        $self->progress('Script complete. All went well.');
    }
    catch {
        $l4p->error("An error occurred: $_");
        exit 1;
    };
}

sub do_table_counts {
    my $self = shift;
    $self->clear_table_counts();
    my $cnt = $self->table_counts;

    use Text::Table;
    my $tb = Text::Table->new(
        "Data source",
        "Status",
        "Total Old",
        "Total New",
        "Obj Old",
        "Obj New",
        "Meta Old",
        "Meta New"
    );
    foreach my $ds ( sort keys $cnt ) {
        my $old = $cnt->{$ds}{old};
        my $new = $cnt->{$ds}{new};
        my @data;
        my $mismatch = 0;
        foreach my $type (qw( total object meta )) {
            $_->{$type} //= 0 foreach ( $old, $new );
            $mismatch++ if $old->{$type} != $new->{$type};
            push( @data, $old->{$type}, $new->{$type} );
        }
        $tb->add( "mt_$ds", ( $mismatch ? 'NOT OK' : 'OK' ), @data );
    }
    $self->progress("Table counts:\n$tb");
    return $cnt;
}

sub do_check_meta {
    my $self       = shift;
    my $cfgmgr     = $self->cfgmgr;
    my $classmgr   = $self->classmgr;
    my $class_objs = $self->class_objects;
    ###l4p $l4p ||= get_logger();
    require MT::Meta;

    my ( %counts, %badmeta );

    foreach my $classobj (@$class_objs) {
        my $class = $classobj->class;
        my @isa   = try { no strict 'refs'; @{$class.'::ISA'} };
        next unless grep { $_ eq 'MT::Object' } @isa;

        # Reset object drivers for class and metaclass
        $cfgmgr->use_old_database;
        $classobj->reset_object_drivers();

        next unless MT::Meta->has_own_metadata_of($class);

        my %arg = $self->_create_check_meta_args(
            classobj => $classobj,
            counts   => \%counts,
            badmeta  => \%badmeta
        );

        $self->progress("Checking $class metadata...");

        try {
            $self->_do_check_unknown(\%arg);
            $self->_do_check_orphans(\%arg);
        }
        catch { $l4p->error($_); exit };

        $self->_do_remove_orphans(\%arg) if $self->remove_orphans;

        if ( $self->migrate_unknown ) {
            $self->_do_migrate_unknown(\%arg);
        }
        else {
            $self->_do_remove_obsolete(\%arg) if $self->remove_obsolete;
            $self->_do_remove_unused(\%arg)   if $self->remove_unused;
        }
    }
    p(%counts);

    say "Orphaned metadata fields:";
    delete $badmeta{$_}{type}
        for grep { ! @{$badmeta{$_}{type}} } keys %badmeta;
    delete $badmeta{$_}{parent}
        for grep { ! @{$badmeta{$_}{parent}} } keys %badmeta;
    delete $badmeta{$_}
        for grep { ! %{ $badmeta{$_} } } keys %badmeta;
    p(%badmeta);
}

sub do_test {
    my $self       = shift;
    my $cfgmgr     = $self->cfgmgr;
    my $classmgr   = $self->classmgr;
    my $class_objs = $self->class_objects;
    ###l4p $l4p ||= get_logger();

=pod

    use DBIx::Compare;

    say "Instantiation....";
    my $oDB_Comparison = db_comparison->new(
        $cfgmgr->olddb->driver->dbh,
        $cfgmgr->newdb->driver->dbh,
    );

    say "Verbose...";
    $oDB_Comparison->verbose;

    say "Comparing.";
    $oDB_Comparison->compare;

    say "Deep comparing.";
    $oDB_Comparison->deep_compare;

    # $oDB_Comparison->deep_compare(@aTable_Names);
    exit;
    p( MT::Meta->metadata_by_class('MT::Website') );
    p( MT::Meta->has_own_metadata_of('MT::Website') );
    p( MT::Website->meta_pkg->properties );
    my @sites = MT->model('blog:meta')->load();
    p(@sites);
    exit;

    # foreach my $c ( @$class_objs ) {
    #
    # }

   my @entries = MT::Entry->load(undef, {
        'join' => MT::Comment->join_on( 'entry_id',
                    { blog_id => $blog_id },
                    { 'sort' => 'created_on',
                      direction => 'descend',
                      unique => 1,
                      limit => 10 } )
    });
=cut

}

sub do_resave_source {
    my $self       = shift;
    my $cfgmgr     = $self->cfgmgr;
    my $classmgr   = $self->classmgr;
    my $class_objs = $self->class_objects;
    ###l4p $l4p ||= get_logger();

    my $count       = 0;
    my $next_update = $self->progressbar->update(0);

    ###l4p $self->progress('Resaving '.$self->total_objects.' source objects.');

    $cfgmgr->old_config->read_only(0);

    foreach my $classobj (@$class_objs) {
        my $class = $classobj->class;

        # Reset object drivers for class and metaclass
        undef $class->properties->{driver};
        try { undef $class->meta_pkg->properties->{driver} };

        ###l4p $self->progress(sprintf('Resaving %s objects', $class ));
        my $iter = $cfgmgr->olddb->load_iter($classobj);
        while ( my $obj = $iter->() ) {

            my $meta = $cfgmgr->olddb->load_meta( $classobj, $obj );

            $cfgmgr->olddb->save( $classobj, $obj, $meta )
                or die "Could not save "
                . $obj->type
                . " object: "
                . $obj->errstr;

            $count += 1 + scalar( keys %$meta );
            $next_update = $self->progressbar->update($count)
                if $count >= $next_update;    # efficiency
        }
    }
    $cfgmgr->old_config->read_only(1);

    $self->progress('Resaved all objects!');

    $self->progressbar->update( $self->total_objects );
}

sub do_migrate_verify {
    my $self       = shift;
    my $cfgmgr     = $self->cfgmgr;
    my $classmgr   = $self->classmgr;
    my $class_objs = $self->class_objects;
    ###l4p $l4p ||= get_logger();

    if ( $self->mode eq 'migrate' ) {
        ###l4p $l4p->info( "Removing all rows from tables in new database" );
        $cfgmgr->newdb->remove_all($_) foreach @$class_objs;
        $self->do_table_counts();
    }

    my $count       = 0;
    my $next_update = $self->progressbar->update(0);

    foreach my $classobj (@$class_objs) {
        my $class = $classobj->class;

        ###l4p $self->progress(sprintf('%s %s objects',
        ###l4p     ($self->mode eq 'migrate' ? 'Migrating' : 'Verifying'), $class ));
        my $iter = $cfgmgr->olddb->load_iter($classobj);
        while ( my $obj = $iter->() ) {

            unless ( defined($obj) ) {
                $l4p->error( $class . " object not defined!" );
                next;
            }

            my $meta = $cfgmgr->olddb->load_meta( $classobj, $obj );

            $cfgmgr->newdb->save( $classobj, $obj, $meta )
                if $self->mode eq 'migrate';

            $self->verify_migration( $classobj, $obj, $meta )
                if $self->mode eq 'verify' or ! $self->no_verify;

            $count += 1 + scalar( keys %$meta );
            $next_update = $self->progressbar->update($count)
                if $count >= $next_update;    # efficiency

            $cfgmgr->use_old_database();
        }

        $cfgmgr->post_migrate_class($classobj) unless $self->dry_run;
    }
    $cfgmgr->post_migrate($classmgr) unless $self->dry_run;
    $self->progress("Processing of ALL OBJECTS complete.");

    $self->verify_record_counts()
        if $self->mode eq 'verify' or ! $self->no_verify;

    $self->progressbar->update( $self->total_objects );
}

sub verify_migration {
    my $self = shift;
    my ( $classobj, $obj, $oldmeta ) = @_;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->debug('Reloading record from new DB for comparison');
    my $cfgmgr = $self->cfgmgr;
    my $newobj = try { $cfgmgr->newdb->load_object( $classobj, $obj ) }
    catch { $l4p->error( $_, l4mtdump( $obj->properties ) ) };

    my $newmeta = $cfgmgr->newdb->load_meta( $classobj, $newobj );

    $classobj->object_diff(
        objects => [ $obj,     $newobj ],
        meta    => [ $oldmeta, $newmeta ],
    );
}

sub verify_record_counts {
    my $self       = shift;
    my $cfgmgr     = $self->cfgmgr;
    my $class_objs = $self->class_objects;
    ###l4p $l4p ||= get_logger();

    my $cnts = $self->do_table_counts();

    foreach my $ds ( keys %$cnts ) {
        my ( $old, $new ) = map { $cnts->{$ds}{$_}{total} } qw( old new );
        if ( $old == $new ) {
            $self->progress("Object counts match for $ds ");
        }
        else {
            ( $l4p ||= get_logger )
                ->error( sprintf( 'Object count mismatch for %s ', $ds ),
                l4mtdump( $cnts->{$ds} ) );
        }
    }
}

sub _do_check_unknown {
    my ($self, $arg) = @_;
    my $class = $arg->{class};
    ###l4p $l4p ||= get_logger();
    my $sql   = " SELECT ". $arg->{mtype}.", count(*) "
              . " FROM " . $arg->{mtable}
              . " GROUP BY ".$arg->{mtype};
    my $rows  = $arg->{dbh}->selectall_arrayref($sql);
    my $mcols = $arg->{classobj}->metacolumns;
    foreach my $row ( @$rows ) {
        my ( $type, $cnt ) = @$row;
        $arg->{counts}{$class}{total} += $cnt;

        unless ( grep { $_->{name} eq $type } @$mcols ) {
            ###l4p $l4p->error( "Found $cnt $class meta records "
            ###l4p            . "of unknown type '$type'" );
            $arg->{counts}{$class}{bad_type} += $cnt;
            push(@{ $arg->{badmeta}{$class}{type} }, $type );
        }
    }
}

sub _do_check_orphans {
    my ($self, $arg) = @_;
    my ($class, $mpk, $mtable)  = map { $arg->{$_} } qw( class mpk mtable );
    my $sql  = "SELECT $mpk, count(*) FROM $mtable GROUP BY $mpk";
    my $rows = $arg->{dbh}->selectall_arrayref($sql);
    foreach my $row ( @$rows ) {
        my ( $obj_id, $cnt ) = @$row;
        unless ( $class->exist({ $arg->{pk} => $obj_id }) ) {
            ###l4p $l4p->error( "Found $cnt $class meta records "
            ###l4p    . "with non-existent parent ID $obj_id" );
            $arg->{counts}{$class}{bad_parent} += $cnt;
            push(@{ $arg->{badmeta}{$class}{parent} }, $obj_id );
        }
    }
}

sub _do_remove_orphans {
    my ($self, $arg) = @_;
    my $class        = $arg->{class};
    my $mpkg         = $arg->{mpkg};
    my $parent_ids   = $arg->{badmeta}{$class}{parent} || [];
    ###l4p $l4p ||= get_logger();
    return unless @$parent_ids;

    my $msg = 'Are you sure you want to remove '.$arg->{mtable} .' rows with '
            . 'non-existent parents? (This is destructive and '
            . 'non-reversible!)';
    return unless prompt('y', $msg, 'y/n', 'n');

    $self->progress("Removing orphaned metadata for $class... "
        .p( $parent_ids ));

    my $id  = $class->datasource . '_id';
    $self->_do_direct_remove( $arg, { $id => $parent_ids } );
}

sub _do_migrate_unknown {
    my ($self, $arg) = @_;
    state $rf        = MT->component('RetiredFields');
    state $obsolete  = $rf->registry('obsolete_meta_fields');
    state $unused    = $rf->registry('unused_meta_fields');
    my $class        = $arg->{class};
    my $mtable       = $arg->{mtable};
    my $ds           = $arg->{ds};
    my $mcols        = $arg->{classobj}->metacolumns;
    my $olddb         = $arg->{mpkg}->driver;
    ###l4p $l4p ||= get_logger();

    my @unknown = map { @{ $_->{$ds} || [] } } $unused, $obsolete;
    p(@unknown);

    require SQL::Abstract;
    my $sql = SQL::Abstract->new();

    # Reset object drivers for class and metaclass
    $self->cfgmgr->use_new_database;
    $arg->{classobj}->reset_object_drivers();
    my $newdb = $arg->{mpkg}->driver;
    $self->cfgmgr->use_old_database;

    foreach my $unknown ( @unknown ) {
        next if grep { $unknown eq $_->{name} } @$mcols;
        my( $select, @sbind )
            = $sql->select( $mtable, ['*'], {$arg->{mtype} => $unknown} );
        say $select.' '.p(@sbind);

        my ($insert, $isth);
        my $ssth = $olddb->rw_handle->prepare($select);
        $ssth->execute(@sbind);
        while ( my $d = $ssth->fetchrow_hashref ) {
            $insert ||= $sql->insert($mtable, $d);
            $isth   ||= $newdb->rw_handle->prepare($insert);
            say $insert.' '.p($sql->values($d));
            $isth->execute($sql->values($d));
        }
    }

    $self->cfgmgr->use_old_database;
}

sub _do_remove_obsolete {
    my ($self, $arg) = @_;
    state $rf        = MT->component('RetiredFields');
    state $obsolete  = $rf->registry('obsolete_meta_fields');
    state $unused    = $rf->registry('unused_meta_fields');
    my $class  = $arg->{class};
    my $mtable = $arg->{mtable};
    my $meta_types = $obsolete->{$arg->{ds}};
    ###l4p $l4p ||= get_logger();

    return unless @{ $arg->{badmeta}{$class}{type} }
               && try { @{$arg->{meta_types}} };

    my $msg = "Are you sure you want to remove $mtable rows with the fields "
            . "above which RetiredFields says are obsolete? (This is "
            . "destructive and non-reversible!)";
    p($meta_types);
    return unless prompt('y', $msg, 'y/n', 'n');

    my $is_unknown = sub {
        my $v = shift;
        none { $v eq $_ } @$meta_types ? 1 : 0;
    };

    my ( $obsoletes, $unhandled )
        = part { $is_unknown->($_) } @{ $arg->{badmeta}{$class}{type} };

    if ( $obsoletes && @$obsoletes ) {
        $self->progress("Removing obsolete metadata fields for $class...");
        p( $obsoletes );
        $self->_do_direct_remove( $arg, { type => $obsoletes } );
    }

    if ( $unhandled && @$unhandled ) {
        $self->progress('Not removing the following fields which '
              . 'were not specified by the RetiredFields plugin: '
              . (join(', ', @$unhandled)));
    }
}

sub _do_direct_remove {
    my ( $self, $arg, $terms ) = @_;
    my $mpkg = $arg->{mpkg};
    ###l4p $l4p ||= get_logger();
    try   { $mpkg->driver->direct_remove( $mpkg, $terms ) }
    catch { $l4p->error($_); exit };
}

sub _create_check_meta_args {
    my ($self, %arg) = @_;
    my $class = $arg{class} = $arg{classobj}->class;
    my $mpkg  = $arg{mpkg} = $class->meta_pkg;
    my $mds   = $arg{mds} = $mpkg->datasource;
    %arg   = (
        %arg,
        ds     => $class->datasource,
        pk     => $class->properties->{primary_key},
        dbh    => $mpkg->driver->rw_handle,
        mtable => "mt_${mds}",
        mtype  => "${mds}_type",
    );
    $arg{mpk} = join('_', @arg{'mds','ds','pk'});
    $arg{badmeta}{$class}{$_} = [] foreach qw( type parent );
    $arg{counts}{$class}{$_}   = 0 foreach qw( total bad_type bad_parent );
    local $arg{dbh}{RaiseError}       = 1;
    local $arg{dbh}{FetchHashKeyName} = 'NAME_lc'; # lc($colnames)
    return %arg;
}

sub progress {
    my $self = shift;
    my $msg  = shift;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->info($msg);
    if ( $self->has_progressbar ) {
        my $p = $self->progressbar;
        $p->message($msg);
    }
    else {
        say $msg;
    }
}

1;

