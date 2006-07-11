#!perl

use Test::More;

use strict;
use warnings;

use Test::Exception;

use JavaScript;

my ($engine_version) = (JavaScript->get_engine_version())[1] =~ /(\d+\.\d+)/;
if ($engine_version <= 1.5) {
    plan tests => 12;
}
else {
    plan skip_all => "No support for error handler when using SpiderMonkey > 1.5";
}

my ($message, $filename, $lineno, $linebuf);

sub error_handler {
    ($message, $filename, $lineno, $linebuf) = @_;
}

my $rt1 = JavaScript::Runtime->new();
my $cx1 = $rt1->create_context();

$cx1->eval("error;");
is($message, undef);
is($filename, undef);
is($lineno, undef);
is($linebuf, undef);

$cx1->set_error_handler(\&error_handler);
$cx1->eval(q!syntax error;!);
like($message, qr/SyntaxError/);
is($filename, "main line 36");
is($lineno, 1);
is($linebuf, "syntax error;");

($message, $filename, $lineno, $linebuf) = (undef) x 4;
$cx1->set_error_handler(undef);
$cx1->eval(q!syntax error;!);
is($message, undef);
is($filename, undef);
is($lineno, undef);
is($linebuf, undef);
