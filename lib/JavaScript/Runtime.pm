package JavaScript::Runtime;

use strict;
use warnings;

sub new {
    my ($pkg, $maxbytes) = @_;

    $pkg = ref $pkg || $pkg;
    
    $maxbytes = $JavaScript::MAXBYTES unless(defined $maxbytes);

    my $runtime = jsr_create($maxbytes);
    my $self = bless { _impl => $runtime }, $pkg;
    
    return $self;
}

sub _destroy {
    my $self = shift;
    return unless $self->{'_impl'};
    jsr_destroy($self->{'_impl'});
    delete $self->{'_impl'};
    return 1;
}

sub DESTROY {
    my ($self) = @_;
    $self->_destroy();
    delete $self->{_error_handler};
}

sub create_context {
    my ($self, $stacksize) = @_;

    $stacksize = $JavaScript::STACKSIZE unless(defined($stacksize));
    my $context = JavaScript::Context->new($self, $stacksize);

    return $context;
}

sub set_interrupt_handler {
    my ($rt, $handler) = @_;

    if ($handler && ref $handler eq '') {
        my $caller_pkg = caller;
        $handler = $caller_pkg->can($handler);
    }
    
    jsr_set_interrupt_handler($rt->{_impl}, $handler);
}

1;
__END__

=head1 NAME

JavaScript::Runtime -

=head1 DESCRIPTION

=head1 INTERFACE

=head2 CLASS METHODS

=over 4

=item new ( $maxbytes )

Creates a new runtime object. The optional argument I<$maxbytes> specifies the number
of bytes that can be allocated before garbage collection is runned. If ommited it
defaults to 1MB.

=back

=head2 INSTANCE METHODS

=over 4

=item create_context ( $stacksize )

Creates a new C<JavaScript::Context>-object in the runtime. The optional argument
I<$stacksize> specifies number of bytes to allocate for the execution stack for the
script. If omitted it defaults to 32KB.

=item set_interrupt_handler ( $handler )

Attaches an interrupt handler (a function that is called before each op is
executed ) to the runtime. The argument I<$handler> must be either a code-reference
or the name of a subroutine in the calling package.

To remove the handler call this method with an undef as argument.

Note that attaching an interrupt handler to the runtime causes a slowdown in
execution speed since we must execute some Perl code between each op.

In order to abort execution your handler should a false value (such as 0). All true values will continue
execution. Any exceptions thrown by the handler are ignored and $@ is cleared.

=back

=begin PRIVATE

=head1 PRIVATE INTERFACE

=over 4

=item _destroy

Method that deallocates the runtime.

=item DESTORY

Called when the runtime is destroyed by Perl.

=item jsr_create ( int maxbytes )

Creates a runtime and returns a pointer to a C<PJS_Runtime> structure.

=item jsr_destroy ( PJS_Runtime *runtime )

Destorys the runtime and deallocates the memory occupied by it.

=item jsr_set_interrupt_handler ( PJS_Runtime *runtime, SV *handler)

Attaches an interrupt handler to the runtime. No check is made to see if I<handler> is a valid SVt_PVCV.

=back

=end PRIVATE

=head1 SEE ALSO

L<JavaScript::Context>

=cut

