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

# Compile a script
my $script = $context->compile(q!
b = Math.random() * 100;
b = b * 2;
b;
!);

ok(1);

my $rval = $script->exec();
$rval = $script->exec();

ok(1);
