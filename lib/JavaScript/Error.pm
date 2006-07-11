package JavaScript::Error;

use strict;
use warnings;

use overload q{""} => 'as_string', fallback => 1;

sub as_string {
    my $self = shift;
    return "$self->{message} at $self->{fileName} in $self->{lineNumber}";
}

sub message {
    return $_[0]->{message};
}

sub file {
    return $_[0]->{fileName};
}

sub line {
    return $_[0]->{lineNumber};
}

1;
__END__

=head1 NAME

JavaScript::Error - Encapsulates errors thrown from JavaScript

=head1 INTERFACE

=head2 INSTANCE METHODS

=over 4

=item message

The cause of the exception.

=item file

The name of the file that the caused the exception.

=item line

The line number in the file that caused the exception.

=item as_string

A stringification of the exception in the format C<$message at $line in $file>

=back

=head1 OVERLOADED OPERATIONS

This class overloads stringification an will return the result from the method C<as_string>.

=cut
