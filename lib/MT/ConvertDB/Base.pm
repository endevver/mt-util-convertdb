package MT::ConvertDB::Base;

use base 'Import::Base';

$ENV{MT_HOME} = '/Users/jay/Sites/gene.local/html/mt';

use lib (
    "$ENV{MT_HOME}/lib",
    "$ENV{MT_HOME}/extlib",
    "$ENV{MT_HOME}/lib/addons/Log4MT.plugin/lib",
    "$ENV{MT_HOME}/plugins/ConvertDB/lib"
);

our @IMPORT_MODULES = (
    'strict',
    'warnings',
    'Try::Tiny',
    'Data::Printer',
    'Path::Tiny',
    # 'feature'              => [qw( :5.16 )],
    'Scalar::Util'         => [qw( blessed )],
    'MT::Logger::Log4perl' => [qw( l4mtdump get_logger :resurrect )],
    'namespace::clean',
);

our %IMPORT_BUNDLES = (
    with_signatures => [
        'feature' => [qw( signatures )],
        # Put this last to make sure nobody else can re-enable this warning
        '>-warnings' => [qw( experimental::signatures )]
    ],
    Test => [qw( Test::More Test::Deep )],
    Class => [
        # Put this first so we can override what it enables later
        '<Moo',
        'Sub::Quote' => [qw(quote_sub)],
    ],
);

1;
