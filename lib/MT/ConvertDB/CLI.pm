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

option types => (
    is     => 'ro',
    format => 's@',
    autosplit => ',',
    default => sub { [] },
    doc => '',
    longdoc => '',
);

option dry_run => (
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

sub _build_classmgr { use_module('MT::ConvertDB::ClassMgr')->new() }

sub _build_class_objects {
    my $self = shift;
    $self->classmgr->class_objects($self->types);
}

sub run {
    my $self       = shift;
    my $cfgmgr     = $self->cfgmgr;
    my $classmgr   = $self->classmgr;
    my $class_objs = $self->class_objects;
    ###l4p $l4p ||= get_logger();

    my $count       = 0;
    my $next_update = 0;
    my $finish      = $self->update_count( $count => $class_objs );

    unless ( $self->migrate || $self->verify ) {
        $self->update_count($finish);
        $self->progress(
              "Class initialization done for $finish objects. "
            . 'Exiting without --migrate or --verify'
        );
        exit;
    }

    try {
        local $SIG{__WARN__} = sub { $l4p->warn($_[0]) };

        foreach my $classobj ( @$class_objs ) {

            $cfgmgr->newdb->remove_all( $classobj )
                if $self->migrate;

            my $iter = $cfgmgr->olddb->load_iter( $classobj );

            ###l4p $l4p->info($classobj->class.' object migration starting');
            while (my $obj = $iter->()) {

                my $meta = $cfgmgr->olddb->load_meta( $classobj, $obj );

                $cfgmgr->newdb->save( $classobj, $obj, $meta )
                    if $self->migrate;

                $self->verify_migration( $classobj, $obj )
                    if $self->verify;

                $count += 1 + scalar(keys %$meta);
                $next_update = $self->update_count($count)
                  if $count >= $next_update;    # efficiency
            }
            ###l4p $l4p->info($classobj->class.' object migration complete');
            $cfgmgr->post_load( $classobj );
            $self->verify_counts() if $self->verify;

        }
        $cfgmgr->post_load( $classmgr );
        $self->update_count($finish);
        $self->progress('Done copying data! All went well.');
    }
    catch {
        $l4p->error("An error occurred while loading data: $_");
        exit 1;
    };
    $self->progress('Object counts: '.p($cfgmgr->object_summary));
}

sub verify_migration {
    my $self             = shift;
    my ($classobj, $obj) = @_;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->debug('Reloading record from new DB for comparison');
    my $cfgmgr = $self->cfgmgr;
    my $newobj = try { $cfgmgr->newdb->load($classobj, $obj->primary_key_to_terms) }
               catch { $l4p->error($_, l4mtdump($obj->properties)) };
    my $meta = $cfgmgr->newdb->load_meta( $classobj, $newobj );

    $classobj->object_diff( $obj, $newobj );
}

sub verify_counts {
    my $self = shift;
    my $class_objs = $self->class_objects;
    ### TODO Check object counts
}

sub update_count {
    my $self = shift;
    my ($cnt, $class_objs) = @_;
    state $obj_cnt
        = reduce { $a + $b }
             map { $_->object_count + $_->meta_count } @$class_objs;
    state $progress
        = Term::ProgressBar->new({ name => 'Progress', count => $obj_cnt });
    if ( $class_objs ) { # Initialization/first call
        $progress->minor(0);
        return $obj_cnt;        # Return finish value
    }
    $progress->update( $cnt );  # Returns next update value
}

sub progress {
    my $self = shift;
    my $msg  = shift;
    ###l4p $l4p ||= get_logger();
    ###l4p $l4p->info($msg);
    print "$msg\n";
}

1;

__END__

=head1 NAME

convert-db - A tool to convert backend database of Movable Type

=head1 SYNOPSIS

convert-db --new=mt-config.cgi.new [--old=mt-config.cgi.current]

=head1 DESCRIPTION

I<convert-db> is a tool to convert database of Movable Type to
others.  It is useful when it is necessary to switch like from
MySQL to PostgreSQL.

The following options are available:

  --new       mt-config.cgi file of destination
  --old       mt-config.cgi file of source (optional)

It is also useful to replicate Movable Type database.

=cut
