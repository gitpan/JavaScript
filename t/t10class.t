package Foo;

sub new {
	return bless {}, __PACKAGE__;
}

sub bar {
	my $self = shift;
}

sub baz {
	my $self = shift;
}

use strict;
use Test;

use Data::Dumper qw(Dumper);

# How many tests
BEGIN { plan tests => 4 };

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

$context->bind_class(
	name => 'Foo',
	constructor => \&Foo::new,
	methods => {
		'bar' => \&Foo::bar,
		'baz' => \&Foo::baz,
	},
	package => 'Foo'
);

$context->eval(q!
obj = new Foo();
obj.bar();
obj.baz();
!);

ok(1);
