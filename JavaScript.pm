package JavaScript::Script;
use strict;

sub new {
	my $class = shift;
	my $self = bless {}, $class;
	my $context = shift;
	my $source = shift;
	$self->{impl} = CompileScriptImpl($context, $source);
	return $self;
}

sub exec {
	my $self = shift;
	my $rval =  ExecuteScriptImpl($self->{impl});
	return $rval;
}

package JavaScript::Context;
use strict;

sub new {
	my ($class, $rt, $stacksize) = @_;
	$stacksize = $JavaScript::STACKSIZE unless(defined $stacksize);
	my $self = bless {}, $class;
	$self->{impl} = CreateContext($rt, $stacksize);
	return $self;
}

sub eval {
	my ($self, $script) = @_;
	my $rval = EvaluateScriptImpl($self->{impl}, $script);
	return $rval;
}

sub call {
	my $self = shift;
	my $func_name = shift;
	my $args = [];
	push(@$args, $_) foreach(@_);
	my $rval = CallFunctionImpl($self->{impl}, $func_name, $args);
	rerturn $rval;
}

# Functions for binding perl stuff into JS namespace
sub bind_function {
	my $self = shift;
	my %args = @_;

	# Check for name
	die "Missing argument 'name'\n" unless(exists $args{name});
	die "Argument 'name' must match /^[A-Za-z0-9_]+\$/" unless($args{name} =~ /^[A-Za-z0-9\_]+$/);

	# Check for func
	die "Missing argument 'func'\n" unless(exists $args{func});
	die "Argument 'func' is not a CODE reference\n" unless(ref($args{func}) eq 'CODE');
	my $rval = BindPerlFunctionImpl($self->{impl}, $args{name}, $args{func});	
	return $rval;
}

sub bind_class {
	my $self = shift;
	my %args = @_;

	# Check if name argument is valid
	die "Missing argument 'name'\n" unless(exists $args{name});
	die "Argument 'name' must match /^[A-Za-z0-9_]+\$/" unless($args{name} =~ /^[A-Za-z0-9\_]+$/);

	# Check if constructor is supplied and it's an coderef
	die "Missing argument 'constructor'\n" unless(exists $args{constructor});
	die "Argument 'constructor' is not a code reference\n" unless(ref($args{constructor}) eq 'CODE');

	# Check if we've supplied a methods mapping
	if(exists $args{methods}) {
		die "Argument 'methods' is not a hash reference\n" unless(ref($args{methods}) eq 'HASH');

		# Make sure that all methods are coderefs
		foreach(keys %{$args{methods}}) {
			die "Defined method '$_' is not a code reference\n" unless(ref($args{methods}->{$_}) eq 'CODE');
		}
	} else {
		# BindPerlClassImpl always expects a hash reference
		$args{methods} = {};
	}

	# Check properties we've supplied
	if(exists $args{properties}) {
		die "Argument 'properties' must be a hash reference\n" unless(ref($args{properties}) eq 'HASH');
		
		# Make sure that all methods are valid, ie. they must be of integer type
		foreach(keys %{$args{properties}}) {
			die "Defined property '$_' is not numeric\n" unless($args{properties}->{$_} =~ /^\d+$/);
		}
	} else {
		$args{properties} = {};
	}

	if(exists $args{flags}) {
		die "Argument 'flags' is not numeric\n" unless($args{flags} =~ /^\d+$/);
	} else {
		$args{flags} = 0;
	}

	unless(exists $args{blessed}) {
		$args{blessed} = "";
	}

	my $rval = BindPerlClassImpl($self->{impl}, $args{name}, $args{constructor}, $args{methods}, $args{properties}, $args{blessed}, $args{flags});
	return $rval;
}

sub bind_object {
	my ($self, $name, $jsclass, $object) = @_;

	my $rval = BindPerlObject($self->{impl}, $name, $jsclass, $object);
	return $rval;
}

sub set_error_handler {
	my $self = shift;
	my %args = @_;

	die "Argument 'type' doesn't exist\n" unless(exists $args{type});

	if(lc($args{type}) eq 'callback') {
		die "Argument 'callback' is not a code reference\n" unless(ref($args{callback}) eq 'CODE');
	} elsif(lc($args{type}) eq 'variable') {
		die "Argument 'variable' is not a scalar ref\n" unless(ref($args{variable}) eq '');
	}
}

sub compile {
	my $self = shift;
	my $source = shift;

	my $script = new JavaScript::Script($self->{impl}, $source);
	return $script;
}

package JavaScript::Runtime;

sub new {
	my ($class, $maxbytes) = @_;

	$maxbytes = $JavaScript::MAXBYTES unless(defined $maxbytes);

	my $self = bless {}, $class;

	$self->{'impl'} = JavaScript::Runtime::CreateRuntime($maxbytes);
	return $self;
}

sub DESTROY {
	my ($self) = @_;
}

sub new_context {
	my $self = shift;
	my %attrs = @_;
	my $stacksize = $JavaScript::STACKSIZE unless(defined $attrs{stacksize});
	my $context = new JavaScript::Context($self->{'impl'}, $stacksize);
	return $context;
}

package JavaScript;

use 5.006;
use strict;
use warnings;
use Carp;

require Exporter;
require DynaLoader;
use AutoLoader;

our @ISA = qw(Exporter DynaLoader);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration	use JavaScript ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [ qw(
	JS_PROP_PRIVATE 
	JS_PROP_READONLY	
	JS_CLASS_NO_INSTANCE
) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(
	JS_PROP_PRIVATE
	JS_PROP_READONLY
	JS_CLASS_NO_INSTANCE
);

our $VERSION = '0.5';

use vars qw($STACKSIZE $MAXBYTES $INITIALIZED);

use constant JS_PROP_PRIVATE => 0x1;
use constant JS_PROP_READONLY => 0x2;
use constant JS_CLASS_NO_INSTANCE => 0x1;

BEGIN {
	$MAXBYTES = 1024 ** 2;
	$STACKSIZE = 32 * 1024;
}

sub AUTOLOAD {
    # This AUTOLOAD is used to 'autoload' constants from the constant()
    # XS function.  If a constant is not found then control is passed
    # to the AUTOLOAD in AutoLoader.

    my $constname;
    our $AUTOLOAD;
    ($constname = $AUTOLOAD) =~ s/.*:://;
    croak "& not defined" if $constname eq 'constant';
    my $val = constant($constname, @_ ? $_[0] : 0);
    if ($! != 0) {
	if ($! =~ /Invalid/ || $!{EINVAL}) {
	    $AutoLoader::AUTOLOAD = $AUTOLOAD;
	    goto &AutoLoader::AUTOLOAD;
	}
	else {
	    croak "Your vendor has not defined JavaScript macro $constname";
	}
    }
    {
	no strict 'refs';
	# Fixed between 5.005_53 and 5.005_61
	if ($] >= 5.00561) {
	    *$AUTOLOAD = sub () { $val };
	}
	else {
	    *$AUTOLOAD = sub { $val };
	}
    }

    goto &$AUTOLOAD;
}

bootstrap JavaScript $VERSION;

1;
__END__

# Below is the stub of documentation for your module. You better edit it!
=head1 NAME

JavaScript - Perl extension for executing embedded JavaScript
