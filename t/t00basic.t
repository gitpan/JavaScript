use strict;
use Test;

use Data::Dumper qw(Dumper);

# How many tests
BEGIN { plan tests => 8 };

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

# Eval a calculation, no variables involved
{
	my $rval = $context->eval("2+2");
	ok(0) unless($rval == 4);
	ok(1);
}

# Eval a calculation using 2 variables and storing the result in a third
{
	my $code = <<CODE;
var a = 10;
var b = 20;

var c = a * b;

c;
CODE

	my $rval = $context->eval($code);
	ok(0) unless($rval == 200);
	ok(1);
}

# Call a function that does some calc, then return the result
{
	my $code = <<CODE;
function test(a, b, c) {
  var ret = 0;

  for(i = 0; i < c; i++) {
	ret += a*b;
  }

  return ret;
}

result = test(2,2,4);
result;
CODE

	my $rval = $context->eval($code);
	ok(0) unless($rval == 16);
	ok(1);
}

# Try 
# Try export of arrays
{
	my $code = <<CODE;
var a = [1,2,3,4];

a;
CODE

	my $rval = $context->eval($code);
	ok(0) unless(join(",",@$rval) eq '1,2,3,4');
	ok(1);
}

# Try export of anonymous objects
{
	my $code = <<CODE;
var obj = { key1: 'ok', key2: 'ok' };

obj;
CODE

	my $rval = $context->eval($code);
	ok(0) unless(exists $rval->{key1} && exists $rval->{key2});
	ok(0) unless($rval->{key1} eq 'ok' && $rval->{key2} eq 'ok');
	ok(1);
}
