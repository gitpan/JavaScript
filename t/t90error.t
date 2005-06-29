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
my $context = $runtime->create_context();
ok(1);

our $test = 0;
$context->set_error_handler( sub { $test++; print "# ", join(':', @_), "\n"; return 1; } );

ok(1);

$context->eval(<<EOP);

"bobabasdfasd";

joe;

EOP

ok($test == 1);
