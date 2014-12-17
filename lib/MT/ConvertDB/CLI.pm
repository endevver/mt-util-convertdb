package MT::ConvertDB::CLI;

use MT::ConvertDB::ToolSet;
use Term::ProgressBar 2.00;
use List::Util qw( reduce );
use List::MoreUtils qw( none part );
use Term::Prompt qw( prompt );
use Sub::Quote qw( quote_sub );
use Pod::Usage qw( pod2usage );

use Pod::POM;
my ( @POD_EXTRACT, %MooXOptions, $parser, $pom );
BEGIN {
    @POD_EXTRACT = qw( name synopsis description );
    $parser      = Pod::POM->new;
    $pom         = $parser->parse(__FILE__) or die $parser->error();
    for my $head1 ( $pom->head1 ) {
        my $label = lc($head1->title);
        next unless grep { $label eq $_ } @POD_EXTRACT;
        $MooXOptions{$label} = $head1->content;
    }
    # $MooXOptions{flavour} = [qw( pass_through )];
}
use MooX::Options ( %MooXOptions );
use vars qw( $l4p );

has mode_handlers => (
    is      => 'ro',
    default => sub {
        {
            showcounts   => 'do_table_counts',
            checkmeta    => 'do_check_meta',
            resavesource => 'do_resave_source',
            migrate      => 'do_migrate_verify',
            verify       => 'do_migrate_verify',
            test         => 'do_test',
            fullmigrate  => 'do_full_migrate_verify'
        }
    },
);

option mode => (
    is       => 'ro',
    format   => 's',
    doc      => '[REQUIRED] Run mode: show_counts, resave_source, check_meta, migrate or verify.',
    long_doc => q([REQUIRED] Run modes. See the L</MODES> section for the list of valid values.),
    coerce   => quote_sub(q( ($_[0] = lc($_[0])) =~ s/[^a-z]//g; $_[0]  )),
    default  => 'initonly',
    required => 1,
    order    => 1,
);

option new_config => (
    is       => 'ro',
    format   => 's',
    required => 1,
    doc      => '[REQUIRED] Path to config file for new database. Can be relative to MT_HOME',
    long_doc => q([REQUIRED] Use this option to specify the path/filename of the MT config file containing the new database information.  It can be an absolute path or relative to MT_HOME (e.g. ./mt-config-new.cgi)),
    order    => 2,
);

option old_config => (
    is       => 'ro',
    format   => 's',
    doc      => 'Path to current config file. Can be relative to MT_HOME. Defaults to ./mt-config.cgi',
    long_doc => q(Use this to specify the path/filename of the current MT config file.  It defaults to ./mt-config-cgi so you only need to use it if you want to set specific configuration directives which are different than the ones in use in the MT installation.),
    default  => './mt-config.cgi',
    order    => 3,
);

option classes => (
    is        => 'ro',
    format    => 's@',
    autosplit => ',',
    default   => sub { [] },
    doc       => 'Classes to include (e.g. MT::Blog). Can be comma-delimited or specified multiple times',
    long_doc  => q(
Use this to specify one or more classes you want to act on in the specified
mode. The value can be comma-delimited or you can specify this option multiple
times for multiple classes. For example, the following are equivalent:

    --classes MT::Blog --classes MT::Author --classes MT::Entry
    --classes MT::Blog,MT::Author,MT::Entry

This is useful if you want to execute a particular mode on a single table or a small handful of tables. For example:

    --mode migrate --class MT::Blog
    --mode showcounts --class MT::Blog
    --mode checkmeta --classes MT::Blog,MT::Author,MT::Entry),
    order     => 4,
);

option skip_classes => (
    is        => 'ro',
    format    => 's@',
    autosplit => ',',
    default   => sub { [] },
    doc       => 'Classes to skip (e.g. MT::Log). Can be comma-delimited or specified multiple times',
    long_doc  => q(Use this to specify one or more classes to exclude during execution of the specified mode. This
is the exact inverse of C<--classes>, has the same syntax and is most useful for excluding one
or a small handful of classes.

    --skip-classes MT::Log,MT::Log::Entry,MT::Log::Comment[,...]
    ),
    order     => 5,
);

option skip_tables => (
    is        => 'ro',
    format    => 's@',
    autosplit => ',',
    default   => sub { [] },
    doc       => 'Tables to skip (omit "mt_" prefix: log). Can be comma-delimited or specified multiple times',
    long_doc  => q(Use this to specify one or more tables to exclude during execution of the specified mode. This
is similar to C<--skip_classes> but often shorter and more likely what you want. For example,
the following skips the entire mt_log table and is equivalent to the example above. Note that
you omit the C<mt_> prefix of the table:

    --skip-table log

It is recommended that you always use this option (especially with with B<migrate> or B<verify>
modes) unless you need to preserve your Activity log data:

    --mode migrate --skip-table log
    --mode verify --skip-table log
    --mode showcounts --skip-table log
    ),
    order     => 6,
);

option no_verify => (
    is       => 'ro',
    doc      => '[WITH MODE: migrate] Skip data verification during migration.',
    long_doc => q(Under B<migrate> mode, this option skips the content and encoding verification for each object
migrated to the source database. This is useful if you want to quickly perform a migration and
are confident of the process or plan on verifying later.),

    default  => 0,
    order    => 7,
);

option migrate_unknown => (
    is       => 'ro',
    doc      => '[WITH MODE: checkmeta] Migrate all unknown metadata.',
    long_doc => q(Under B<checkmeta> mode, this option cause all metadata records with unregistered field types to be migrated.  This normally doesn't happen under B<migrate> mode which only transfers object metadata with registered field types.'),
    default  => 0,
    order    => 8,
);

option remove_orphans => (
    is       => 'ro',
    doc      => '[WITH MODE: checkmeta] Remove found orphans.',
    long_doc => q(Under B<checkmeta> mode, this removes all metadata records from the source database which are associated with a non-existent object.),
    default  => 0,
    order    => 9,
);

option remove_obsolete => (
    is      => 'ro',
    doc     => 'hidden',
    default => 0,
);

option remove_unused => (
    is      => 'ro',
    doc     => 'hidden',
    default => 0,
);

option dry_run => (
    is       => 'rw',
    doc      => 'DEBUG: Marks new database as read-only for testing during migrate mode',
    long_doc => q(A debugging option which marks the target database as read-only),
    default  => 0,
    order    => 12,
);

option readme => (
    is       => 'ro',
    format   => 's',
    doc      => 'hidden',
    default  => 0,
    order    => 13,
);

has [qw( classmgr cfgmgr class_objects )] => ( is => 'lazy', );

has progressbar => (
    is        => 'lazy',
    predicate => 1,
);

has ds_ignore => (
    is        => 'ro',
    default   => sub { qr{^(fileinfo|log|touch|trackback|ts_.*)$} },
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
            my $ds = $classobj->ds;
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

        if ( $self->mode eq 'initonly' ) {
            $self->progress( 'Class initialization done for '
                    . $self->total_objects
                    . ' objects. '
                    . 'Exiting without --mode. '
                    . 'Use --usage, --help or --man flags '
                    . 'for more information' );
            ###l4p $l4p->debug('CLI object: ', l4mtdump($self));
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
        "Table",
        "Status",
        "Old",
        "New",
        "Obj-Old",
        "Obj-New",
        "Meta-Old",
        "Meta-New"
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
        if ( $ds =~ $self->ds_ignore ) {
            $mismatch = 'IGNORE';
        }
        else {
            $mismatch = ( $mismatch ? 'NOT OK' : 'OK' );
        }
        $tb->add( "mt_$ds", $mismatch, @data );
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

        my $arg = $self->_create_check_meta_args({
            classobj => $classobj,
            counts   => \%counts,
            badmeta  => \%badmeta,
        });
        $arg->{dbh}{RaiseError}       = 1;
        $arg->{dbh}{FetchHashKeyName} = 'NAME_lc'; # lc($colnames)

        $self->progress("Checking $class metadata...");

        try {
            $self->_do_check_unknown($arg);
            $self->_do_check_orphans($arg);
        }
        catch { $l4p->error($_); exit };

        $self->_do_remove_orphans($arg) if $self->remove_orphans;

        if ( $self->migrate_unknown ) {
            $self->_do_migrate_unknown($arg);
        }
        else {
            $self->_do_remove_obsolete($arg) if $self->remove_obsolete;
            $self->_do_remove_unused($arg)   if $self->remove_unused;
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
        elsif ( $ds =~ $self->ds_ignore ) {
            $self->progress("Object counts don't match for $ds (Ignore. Drift data) ");
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
    my $classobj = $arg->{classobj};
    my $class    = $arg->{class};
    ###l4p $l4p ||= get_logger();
    my $mtype = $classobj->mds.'_type';
    my $sql   = " SELECT $mtype, count(*) "
              . " FROM " . $classobj->mtable
              . " GROUP BY $mtype";
    my $rows  = $arg->{dbh}->selectall_arrayref($sql);
    my $mcols = $classobj->metacolumns;
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
    my ($class, $mtable) = map { $arg->{$_} } qw( class mtable );
    my $pk   = $class->properties->{primary_key};
    my $mpk  = join('_', @{$arg}{'mds','ds'}, $pk);
    my $sql  = "SELECT $mpk, count(*) FROM $mtable GROUP BY $mpk";
    my $rows = $arg->{dbh}->selectall_arrayref($sql);

    foreach my $row ( @$rows ) {
        my ( $obj_id, $cnt ) = @$row;
        unless ( $class->exist({ $pk => $obj_id }) ) {
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
    ###l4p $l4p->debug('Migrating unregistered meta fields: ', l4mtdump(@unknown));

    require SQL::Abstract;
    my $sql = SQL::Abstract->new();

    # Reset object drivers for class and metaclass
    $self->cfgmgr->use_new_database;
    $arg->{classobj}->reset_object_drivers();
    my $newdb = $arg->{mpkg}->driver;

    $self->cfgmgr->use_old_database;
    foreach my $unknown ( @unknown ) {
        next if grep { $unknown eq $_->{name} } @$mcols;
        my( $select, @sbind ) = $sql->select(
            $mtable,
            ['*'],
            { $arg->{mds}.'_type' => $unknown }
        );
        ###l4p $l4p->debug( $select.' '.p(@sbind) );

        my ($insert, $isth);
        my $ssth = $olddb->rw_handle->prepare($select);
        $ssth->execute(@sbind);
        while ( my $d = $ssth->fetchrow_hashref ) {
            $insert ||= $sql->insert($mtable, $d);
            $isth   ||= $newdb->rw_handle->prepare($insert);
            ###l4p $l4p->info( $insert.' '.p($sql->values($d)));
            try { $isth->execute($sql->values($d)); }
            catch { $l4p->warn('Insert error: '.$_) };
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
    my ( $self, $arg ) = @_;
    my $classobj       = $arg->{classobj};
    $arg->{$_}         = $classobj->$_ for qw( class mpkg ds mds table mtable );
    $arg->{dbh}        = $arg->{mpkg}->driver->rw_handle;

    my $class = $arg->{class};
    $arg->{badmeta}{$class}{$_} = [] foreach qw( type parent );
    $arg->{counts}{$class}{$_}  = 0 foreach qw( total bad_type bad_parent );
    return $arg;
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

our $README = '';

around parse_options => sub {
    my ( $orig, $class, %params) = (shift, shift, @_);
    # warn "In parse_options";
    if ( grep { '--readme' eq $_ } @ARGV ) {
        push( @ARGV, '--man' );
        my %p = $class->$orig(%params);
        $README = $p{readme};
        return %p;
    }
    my %p = $class->$orig(%params);
};

around options_man => sub {
    my ( $orig, $class, $usage, $output ) = @_;
    # p(@_);
    local @ARGV = ();
    if ( !$usage ) {
        local @ARGV = ();
        my %cmdline_params = $class->parse_options( man => 1 );
        $usage = $cmdline_params{man};
    }

    $Pod::POM::DEFAULT_VIEW = 'Pod::POM::View::Pod';
    my ($printing, @extra_pod) = ( 0, () );
    for my $node ( $pom->content ) {
        unless ( $printing ) {
            next unless $node->type() eq 'head1'
                    and $node->title eq 'MODES';
            $printing = 1;
        }
        push( @extra_pod, $node->present('Pod::POM::View::Pod') );
    }

    use Path::Class;
    my $man_file = file( Path::Class::tempdir( CLEANUP => 1 ), 'help.pod' );
    $man_file->spew(
        iomode => '>:encoding(UTF-8)',
        join("\n\n", $usage->option_pod, @extra_pod)
    );

    if ( $README eq 'txt' ) {
        require Pod::Text;
        Pod::Text->filter( $man_file->stringify )
    }
    elsif ( $README eq 'md' ) {
        require Pod::Markdown;
        Pod::Markdown->filter( $man_file->stringify )
    }
    elsif ( $README eq 'gh' ) {
        require Pod::Markdown::Github;
        Pod::Markdown::Github->filter( $man_file->stringify );
    }
    else {
        pod2usage(
            -verbose => 2,
            -input   => $man_file->stringify,
            -exitval => 'NOEXIT',
            -output  => $output
        );
    }

    exit(0);
};

1;

__END__

=head1 NAME

convertdb

=head1 DESCRIPTION

This utility makes it possible to migrate Movable Type data between databases, regardless of
database type. For example, you could use it to backup your MT data from one MySQL database to
another or you could migrate your data to a completely different database (e.g. Oracle to MySQL).

=head1 SYNOPSIS

    cd $MT_HOME
    CONVERTDB="plugins/ConvertDB/tools/convertdb --new mt-config-NEW.cgi"

    # Need help??
    $CONVERTDB --usage                              # Show compact usage syntax
    $CONVERTDB --help                               # Show help text
    $CONVERTDB --man                                # Show man page

    # Migration modes
    $CONVERTDB --mode resavesource                  # Prep source DB
    $CONVERTDB --mode migrate                       # Migrate and verify

    # Inspection/verification modes
    $CONVERTDB --mode verify                        # Reverify data
    $CONVERTDB --mode showcounts                    # Compare table counts
    $CONVERTDB --mode checkmeta                     # Check for orphaned/unregistered

    # Metadata cleanup
    $CONVERTDB --mode checkmeta --remove-orphans    # Remove the orphaned
    $CONVERTDB --mode checkmeta --migrate-unknown   # Migrate the unregistered

=head1 MODES

convertdb's run mode is specified using the C<--mode> option (see L</OPTIONS>).
All values are case-insensitive and the word separator can be a hyphen, an
underscore or omitted entirely (checkmeta, check-meta, check_meta, CheckMeta,
etc)

All of the modes described below iterate over a master list of all object
classes (and their respective metadata classes and tables) in use by Movable
Type. You can modify this list using C<--classes>, C<--skip-classes> and
C<--skip-tables>. This is extremely useful for acting on all but a few large
tables or performing a mode only on a single or handful of classes/tables.

=head2 Supported Modes

The following is a list of all supported values for the C<--mode> flag:

=over 4

=item * B<resave_source>

Iteratively load each object of the specified class(es) from the source database
(in all/included classes minus excluded) and then resave them back to the
source database. Doing this cleans up all of the metadata records which have
null values and throw off the counts.

This is one of only two modes which affect the source database (the other is
C<--mode checkmeta --remove-orphans>) and it only needs to be run once. It is
most efficient to execute this mode first in order to clean up the table counts
for later verification.

=item * B<check_meta>

Perform extra verification steps on metadata tables for the specified class(es)
looking for orphaned and unused metadata rows. With other flags, you can remove
or even migrate the found rows. It is highly recommended to run this with
C<--remove-orphans> and C<--migrate-unknown> flags described later.

=item * B<migrate>

Iteratively loads each object of the specified class(es) and its associated
metadata from the source database and saves all of it to the target database.

By default, the utility also performs an additional step in verifying that the
data loaded from the source and re-loaded from the target is exactly the same,
both in content and encoding. If you wish to skip this verification step you
can use the C<--no-verify> flag.

We highly recommend you use C<--skip-table=log> unless you need to preserve the
activity log history because it can easily dwarf the actual user-created
content in the database.

=item * B<verify>

Performs the same verification normally performed by default under migrate
mode, only without the data migration. This is the exact opposite of C<--mode
migrate --no-verify>.

=item * B<show_counts>

Shows the object and metadata table counts for the specified class(es) in both the current and new databaseq.

=back

=head1 INSTALLATION

You can download an archived version of this utility from
[Github/endevver/mt-util-convertdb](https://github.com/endevver/mt-util-convertdb) or use git:

        $ cd $MT_HOME;
        $ git clone git@github.com:endevver/mt-util-convertdb.git plugins/ConvertDB

Due to a silly little quirk in Movable Type, the utility must be installed as
`plugins/ConvertDB` and not `plugins/mt-util-convertdb` as is the default.

=head2 DEPENDENCIES

=over 4

=item * Movable Type 5 or higher

=item * Log4MT plugin

=item * Class::Load

=item * Data::Printer

=item * Import::Base

=item * List::MoreUtils

=item * List::Util

=item * Module::Runtime

=item * Moo

=item * MooX::Options

=item * Path::Tiny

=item * Scalar::Util

=item * Sub::Quote

=item * Term::ProgressBar

=item * Test::Deep

=item * Text::Table

=item * ToolSet

=item * Try::Tiny

=item * Term::Prompt

=item * Pod::POM

=item * SQL::Abstract

=item * Path::Class

=head1 AUTHOR

Jay Allen, Endevver LLC <jay@endevver.com>

=cut
