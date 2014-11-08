package MT::ConvertDB::CLI;

use MT::ConvertDB::ToolSet;
use MT::ConvertDB::ConfigMgr;
use MT::ConvertDB::ClassMgr;
use Getopt::Long;
use vars qw( $l4p );

sub run {
    my $class = shift;
    GetOptions(
        "old:s"     => \my($old_config),
        "new:s"     => \my($new_config),
        "type:s@"   => \my($types),
        'save'      => \my($save),
        'init-only' => \my($init_only),
    );

    ###l4p $l4p ||= get_logger();
    $old_config ||= './mt-config.cgi';

    die "No --new config file specified" unless $new_config;

    my $cfgmgr = MT::ConvertDB::ConfigMgr->new(
                 read_only => ($save ? 0 : 1),
                       new => $new_config,
        $old_config ? (old => $old_config) : (),
    );

    my $classmgr   = MT::ConvertDB::ClassMgr->new();
    my $class_objs = $classmgr->class_objects($types);

    if ( $init_only ) {
        $l4p->info('Initialization done.  Exiting due to --init-only');
        exit;
    }

    try {
        local $SIG{__WARN__} = sub { $l4p->warn($_[0]) };

        ###
        ### First pass to load/save objects
        ###
        foreach my $classobj ( @$class_objs ) {
            # p($classobj->class->properties);

            $cfgmgr->newdb->remove_all( $classobj );

            my $iter = $cfgmgr->olddb->load_iter( $classobj );

            while (my $obj = $iter->()) {

                $cfgmgr->newdb->save( $classobj, $obj );
            }
            $cfgmgr->post_load( $classobj );
        }
        $cfgmgr->post_load( $classmgr );

        ####l4p $l4mt->info('NOW STARTING SECOND PASS FOR METADATA MIGRATION');

        ###
        ### Second pass to load/save object metadata
        ###
        foreach my $classobj ( @$class_objs ) {
            next unless $classobj->has_metacolumns;
            p($classobj->metacolumns);
            my $iter = $cfgmgr->olddb->load_iter( $classobj );

            while (my $obj = $iter->()) {
                next unless $obj->has_meta;
                my $meta = $cfgmgr->olddb->load_meta( $classobj, $obj );
                $cfgmgr->newdb->save_meta( $classobj, $obj, $meta );
            }
            $cfgmgr->post_load_meta( $classobj );
        }
        $cfgmgr->post_load_meta( $classmgr );

        $l4p->info("Done copying data! All went well.");
    }
    catch {
        $l4p->error("An error occurred while loading data: $_");
        exit 1;
    };

    print "Object counts: ".p($cfgmgr->object_summary);
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
