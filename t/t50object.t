package Foo;
use strict;

sub new { return bless {}, __PACKAGE__; }
sub bar { 
	my $self = shift; 
	return 5; 
}

sub baz { 
	my $self = shift; 
	return "five"; 
}

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

$context->bind_class(
	name => 'Foo',
	constructor => sub { return new Foo(); },
	methods => {
		bar => \&Foo::bar,
		baz => \&Foo::baz,
	},
	package => 'Foo'
);

my $foo = new Foo();

$context->bind_function(
	name => 'print', 
	func => sub { 
		my $dt = shift; 
		return undef; 
	}
);

$context->bind_object('FooSan', $foo);

ok(1);

$context->eval(q!
a = FooSan.bar();
print(a);
!);

ok(1);
