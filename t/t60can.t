use Test;
use strict;

# How many tests
BEGIN { plan tests => 2 };

# Load JavaScript module
use JavaScript;

# First test, JavaScript has set up properly

# Create a new runtime
my $runtime = new JavaScript::Runtime();

# Create a new context
my $context = $runtime->create_context();


$context->eval(q!
function test_func(a, b) {
	return a * b + (a * b);
}
!);

if($context->can('test_func')) {
	ok(1);
} else {
	ok(0);
}

unless($context->can('another_func')) {
	ok(1);
} else {
	ok(0);
}
