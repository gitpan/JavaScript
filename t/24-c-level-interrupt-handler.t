#!perl

package JavaScript::Runtime::Opcounted;

use Test::More;
use Test::Exception;

use File::Spec;

eval "require Inline::C";
plan skip_all => "Inline::C is required for testing C-level interrupt handlers" if @$;	

use base qw(JavaScript::Runtime);

my $typemap = File::Spec->catfile($ENV{PWD}, 'typemap');
my $inc = do {
	my @inc_paths = $ENV{PWD};
	if (exists $ENV{JS_INC}) {
		my $sep = $^O eq 'Win32' ? ';' : ':';
		push @inc_paths, split/$sep/, $ENV{JS_INC};
	}
	join(" ", map { "-I$_"} @inc_paths);
};

use Inline Config => FORCE_BUILD => 1;

Inline->bind('C' => <<'END_OF_CODE', TYPEMAPS => $typemap, INC => $inc,	AUTO_INCLUDE => '#include "JavaScript.h"');

struct PJS_Runtime_Opcount {
	int	cnt;
	int limit;
};

typedef struct PJS_Runtime_Opcount PJS_Runtime_Opcount;

static JSTrapStatus _opcounting_interrupt_handler(JSContext *cx, JSScript *script, jsbytecode *pc, jsval *rval, void *closure) {
	PJS_Runtime *rt = closure;
	PJS_Runtime_Opcount *opcnt = (PJS_Runtime_Opcount *) rt->ext;
	opcnt->cnt++;
	if ( opcnt->limit != 0 && opcnt->cnt > opcnt->limit ) {
	      croak("oplimit has been exceeded");
	}
	
	return JSTRAP_CONTINUE;
}

void _init_runtime(PJS_Runtime *rt) {
	PJS_Runtime_Opcount *opcnt;
	
	Newz(1, opcnt, 1, PJS_Runtime_Opcount);
	
	opcnt->cnt = 0;
	opcnt->limit = 100;
	
	rt->ext = (void *) opcnt;
	
	/* Set interrupt handler */
	JS_SetInterrupt(rt->rt, _opcounting_interrupt_handler, rt);
}

void _destroy_runtime(PJS_Runtime *rt) {
	JSTrapHandler 	trap_handler;
    void 			*ptr;

    JS_ClearInterrupt(rt->rt, &trap_handler, &ptr);
    
	Safefree(rt->ext);
	rt->ext = NULL;
}

void _set_opcnt(PJS_Runtime *rt, int cnt) {
	((PJS_Runtime_Opcount *) rt->ext)->cnt = cnt;
}

int _get_opcnt(PJS_Runtime *rt) {
	return ((PJS_Runtime_Opcount *) rt->ext)->cnt;
}

void _set_oplimit(PJS_Runtime *rt, int limit) {
	((PJS_Runtime_Opcount *) rt->ext)->limit = limit;
}

int _get_oplimit(PJS_Runtime *rt) {
	return ((PJS_Runtime_Opcount *) rt->ext)->limit;
}
END_OF_CODE

sub new {
	my $pkg = shift;
	$self = $pkg->SUPER::new(@_);
	_init_runtime($self->{_impl});
	return $self;
}

sub DESTROY {
	my $self = shift;
	_destroy_runtime($self->{_impl});
	$self->SUPER::DESTROY();
}

sub oplimit {
	my $self = shift;
	
	if (@_) {
		_set_oplimit($self->{_impl}, shift);
	}
	return _get_oplimit($self->{_impl});
}

sub opcnt {
	my $self = shift;
	
	if (@_) {
		_set_opcnt($self->{_impl}, shift);
	}
	return _get_opcnt($self->{_impl});
}

plan tests => 5;

my $runtime = JavaScript::Runtime::Opcounted->new();
my $context = $runtime->create_context();

is($runtime->opcnt, 0, 'opcnt is 0');
is($runtime->oplimit, 100, 'oplimit is 100');

$context->eval("1+1");
isnt($runtime->opcnt, 0, "opcnt is > 0. Currently at: " . $runtime->opcnt);

eval {
	$context->eval("for(v = 0; v < 100; v++) { 1 + 1; }");
};
ok($@, "Threw exception");
like($@, qr/exceeded/);

1;

