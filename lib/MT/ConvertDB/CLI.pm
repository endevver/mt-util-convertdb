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

    unless ( $self->migrate || $self->verify ) {
        $l4p->info('Initialization done.  Exiting due to --init-only');
        exit;
    }

    my $max = reduce { $a + $b }
                 map { $_->object_count + $_->meta_count } @$class_objs;
    $self->update_count( 0 => $max );

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

                $self->update_count( scalar(keys %$meta) + 1 );
            }
            ###l4p $l4p->info($classobj->class.' object migration complete');
            $cfgmgr->post_load( $classobj );
        }
        $cfgmgr->post_load( $classmgr );
        $self->update_count($max);
        ###l4p $l4p->info("Done copying data! All went well.");
    }
    catch {
        $l4p->error("An error occurred while loading data: $_");
        exit 1;
    };

    print "Object counts: ".p($cfgmgr->object_summary);
}

sub verify_migration {
    my $self             = shift;
    my ($classobj, $obj) = @_;
    ###l4p $l4p ||= get_logger();

    my $cfgmgr = $self->cfgmgr;
    my $class  = $classobj->class;
    my $pk_str = $obj->pk_str;

    ###l4p $l4p->debug('Reloading record from new DB for comparison');
    my $newobj = try { $cfgmgr->newdb->load($classobj, $obj->primary_key_to_terms) }
               catch { $l4p->error($_, l4mtdump($obj->properties)) };
    foreach my $k ( keys %{$obj->get_values} ) {
        $l4p->debug("Comparing $class $pk_str $k values");
        use Test::Deep::NoTest;
        my $diff = ref($obj->$k) ? (eq_deeply($obj->$k, $newobj->$k)?'':1)
                                 : DBI::data_diff($obj->$k, $newobj->$k);
        if ( $diff ) {
            unless ($obj->$k eq '' and $newobj->$k eq '') {
                $l4p->error(sprintf(
                    'Data difference detected in %s ID %d %s!',
                    $class, $obj->id, $k, $diff
                ));
                $l4p->error($diff);
                $l4p->error('a: '.$obj->$k);
                $l4p->error('b: '.$newobj->$k);
            }
        }
    }
}

sub update_count {
    my ($cnt, $max)    = @_;
    state $count       = 0;
    state $next_update = 0;
    state $maximum     = $max;
    state $progress    = Term::ProgressBar->new({
                            name => 'Migrated', count => $max, remove => 0
                        });
    $max and $progress->minor(0);
    $count += $cnt;
    $next_update = $progress->update($count)
      if ( $count >= $next_update )
      || ( $count == $maximum );
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
