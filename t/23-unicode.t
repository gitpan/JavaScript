#!perl

use Test::More;

use strict;
use warnings;

use JavaScript;

if (JavaScript->does_handle_utf8) {
    plan tests => 5;
}
else {
    plan skip_all => "No unicode support in SpiderMonkey";
}

my $runtime = new JavaScript::Runtime();
my $context = $runtime->create_context();

is( $context->eval(q!"\251"!), "\x{a9}", "got &copy;" );
is( $context->eval(q!"\xe9"!), "\x{e9}", "got e-actute" );
is( $context->eval(q!"\u2668"!), "\x{2668}", "got hot springs" );

$context->eval( 'copy = "\251" ');
is( $context->eval(q!copy!), "\x{a9}", "got &copy;" );

$context->bind_value( copy2 => "\251" );
is( $context->eval(q!copy2!), "\x{a9}", "got &copy;" );

