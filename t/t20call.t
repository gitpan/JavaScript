use strict;
use Test;

use Data::Dumper qw(Dumper);

# How many tests
BEGIN { plan tests => 5 };

# Load JavaScript module
use JavaScript;

# First test, JavaScript has set up properly
ok(1);

# Create a new runtime
my $runtime = new JavaScript::Runtime();
ok(1);

# Create a new context
my $context = $runtime->new_context();
my $context2 = $runtime->new_context();
ok(1);

$context->eval(q!
function testfunc(a, b) {
	c = a * b;
	return c;
}
!);

$context2->eval(q!
function testfunc(a, b) {
	c = a + b;
	return c;
}
!);

ok(1);

ok(1)
