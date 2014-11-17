package MT::ConvertDB::ToolSet;

use base 'ToolSet';

BEGIN { die "MT_HOME environment not set " unless $ENV{MT_HOME} }

use lib (
    "$ENV{MT_HOME}/lib",
    "$ENV{MT_HOME}/extlib",
    "$ENV{MT_HOME}/lib/addons/Log4MT.plugin/lib",
    "$ENV{MT_HOME}/plugins/ConvertDB/lib"
);

ToolSet->use_pragma('strict');
ToolSet->use_pragma('warnings');
ToolSet->use_pragma(qw(feature :5.16));

# define exports from other modules
ToolSet->export(
    'Carp' => [qw( croak carp longmess cluck confess )],    # get the defaults
         # 'Scalar::Util'         => 'blessed',   # or a specific list
    'Try::Tiny'            => undef,
    'Data::Printer'        => undef,
    'Path::Tiny'           => undef,
    'MT::Logger::Log4perl' => [qw( l4mtdump get_logger :resurrect )],
    'Moo'                  => undef,
    'Sub::Quote'           => 'quote_sub',
    'Module::Runtime'      => [qw( use_module use_package_optimistically )],
);

# define exports from this module
# our @EXPORT = qw( shout );
# sub shout { print uc shift };

1;    # modules must return true
