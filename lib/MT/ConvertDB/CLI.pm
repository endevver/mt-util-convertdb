package MT::ConvertDB::CLI;

use MT::ConvertDB::ToolSet;
use Term::ProgressBar 2.00;
use List::Util qw( reduce );
use List::MoreUtils qw( none part );
use Term::Prompt qw( prompt );
use Sub::Quote qw( quote_sub );
use Pod::Usage qw( pod2usage );
use Text::Table;
use Text::FindIndent;

use Pod::POM;
my ( @POD_EXTRACT, %MooXOptions, $parser, $pom );

BEGIN {
    @POD_EXTRACT = qw( name synopsis description );
    $parser      = Pod::POM->new;
    $pom         = $parser->parse(__FILE__) or die $parser->error();
    for my $head1 ( $pom->head1 ) {
        my $label = lc( $head1->title );
        next unless grep { $label eq $_ } @POD_EXTRACT;
        $MooXOptions{$label} = $head1->content;
    }

    # $MooXOptions{flavour} = [qw( pass_through )];
}
use MooX::Options (%MooXOptions);
use vars qw( $l4p );

use MT::DisableCallbacks (
    internal => [qw( post_save post_remove )],
    plugins  => [qw(
        ajaxrating  genentechthemepack  gamify multiblog  reblog
        bob  assetimagequality  Loupe  facebookcommenters  formattedtext
        imagecropper  messaging  photoassetfromentry  previewshare
        userblogassociation
    )],
);

has mode_handlers => (
    is      => 'ro',
    default => sub {
        {   showcounts   => 'do_table_counts',
            checkmeta    => 'do_check_meta',
            resavesource => 'do_resave_source',
            migrate      => 'do_migrate_verify',
            verify       => 'do_migrate_verify',
            test         => 'do_test',
            fullmigrate  => 'do_full_migrate_verify'
        };
    },
);

option mode => (
    is       => 'rw',
    format   => 's',
    coerce   => quote_sub(q( ($_[0] = lc($_[0])) =~ s/[^a-z]//g; $_[0]  )),
    default  => 'initonly',
    required => 1,
    order    => 1,
    doc(q(
        [REQUIRED] Run mode: show_counts, resave_source, check_meta, migrate
        or verify.
    )),
    long_doc(q(
        [REQUIRED] Run modes. See the L</MODES> section for the list of
        valid values.
    )),
);

option new_config => (
    is       => 'ro',
    format   => 's',
    required => 1,
    order    => 5,
    doc(q(
        [REQUIRED] Path to config file for new database. Can be relative to
        MT_HOME
    )),
    long_doc(q(
        [REQUIRED] Use this option to specify the path/filename of the MT
        config file containing the new database information. It can be an
        absolute path or relative to MT_HOME (e.g. ./mt-config-new.cgi)
    )),
);

option old_config => (
    is       => 'ro',
    format   => 's',
    default  => './mt-config.cgi',
    order    => 10,
    doc(q(
        Path to current config file. Can be relative to MT_HOME. Defaults
        to ./mt-config.cgi'
    )),
    long_doc(q(
        Use this to specify the path/filename of the current MT config file. It
        defaults to ./mt-config-cgi so you only need to use it if you want to
        set specific configuration directives which are different than the ones
        in use in the MT installation.
    )),
);

option classes => (
    is         => 'ro',
    format     => 's@',
    autosplit  => ',',
    default    => sub { [] },
    order      => 25,
    doc(q(
        Classes to include (e.g. MT::Blog). Can be comma-delimited
        or specified multiple times
    )),
    long_doc(q(
        (B<Note:> You should I<PROBABLY> be using the C<--tables> option
        instead.) Use this to specify one or more classes you want to act on in
        the specified mode. This is useful if you want to execute a particular
        mode on a one or a few classes of objects. For example:

            --mode migrate --class MT::Template
            --mode showcounts --classes MT::Author,MT::Template

        See the C<--tables> option for information on this options
        multiple-value syntax and parent class inclusion.
    )),
);

option skip_classes => (
    is        => 'ro',
    format    => 's@',
    autosplit => ',',
    default   => sub { [] },
    order     => 30,
    doc(q(
        Classes to skip (e.g. MT::Log). Can be comma-delimited or specified
        multiple times
    )),
    long_doc(q(
        (B<Note:> You should I<PROBABLY> be using the C<--skip-tables> option
        instead.) Use this to specify one or more classes to exclude during
        execution of the specified mode. It is the exact inverse of the
        C<--classes> option and similar to the C<--skip-tables> option.

        This option is ignored if either C<--tables> or C<--classes> options
        are specified.
    )),
);

option tables => (
    is        => 'ro',
    format    => 's@',
    autosplit => ',',
    default   => sub { [] },
    order     => 15,
    doc(q(
        Tables to process (omit "mt_" prefix: log). Can be
        comma-delimited or specified multiple times
    )),
    long_doc(q(
        Use this to specify one or more tables (omitting the C<mt_>
        prefix) to include during execution of the specified mode. It works
        similarly to C<--classes> but often shorter and more likely what you
        want since it removes the ambiguity of classed objects
        (MT::Blog/MT::Website, MT::Entry/MT::Page).

        For example, the following performs migration of ALL objects in the
        mt_blog table (which may include MT::Blog, MT::Website and
        MT::Community::Blog objects):

            convertdb --mode migrate --table blog

        Like the C<--classes>, C<--skip-classes> and C<--skip-tables> options,
        multiple values can be specified either as a comma-delimited list or
        separate options and the option name can be singularized for
        readability. For example, the following are equivalent:

            --table blog --table author --table entry
            --tables blog,author,entry

        Also note, like the C<--classes> option, any tables contain objects
        whose class is a parent of the class of objects in your specified
        tables will also be included. For example, the following:

            convertdb --mode migrate --table comment

        ...is exactly the same as this:

            convertdb --mode migrate --tables blog,entry,comment

        This is because MT::Comment objects are children of
        MT::Entry/MT::Page objects which themselves are children of MT::Blog
        objects. For reasons of data integrity, there is no way to transfer an
        object without its parent object.
    )),
);

option skip_tables => (
    is        => 'ro',
    format    => 's@',
    autosplit => ',',
    default   => sub { [] },
    order     => 20,
    doc(q(
        Tables to skip (omit "mt_" prefix: log). Can be comma-delimited or
        specified multiple times
    )),
    long_doc(q(
        Use this to specify one or more tables to exclude during execution of
        the specified mode. See the inverse option C<--tables> for its value
        syntax.

        It operates in a similar manner to C<--skip_classes> but is often
        shorter and more likely what you want. For example, the following skips
        the entire mt_log table:

            --skip-table log

        Unless you need to preserve your Activity Log records or are using the
        C<--classes> or C<--tables> option, it is recommended to use this option
        to skip the usually large C<mt_log> table, especially under B<migrate>
        or B<verify> modes:

            --mode migrate --skip-table log
            --mode verify --skip-table log
            --mode showcounts --skip-table log

        This option is ignored if either C<--tables> or C<--classes>
        options are specified.
    )),
);

option only_tables => (
    is        => 'ro',
    format    => 's@',
    autosplit => ',',
    default   => sub { [] },
    order     => 22,
    doc(q(
        Like C<--tables> but exclusively migrates the specified tables without
        parent object tables. Used for parallel execution.
    )),
    long_doc(q(
        This option is exactly like the C<--tables> option except that does not
        silently pre-migrate the parent object's tables.  This allows you to
        run the utility in parallel against different sets of one or more
        tables without truncating and re-migrating common parent object tables.
        This is useful (perhaps necessary) in order to more quickly migrate a
        very large database.
    )),
);

option no_verify => (
    is       => 'ro',
    default  => 0,
    order    => 35,
    doc      => '[WITH MODE: migrate] Skip data verification during migration.',
    long_doc(q(
        [B<migrate MODE ONLY>] This option skips the content and encoding
        verification for each object migrated to the source database. This is
        useful if you want to quickly perform a migration and are confident of
        the process or plan on verifying later.
    )),
);

option migrate_unknown => (
    is  => 'rw',
    default => 0,
    order   => 40,
    doc => '[WITH MODE: checkmeta] Migrate all unknown metadata.',
    long_doc(q(
        [B<checkmeta MODE ONLY>] This option cause all metadata records with
        unregistered field types to be migrated. This step now occurs during
        migrate mode so there should be no need to run it separately.
    )),
);

option remove_orphans => (
    is       => 'ro',
    default  => 0,
    order    => 45,
    doc      => '[WITH MODE: checkmeta] Remove found orphans.',
    long_doc(q(
        [B<checkmeta MODE ONLY>] This removes all metadata records from the
        source database which are associated with a non-existent object.
    )),
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
    is      => 'rw',
    doc     => 'hidden',
    default => 0,
);

option readme => (
    is      => 'ro',
    format  => 's',
    doc     => 'hidden',
    default => 0,
);

has [qw( classmgr cfgmgr class_objects )] => ( is => 'lazy' );

has progressbar => (
    is        => 'lazy',
    predicate => 1,
);

has ds_ignore => (
    is      => 'ro',
    default => sub {qr{^(fileinfo|log|touch|trackback|ts_.*)$}},
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
    if ( @{ $self->only_tables } ) {
        $param{include_tables} = $self->only_tables;
        $param{no_parents}     = 1;
    }
    elsif ( @{ $self->classes } || @{ $self->tables } ) {
        $param{include_classes} = $self->classes if @{ $self->classes };
        $param{include_tables}  = $self->tables  if @{ $self->tables };
    }
    else {
        $param{exclude_classes} = $self->skip_classes
            if @{ $self->skip_classes };
        $param{exclude_tables} = $self->skip_tables
            if @{ $self->skip_tables };
    }
    use_module('MT::ConvertDB::ClassMgr')->new(%param);
}

sub _build_cfgmgr {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    my %param = (
        check_schema => ( $self->only_tables ? 0 : 1 ),
        read_only    => ( $self->dry_run     ? 1 : 0 ),
        new          => $self->new_config,
        old          => $self->old_config,
    );
    use_module('MT::ConvertDB::ConfigMgr')->new(%param);
}

sub _build_class_objects {
    shift->classmgr->class_objects();
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
    ###l4p my $msg = 'Initialized progress bar with %d objects: ';
    ###l4p $l4p->info(sprintf( $msg, $self->total_objects ));
    ###l4p $l4p->debug('Progress bar object: ', l4mtdump($p));
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
                $cnts->{$ds}{$which}
                    = $db->table_counts( $classobj, {}, { no_class => 1, } );
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

    if ( $self->only_tables ) {
        my ( $filelog, $errlog ) = map {
                $Log::Log4perl::Logger::APPENDER_BY_NAME{$_}
            } qw( File Errorlog );
        $l4p->info('Raising file logger threshold to WARN');
        $filelog->threshold('WARN');
        $errlog->threshold('DEBUG');
    }

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
            my $methname = $handle->{ $self->mode }
                or die "Unknown mode: " . $self->mode;
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

    my $tb = Text::Table->new(
        "Table",   "Status",  "Old",      "New",
        "Obj-Old", "Obj-New", "Meta-Old", "Meta-New"
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
    my ( $self, $class_objs ) = @_;
    my $cfgmgr   = $self->cfgmgr;
    my $classmgr = $self->classmgr;
    $class_objs ||= $self->class_objects;
    ###l4p $l4p ||= get_logger();
    require MT::Meta;

    my ( %counts, %badmeta );

    foreach my $classobj (@$class_objs) {
        my $class = $classobj->class;
        my @isa = try { no strict 'refs'; @{ $class . '::ISA' } };
        next unless grep { $_ eq 'MT::Object' } @isa;

        # Reset object drivers for class and metaclass
        $cfgmgr->use_old_database;
        $classobj->reset_object_drivers();

        next unless MT::Meta->has_own_metadata_of($class);

        my $arg = $self->_create_check_meta_args(
            {   classobj => $classobj,
                counts   => \%counts,
                badmeta  => \%badmeta,
            }
        );
        local $arg->{dbh}{RaiseError}       = 1;
        local $arg->{dbh}{FetchHashKeyName} = 'NAME_lc';    # lc($colnames)

        $self->progress("Checking $class metadata...")
            unless $self->mode eq 'migrate';

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

    if ( %counts and $self->mode ne 'migrate' ) {
        ###l4p $l4p->info("Bad metadata check: ", l4mtdump(\%counts));
        p(%counts);
    }

    delete $badmeta{$_}{type}
        for grep { !@{ $badmeta{$_}{type} } } keys %badmeta;
    delete $badmeta{$_}{parent}
        for grep { !@{ $badmeta{$_}{parent} } } keys %badmeta;
    delete $badmeta{$_} for grep { !%{ $badmeta{$_} } } keys %badmeta;

    if ( %badmeta and $self->mode ne 'migrate' ) {
        my $label = 'Orphaned metadata fields:';
        say $label;
        p(%badmeta);
        $l4p->info( $label, l4mtdump( \%badmeta ) );
    }
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
        next unless MT::Meta->has_own_metadata_of($class);

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
        ###l4p $l4p->info( "Truncating all tables in destination database" );
        $self->migrate_unknown(1);
        # $cfgmgr->newdb->remove_all($_) foreach @$class_objs;
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
                if $self->mode eq 'verify' or !$self->no_verify;

            $count += 1 + scalar( keys %$meta );
            $next_update = $self->progressbar->update($count)
                if $count >= $next_update;    # efficiency

            $cfgmgr->use_old_database();
        }

        $self->do_check_meta( [$classobj] );

        $cfgmgr->post_migrate_class($classobj)
            if $self->mode eq 'migrate' and ! $self->dry_run;
    }

    $cfgmgr->post_migrate($classmgr, $self->only_tables)
        if $self->mode eq 'migrate' and ! $self->dry_run;

    $self->progress("Processing of ALL OBJECTS complete.");

    $self->verify_record_counts()
        if $self->mode eq 'verify' or !$self->no_verify;

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
            $self->progress(
                "Object counts don't match for $ds (Ignore. Drift data) ");
        }
        else {
            ( $l4p ||= get_logger )
                ->error( sprintf( 'Object count mismatch for %s ', $ds ),
                l4mtdump( $cnts->{$ds} ) );
        }
    }
}

sub _do_check_unknown {
    my ( $self, $arg ) = @_;
    my $classobj = $arg->{classobj};
    my $class    = $arg->{class};
    ###l4p $l4p ||= get_logger();
    my $mtype = $classobj->mds . '_type';
    my $sql
        = " SELECT $mtype, count(*) "
        . " FROM "
        . $classobj->mtable
        . " GROUP BY $mtype";
    my $rows  = $arg->{dbh}->selectall_arrayref($sql);
    my $mcols = $classobj->metacolumns;
    foreach my $row (@$rows) {
        my ( $type, $cnt ) = @$row;
        $arg->{counts}{$class}{total} += $cnt;

        unless ( grep { $_->{name} eq $type } @$mcols ) {
            my $msg
                = "Found $cnt $class meta records of unknown type '$type'";
            ###l4p $l4p->error( $msg ) unless $self->mode eq 'migrate';
            $arg->{counts}{$class}{bad_type} += $cnt;
            push( @{ $arg->{badmeta}{$class}{type} }, $type );
        }
    }
}

sub _do_check_orphans {
    my ( $self, $arg ) = @_;
    my ( $class, $mtable ) = map { $arg->{$_} } qw( class mtable );
    my $pk   = $class->properties->{primary_key};
    my $mpk  = join( '_', @{$arg}{ 'mds', 'ds' }, $pk );
    my $sql  = "SELECT $mpk, count(*) FROM $mtable GROUP BY $mpk";
    my $rows = $arg->{dbh}->selectall_arrayref($sql);

    foreach my $row (@$rows) {
        my ( $obj_id, $cnt ) = @$row;
        unless ( $class->exist( { $pk => $obj_id } ) ) {
            my $msg = "Found $cnt $class meta records with non-existent "
                . "parent ID $obj_id";
            ###l4p $l4p->error( $msg ) unless $self->mode eq 'migrate';
            $arg->{counts}{$class}{bad_parent} += $cnt;
            push( @{ $arg->{badmeta}{$class}{parent} }, $obj_id );
        }
    }
}

sub _do_remove_orphans {
    my ( $self, $arg ) = @_;
    my $class      = $arg->{class};
    my $mpkg       = $arg->{mpkg};
    my $parent_ids = $arg->{badmeta}{$class}{parent} || [];
    ###l4p $l4p ||= get_logger();
    return unless @$parent_ids;

    my $msg
        = 'Are you sure you want to remove '
        . $arg->{mtable}
        . ' rows with '
        . 'non-existent parents? (This is destructive and '
        . 'non-reversible!)';
    return unless prompt( 'y', $msg, 'y/n', 'n' );

    $self->progress(
        "Removing orphaned metadata for $class... " . p($parent_ids) );

    my $id = $class->datasource . '_id';
    $self->_do_direct_remove( $arg, { $id => $parent_ids } );
}

sub _do_migrate_unknown {
    my ( $self, $arg ) = @_;
    state $rf       = MT->component('RetiredFields');
    state $obsolete = $rf->registry('obsolete_meta_fields');
    state $unused   = $rf->registry('unused_meta_fields');
    my $class  = $arg->{class};
    my $mtable = $arg->{mtable};
    my $ds     = $arg->{ds};
    my $mcols  = $arg->{classobj}->metacolumns;
    my $olddb  = $arg->{mpkg}->driver;
    ###l4p $l4p ||= get_logger();

    my @unknown = map { @{ $_->{$ds} || [] } } $unused, $obsolete;
    return unless @unknown;

    $self->progress("Migrating unregistered $class metadata");
    ###l4p $l4p->debug('Migrating unregistered meta fields: ', l4mtdump(@unknown));

    require SQL::Abstract;
    my $sql = SQL::Abstract->new();

    # Reset object drivers for class and metaclass
    $self->cfgmgr->use_new_database;
    $arg->{classobj}->reset_object_drivers();
    my $newdb = $arg->{mpkg}->driver;

    $self->cfgmgr->use_old_database;
    foreach my $unknown (@unknown) {
        next if grep { $unknown eq $_->{name} } @$mcols;
        my ( $select, @sbind )
            = $sql->select( $mtable, ['*'],
            { $arg->{mds} . '_type' => $unknown } );
        ###l4p $l4p->debug( $select.' '.p(@sbind) );

        my ( $insert, $isth );
        my $ssth = $olddb->rw_handle->prepare($select);
        $ssth->execute(@sbind);
        while ( my $d = $ssth->fetchrow_hashref ) {
            $insert ||= $sql->insert( $mtable, $d );
            $isth ||= $newdb->rw_handle->prepare($insert);
            try {
                $isth->execute( $sql->values($d) );
                ###l4p $l4p->debug( $insert.' '.p($sql->values($d)));
            }
            catch {
                $l4p->warn( "Insert error: $_" );
                $l4p->warn( $insert.' '.p($sql->values($d)));
            };
        }
    }

    $self->cfgmgr->use_old_database;
}

sub _do_remove_obsolete {
    my ( $self, $arg ) = @_;
    state $rf       = MT->component('RetiredFields');
    state $obsolete = $rf->registry('obsolete_meta_fields');
    state $unused   = $rf->registry('unused_meta_fields');
    my $class      = $arg->{class};
    my $mtable     = $arg->{mtable};
    my $meta_types = $obsolete->{ $arg->{ds} };
    ###l4p $l4p ||= get_logger();

    return
        unless @{ $arg->{badmeta}{$class}{type} }
        && try { @{ $arg->{meta_types} } };

    my $msg
        = "Are you sure you want to remove $mtable rows with the fields "
        . "above which RetiredFields says are obsolete? (This is "
        . "destructive and non-reversible!)";
    p($meta_types);
    return unless prompt( 'y', $msg, 'y/n', 'n' );

    my $is_unknown = sub {
        my $v = shift;
        none { $v eq $_ } @$meta_types ? 1 : 0;
    };

    my ( $obsoletes, $unhandled )
        = part { $is_unknown->($_) } @{ $arg->{badmeta}{$class}{type} };

    if ( $obsoletes && @$obsoletes ) {
        $self->progress("Removing obsolete metadata fields for $class...");
        p($obsoletes);
        $self->_do_direct_remove( $arg, { type => $obsoletes } );
    }

    if ( $unhandled && @$unhandled ) {
        $self->progress( 'Not removing the following fields which '
                . 'were not specified by the RetiredFields plugin: '
                . ( join( ', ', @$unhandled ) ) );
    }
}

sub _do_direct_remove {
    my ( $self, $arg, $terms ) = @_;
    my $mpkg = $arg->{mpkg};
    ###l4p $l4p ||= get_logger();
    try { $mpkg->driver->direct_remove( $mpkg, $terms ) }
    catch { $l4p->error($_); exit };
}

sub _create_check_meta_args {
    my ( $self, $arg ) = @_;
    my $classobj = $arg->{classobj};
    $arg->{$_} = $classobj->$_ for qw( class mpkg ds mds table mtable );
    $arg->{dbh} = $arg->{mpkg}->driver->rw_handle;

    my $class = $arg->{class};
    $arg->{badmeta}{$class}{$_} = [] foreach qw( type parent );
    $arg->{counts}{$class}{$_}  = 0  foreach qw( total bad_type bad_parent );
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
    my ( $orig, $class, %params ) = ( shift, shift, @_ );

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
    my ( $printing, @extra_pod ) = ( 0, () );
    for my $node ( $pom->content ) {
        unless ($printing) {
            next
                unless $node->type() eq 'head1'
                and $node->title eq 'MODES';
            $printing = 1;
        }
        push( @extra_pod, $node->present('Pod::POM::View::Pod') );
    }

    use Path::Class;
    my $man_file = file( Path::Class::tempdir( CLEANUP => 1 ), 'help.pod' );
    $man_file->spew(
        iomode => '>:encoding(UTF-8)',
        join( "\n\n", $usage->option_pod, @extra_pod )
    );

    if ( $README eq 'txt' ) {
        require Pod::Text;
        Pod::Text->filter( $man_file->stringify );
    }
    elsif ( $README eq 'md' ) {
        require Pod::Markdown;
        Pod::Markdown->filter( $man_file->stringify );
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

sub doc      { return ( doc      => wrap(@_) ) }
sub long_doc { return ( long_doc => wrap(@_) ) }

sub wrap {
    my $str =  shift;
    $str    =~ s{(\A *\n|\n +\Z)}{}gsm;
    my $indentation_type
        = Text::FindIndent->parse(\$str, first_level_indent_only => 1);
    if ($indentation_type =~ /^s(\d+)/) {
        my $indent = ' 'x$1;
        $str       =~ s{^$indent}{}gsm;
    }
    else { warn "Bad indentation type ($indentation_type): $str" }
    return $str;
}

1;

__END__

=head1 NAME

convertdb

=head1 DESCRIPTION

This utility makes it possible to migrate Movable Type data between databases,
regardless of database type. For example, you could use it to backup your MT
data from one MySQL database to another or you could migrate your data to a
completely different database (e.g. Oracle to MySQL).

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

Shows the object and metadata table counts for the specified class(es) in both
the current and new database.

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

=over 4

=item * Log4MT plugin (use perl5.8.9-compat branch)

=item * RetiredFields plugin

=back

=item * CPAN Modules

=over 4

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

=back

=head1 AUTHOR

Jay Allen, Endevver LLC <jay@endevver.com>

=cut


sub do_full_migrate_verify {
    my $self       = shift;
    # my $cfgmgr     = $self->cfgmgr;
    # my $classmgr   = $self->classmgr;
    # my $class_objs = $self->class_objects;
    ###l4p $l4p ||= get_logger();

    # ref($self)->new_with_options(
    #     mode       => 'resavesource',
    #     skip_table => 'log',
    # )->run();

    # my $skip_tables = [
    #     keys %{ map { $_ => 1 } ( 'log', @{$self->skip_tables} ) }
    # ];
    # $self->skip_tables($skip_tables);
    # $self->mode('migrate');
    # $self->run
    #
    # ref($self)->new_with_options(
    #     mode       => 'migrate',
    #     skip_table => 'log',
    # )->run();

    # =pod
    #     cd $MT_HOME
    #     CONVERTDB="plugins/ConvertDB/tools/convertdb --new mt-config-NEW.cgi"
    #
    #     # Need help??
    #     $CONVERTDB --usage                              # Show compact usage syntax
    #     $CONVERTDB --help                               # Show help text
    #     $CONVERTDB --man                                # Show man page
    #
    #     # Migration modes
    #     $CONVERTDB --mode resavesource                  # Prep source DB
    #     $CONVERTDB --mode migrate                       # Migrate and verify
    #
    #     # Inspection/verification modes
    #     $CONVERTDB --mode verify                        # Reverify data
    #     $CONVERTDB --mode showcounts                    # Compare table counts
    #     $CONVERTDB --mode checkmeta                     # Check for orphaned/unregistered
    #
    #     # Metadata cleanup
    #     $CONVERTDB --mode checkmeta --remove-orphans    # Remove the orphaned
    #     $CONVERTDB --mode checkmeta --migrate-unknown   # Migrate the unregistered
    #
    #     die;
    #     __PACKAGE__->new_with_options('mode' => 'resave-source')->run;
    #
    #     my $chkmeta = __PACKAGE__->new_with_options(
    #         'mode' => 'check-meta',
    #         'remove_orphans' => 1,
    #         'migrate_unknown' => 1
    #     )->run;
    #
    #     my $migrate = __PACKAGE__->new_with_options(
    #         'mode' => 'migrate',
    #     )->run;
    # =cut
}

