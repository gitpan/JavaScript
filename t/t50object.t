package Foo;
use strict;
use warnings;
sub new { return bless {}, __PACKAGE__; }
sub bar { 
	my $self = shift; 
	return 5; 
}

sub baz { 
	my $self = shift; 
	return "five"; 
}

sub getWrap {
    my ($self) = @_;
    $self->{"getter_called"} = 1;
    $self->{"wrapped"};
}

sub setWrap {
    my ($self,$value) = @_;
    $self->{"setter_called"} = 1;
    $self->{"wrapped"} = $value;
}

use Test;
use strict;

# How many tests
BEGIN { plan tests => 16  };

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
        properties => {
            std => 0,
            wrapped_value => {
                flags => JS_PROP_ACCESSOR,
                setter => Foo->can('setWrap'),
                getter => Foo->can('getWrap'),
            },  
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

$context->eval(q{
FooSan.std = 1;
});

ok($foo->{std} == 1);

$foo->{std} = 3;

ok($context->eval(q{ FooSan.std }) == 3);





$context->eval(q!
FooSan.wrapped_value = 1;
!);

ok($foo->{"setter_called"});


ok($foo->{wrapped} == 1);


ok($context && ref($context)); # somehow disappeared during development

$foo->{wrapped} = 2;

ok($context->eval(q{
    FooSan.wrapped_value
}) == 2);
ok($foo->{"getter_called"});

ok($context && ref($context)); # somehow disappeared during development


$context->eval(q{
FooSan.wrapped_value = FooSan.wrapped_value + 1;
});
ok($foo->{"getter_called"});

ok($context && ref($context)); # somehow disappeared during development


ok($foo->{wrapped} == 3);


