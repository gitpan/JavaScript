#!perl

use Test::More tests => 10;

use strict;
use warnings;

use Test::Exception;

use JavaScript;

my $rt1 = JavaScript::Runtime->new();
my $cx1 = $rt1->create_context();

lives_ok { $cx1->bind_function( name => 'foo.bar.baz', func => sub { return 8 } ) };
lives_ok { $cx1->bind_value( 'egg.spam.spam' => "urrrgh" ) };

is( $cx1->eval(q!foo.bar.baz()!), 8, "got 8" );
is( $cx1->eval(q!egg.spam.spam!), 'urrrgh', "beans are off" );

lives_ok { $cx1->bind_value( spam => 'urrrgh' ) };
is( $cx1->eval(q!spam!), 'urrrgh', "beans are off" );
is( $cx1->eval(q!foo.bar.baz()!), 8, "got 8" );

lives_ok { $cx1->bind_value( 'egg.yolk.spam' => "got me?" ) };

is( $cx1->eval(q!egg.yolk.spam!), 'got me?', "beans are off" );
is( $cx1->eval(q!egg.spam.spam!), 'urrrgh', "beans are off" );

