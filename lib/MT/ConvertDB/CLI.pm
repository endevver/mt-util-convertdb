package MT::ConvertDB::CLI;

use MT::ConvertDB::ToolSet;
use Term::ProgressBar 2.00;
use List::Util qw( reduce );
use MooX::Options;
use vars qw( $l4p );

option old_config => (
    is      => 'ro',
    format  => 's',
    doc     => '',
    longdoc => '',
    default => './mt-config.cgi',
);

option new_config => (
    is       => 'ro',
    format   => 's',
    required => 1,
    doc      => '',
    longdoc  => '',
);

option classes => (
    is        => 'ro',
    format    => 's@',
    autosplit => ',',
    default   => sub { [] },
    doc       => '',
    longdoc   => '',
);

option show_counts => (
    is      => 'ro',
    doc     => '',
    longdoc => '',
);

option skip_classes => (
    is        => 'ro',
    format    => 's@',
    autosplit => ',',
    default   => sub { [] },
    doc       => '',
    longdoc   => '',
);

option dry_run => (
    is      => 'rw',
    doc     => '',
    longdoc => '',
    default => 0,
);

option test => (
    is      => 'ro',
    doc     => '',
    longdoc => '',
    default => 0,
);

option resave_source => (
    is      => 'ro',
    doc     => '',
    longdoc => '',
    default => 0,
);

option migrate => (
    is      => 'ro',
    doc     => '',
    longdoc => '',
    default => 0,
);

option verify => (
    is      => 'ro',
    doc     => '',
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
    [ grep { !( $_->class ~~ $self->skip_classes ) }
            @{ $self->classmgr->class_objects() } ];
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

    $self->dry_run(1) unless $self->migrate;

    try {
        local $SIG{__WARN__} = sub { $l4p->warn( $_[0] ) };

        if ( $self->show_counts ) {
            $self->do_table_counts();
        }
        elsif ( $self->test ) {
            $self->do_test();
        }
        elsif ( $self->resave_source ) {
            $self->do_resave_source();
        }
        elsif ( $self->migrate || $self->verify ) {
            $self->do_migrate_verify();
        }
        else {
            $self->progress( 'Class initialization done for '
                    . Sself->total_objects
                    . ' objects. '
                    . 'Exiting without --migrate or --verify' );
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
        "Objects Old",
        "Objects New",
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

    if ( $self->migrate ) {
        ###l4p $l4p->info( "Removing all rows from tables in new database" );
        $cfgmgr->newdb->remove_all($_) foreach @$class_objs;
        $self->do_table_counts();
    }

    my $count       = 0;
    my $next_update = $self->progressbar->update(0);

    foreach my $classobj (@$class_objs) {
        my $class = $classobj->class;

        ###l4p $self->progress(sprintf('%s %s objects',
        ###l4p     ($self->migrate ? 'Migrating' : 'Verifying'), $class ));
        my $iter = $cfgmgr->olddb->load_iter($classobj);
        while ( my $obj = $iter->() ) {

            unless ( defined($obj) ) {
                $l4p->error( $class . " object not defined!" );
                next;
            }

            my $meta = $cfgmgr->olddb->load_meta( $classobj, $obj );

            $cfgmgr->newdb->save( $classobj, $obj, $meta )
                if $self->migrate;

            $self->verify_migration( $classobj, $obj, $meta )
                if $self->verify;

            $count += 1 + scalar( keys %$meta );
            $next_update = $self->progressbar->update($count)
                if $count >= $next_update;    # efficiency

            $cfgmgr->use_old_database();
        }

        $cfgmgr->post_migrate_class($classobj) unless $self->dry_run;
    }
    $cfgmgr->post_migrate($classmgr) unless $self->dry_run;
    $self->progress("Processing of ALL OBJECTS complete.");

    $self->verify_record_counts() if $self->verify;

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

sub progress {
    my $self = shift;
    my $msg  = shift;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->info($msg);
    my $p = $self->progressbar;
    $p->message($msg);
}

1;

