use Test;
use strict;

# How many tests
BEGIN { plan tests => 1 };

# Load JavaScript module
use JavaScript;

# First test, JavaScript has set up properly

# Create a new runtime
my $runtime = new JavaScript::Runtime();

# Create a new context
my $context = $runtime->create_context();

my $rval = $context->eval_file("t/t70file.js");

ok(0) unless($rval == 51200);
ok(1);
