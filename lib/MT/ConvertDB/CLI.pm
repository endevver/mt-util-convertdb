package MT::ConvertDB::CLI;

use MT::ConvertDB::ToolSet;
use Term::ProgressBar 2.00;
use List::Util qw( reduce );
use MooX::Options;
use vars qw( $l4p );

option old_config => (
    is     => 'ro',
    format => 's',
    doc => '',
    longdoc => '',
    default => './mt-config.cgi',
);

option new_config => (
    is       => 'ro',
    format   => 's',
    required => 1,
    doc => '',
    longdoc => '',
);

option classes => (
    is     => 'ro',
    format => 's@',
    autosplit => ',',
    default => sub { [] },
    doc => '',
    longdoc => '',
);

option skip_classes => (
    is     => 'ro',
    format => 's@',
    autosplit => ',',
    default => sub { [] },
    doc => '',
    longdoc => '',
);

option dry_run => (
    is => 'rw',
    doc => '',
    longdoc => '',
    default => 0,
);

option resave_source => (
    is => 'ro',
    doc => '',
    longdoc => '',
    default => 0,
);

option migrate => (
    is => 'ro',
    doc => '',
    longdoc => '',
    default => 0,
);

option verify => (
    is => 'ro',
    doc => '',
    longdoc => '',
    default => 0,
);

has classmgr => (
    is => 'lazy',
);

has cfgmgr => (
    is => 'lazy',
);

has class_objects => (
    is => 'lazy',
);

has progressbar => (
    is        => 'lazy',
    predicate => 1,
);

has total_objects => (
    is        => 'rw',
    predicate => 1,
);

sub _build_classmgr {
    my $self = shift;
    my %param = ();
    $param{include_classes} = $self->classes      if @{$self->classes};
    $param{exclude_classes} = $self->skip_classes if @{$self->skip_classes};
    use_module('MT::ConvertDB::ClassMgr')->new(%param);
}


sub _build_cfgmgr {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    my %param = (
        read_only => ($self->dry_run ? 1 : 0),
        new       => $self->new_config,
        old       => $self->old_config,
    );
    use_module('MT::ConvertDB::ConfigMgr')->new(%param);
}

sub _build_class_objects {
    my $self  = shift;
    [
        grep { ! ( $_->class ~~ $self->skip_classes ) }
            @{$self->classmgr->class_objects()}
    ];
}

my ($finish, $count, $next_update) = ( 0, 0, 0 );

sub _build_progressbar {
    my $self = shift;
    ###l4p $l4p ||= get_logger();
    die "Progress bar requires total_objects count" unless $self->total_objects;
    my $p = Term::ProgressBar->new({
        name  => 'Progress',
        count => $self->total_objects,
        ETA   => 'linear'
    });
    $p->max_update_rate(1),
    $p->minor(0);
    ###l4p $l4p->info(sprintf('Initialized progress bar with %d objects: ',
    ###l4p              $self->total_objects), l4mtdump($p));
    $p;
}

sub run {
    my $self       = shift;
    my $cfgmgr     = $self->cfgmgr;
    my $classmgr   = $self->classmgr;
    my $class_objs = $self->class_objects;
    ###l4p $l4p ||= get_logger();

    $self->dry_run(1) unless $self->migrate;

    $finish = $self->update_count( $count => $class_objs );

    try {
        local $SIG{__WARN__} = sub { $l4p->warn($_[0]) };

        if ( $self->resave_source ) {
            $self->do_resave_source();
        }
        elsif ( $self->migrate || $self->verify  ) {
            $self->do_migrate_verify()
        }
        else {
            $self->progress( "Class initialization done for $finish objects. "
                           . 'Exiting without --migrate or --verify' );
        }
        $self->progress('Script complete. All went well.');
    }
    catch {
        $l4p->error("An error occurred: $_");
        exit 1;
    };
}

sub do_resave_source {
    my $self       = shift;
    my $cfgmgr     = $self->cfgmgr;
    my $classmgr   = $self->classmgr;
    my $class_objs = $self->class_objects;
    ###l4p $l4p ||= get_logger();

    $self->progress("Resaving $finish source objects.");

    $cfgmgr->old_config->read_only(0);

    foreach my $classobj ( @$class_objs ) {

        my $iter = $cfgmgr->olddb->load_iter( $classobj );
        while ( my $obj = $iter->() ) {

            my $meta = $cfgmgr->olddb->load_meta( $classobj, $obj );

            $cfgmgr->olddb->save( $classobj, $obj, $meta )
                or die "Could not save ".$obj->type." object: ".$obj->errstr;

            $count += 1 + scalar(keys %$meta);
            $next_update = $self->update_count($count)
              if $count >= $next_update;    # efficiency
        }
    }
    $cfgmgr->old_config->read_only(1);

    $self->update_count($finish);

    $self->progress('Resaved all objects!');
}

sub do_migrate_verify {
    my $self       = shift;
    my $cfgmgr     = $self->cfgmgr;
    my $classmgr   = $self->classmgr;
    my $class_objs = $self->class_objects;
    ###l4p $l4p ||= get_logger();

    foreach my $classobj ( @$class_objs ) {

        my $class = $classobj->class;

        $cfgmgr->newdb->remove_all( $classobj ) if $self->migrate;

        my $iter = $cfgmgr->olddb->load_iter( $classobj );

        $self->progress('Processing '.$classobj->class.' objects');
        while (my $obj = $iter->()) {

            unless (defined($obj)) {
                $l4p->error($classobj->class." object not defined!");
                next;
            }

            my $meta = $cfgmgr->olddb->load_meta( $classobj, $obj );

            $cfgmgr->newdb->save( $classobj, $obj, $meta )
                if $self->migrate;

             $self->verify_migration( $classobj, $obj, $meta )
                if $self->verify;

            $count += 1 + scalar(keys %$meta);
            $next_update = $self->update_count($count)
              if $count >= $next_update;    # efficiency

            $cfgmgr->use_old_database();
        }
        ###l4p $l4p->info('Processing '.$classobj->class.' objects complete');

        $cfgmgr->post_migrate_class( $classobj ) unless $self->dry_run;
    }
    $cfgmgr->post_migrate( $classmgr ) unless $self->dry_run;
    $self->progress("Processing of ALL OBJECTS complete.");

    $self->verify_record_counts() if $self->verify;

    $self->update_count($finish);
}

sub verify_migration {
    my $self             = shift;
    my ($classobj, $obj, $oldmeta) = @_;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->debug('Reloading record from new DB for comparison');
    my $cfgmgr = $self->cfgmgr;
    my $newobj = try { $cfgmgr->newdb->load_object($classobj, $obj) }
               catch { $l4p->error($_, l4mtdump($obj->properties)) };

    my $newmeta = $cfgmgr->newdb->load_meta( $classobj, $newobj );

    $classobj->object_diff(
        objects => [ $obj,     $newobj  ],
        meta    => [ $oldmeta, $newmeta ],
    );
}

sub verify_record_counts {
    my $self       = shift;
    my $cfgmgr     = $self->cfgmgr;
    my $class_objs = $self->class_objects;
    ###l4p $l4p ||= get_logger();

    foreach my $classobj ( @$class_objs ) {
        my $class    = $classobj->class;

        my $old = $cfgmgr->olddb->full_record_counts($classobj);

        my $new = $cfgmgr->newdb->full_record_counts($classobj);

        if ( $old->{total} == $new->{total} ) {
            $self->progress('Object counts match for '.$classobj->class);
        }
        else {
            ($l4p ||= get_logger)->error(sprintf(
                'Object count mismatch for %s',
                $classobj->class ), l4mtdump({ old => $old, new => $new }));
        }
    }
}

sub update_count {
    my $self               = shift;
    my ($cnt, $class_objs) = @_;
    my $cfgmgr             = $self->cfgmgr;

    if ( $class_objs ) { # Initialization/first call
        $self->total_objects(
            reduce { $a + $b }
               map {   $cfgmgr->olddb->count($_)
                     + $cfgmgr->olddb->meta_count($_) } @$class_objs
        );
        my $p = $self->progressbar();
        return $self->total_objects;        # Return finish value
    }
    $self->progressbar->update( $cnt );  # Returns next update value
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

