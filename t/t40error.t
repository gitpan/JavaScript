use Test;
use strict;

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
my $context = $runtime->create_context();
ok(1);

# Compile a script
$context->eval(q!
function test_call(a, b, c) {
  return a * b + c;
}
!);

ok(1);

my $rval = $context->call("test_call", 2, 3, 4);

ok(0) unless($rval == 10);
ok(1);
