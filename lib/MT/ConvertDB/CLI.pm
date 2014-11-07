package MT::ConvertDB::CLI;

use MT::ConvertDB::Base;
use Getopt::Long;
use FindBin;
use File::Spec;
use lib ('lib', 'extlib', "$FindBin::Bin/lib", "$FindBin::Bin/extlib");
use vars qw( $l4p );

sub run {

    GetOptions(
        "old:s"     => \my($old_config),
        "new:s"     => \my($new_config),
        "type:s@"   => \my($types),
        'save'      => \my($save),
        'init-only' => \my($init_only),
    );

    ###l4p $l4p ||= get_logger();

    my $cfgmgr = MT::ConvertDB::ConfigMgr->new(
        old => $old_config,
        new => $new_config,
    );
    my $classmgr   = MT::ConvertDB::ClassMgr->new();
    my $class_objs = $classmgr->class_objects($types);

    if ( $init_only ) {
        $l4p->info('Initialization done.  Exiting due to --init-only');
        exit;
    }

    try {
        local $SIG{__WARN__} = sub { print "**** WARNING: $_[0]\n" };

        foreach my $classobj ( @$class_objs ) {

            $classobj->class->remove_all() or die "Couldn't remove all rows from new database";

            $cfgmgr->use_old_database();

            my $iter = $classobj->get_iter;

            while (my $obj = $iter->()) {
                $obj = $classobj->process_object($obj);
                # die;
                CORE::print '.' unless $l4p->is_debug;
                if ( $save ) {
                    if ($l4p->is_debug()) {
                        $l4p->debug(sprintf( 'Saving %s%s', $classobj->type, ( $obj->has_column('id') ? ' ID '.$obj->id : '.' )));
                    }
                    else {
                        CORE::print '.';
                    }
                    $cfgmgr->use_new_database();
                    unless ($obj->save) {
                        CORE::print "\n" unless $l4p->is_debug;
                        $l4p->error("ERROR: Failed to save record for class ".$classobj->class
                                     . ": " . ($obj->errstr||'UNKNOWN ERROR'));
                        $l4p->error('Object: '.p($obj));
                        exit 1;
                    }
                    $cfgmgr->use_old_database();
                }
                else {
                    $l4p->debug(sprintf( '(NOT) Saving %s%s', $classobj->class, ( $obj->has_column('id') ? ' ID '.$obj->id : '.' )));
                }
            }
            $cfgmgr->use_new_database();
            CORE::print "\n" unless $l4p->is_debug;
            $classobj->post_load;
        }
        $cfgmgr->use_new_database();
        $classmgr->post_load;
        $l4p->info("Done copying data! All went well.");
    }
    catch {
        $l4p->error("An error occurred while loading data: $_");
        exit 1;
    };
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
