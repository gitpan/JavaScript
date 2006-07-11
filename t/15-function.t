#!perl

use Test::More tests => 7;

use strict;
use warnings;

use JavaScript;

ok( my $rt1 = JavaScript::Runtime->new(), "created runtime" );
ok( my $cx1 = $rt1->create_context(), "created context" );

{
    my $context = $cx1;
    ok(
       !$cx1->bind_function(
                            name => 'test',
                            func => sub {
                                my $rv = $_[0]->();
                                ok( $rv, $rv ); $rv }
                        ),
       "bound function"
   );
}

$cx1->bind_function(
                    name => 'debug',
                    func => sub { warn Dumper(@_) });
my $code = <<EOC;

function perl_apply() {
    var args = new Array()
    for (var i = 0; i < arguments.length; i++) {
        args.push(arguments[i]);
    }

    var func = args.shift();
    return func.apply(func,args);
}

function testFunc() {
  return "called test function from perl space okay";
}

test( testFunc );

EOC
ok( my $rv = $cx1->eval( $code ), "eval'd code" );
is( $rv, "called test function from perl space okay", "roundtrip");

SKIP: {
    eval "use List::Util";
    skip ("List::Util is not installed", 1) if $@;
    no warnings 'once';
    is ($cx1->call('perl_apply', sub { return List::Util::reduce { $a + $b } @_ },
                   1, 2, 3, 4),
        10, 'invoke perlsub from javascript');
}
