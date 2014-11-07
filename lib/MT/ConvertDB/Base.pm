package MT::ConvertDB::Base;
use base 'Import::Base';

our @IMPORT_MODULES = (
    'strict',
    'warnings',
    feature => [qw( :5.16 )],
    'Try::Tiny',
    'Data::Printer',
    'Moo',
    'Sub::Quote' => [qw(quote_sub)],
    'lib' => ['lib', 'extlib', 'addons/Log4MT.plugin/lib'],
    'MT::Logger::Log4perl' => [qw( l4mtdump get_logger :resurrect )],
    'namespace::clean',

);

1;
