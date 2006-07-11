#!perl

use Test::More tests => 4;

use warnings;
use strict;

use JavaScript;

my $rt1 = new JavaScript::Runtime();
my $cx1 = $rt1->create_context();

ok( my $foo = $cx1->eval(q!
    foo = { 'bar':1 }
    foo.baz = foo; // scary recursiveness
    foo
  !) );
is( $foo->{baz}, $foo, "recursive structure returned." );

ok( my $bar = $cx1->eval(q!
    foo = [ 'bar' ]
    foo[1] = foo; // scary recursiveness
    foo
  !) );
is( $bar->[1], $bar, "recursive structure returned." );
