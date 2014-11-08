package Test::MT::ConvertDB::Compile;

use FindBin qw( $Bin );
use lib "$Bin/../lib";
use Test::use::ok;
use Test::More;

done_testing( 6 );

use ok 'MT::ConvertDB::Base';
use ok 'MT::ConvertDB::Toolset';
use ok 'MT::ConvertDB::CLI';
use ok 'MT::ConvertDB::ClassMgr';
use ok 'MT::ConvertDB::ConfigMgr';
use ok 'MT::ConvertDB::DBConfig';

