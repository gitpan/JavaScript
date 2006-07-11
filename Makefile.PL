use ExtUtils::MakeMaker;

use strict;
use warnings;

# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

# Make sure we know what platform we are compiling for
my @defines;

my $path_separator = ":";
if($^O eq 'MSWin32') {
    push @defines,  "XP_PC";
    $path_separator = ";";
} else {
    push @defines, "XP_UNIX";
}

# Handle threadsafe
if($ENV{JS_THREADSAFE}) {
    push @defines, "JS_THREADSAFE";
}
else {
    my $enable_threadsafe = prompt("Is your SpiderMonkey compiled with JS_THREADSAFE (most things will fail if you answer wrong)? [y/N]");
    push @defines, "JS_THREADSAFE" if $enable_threadsafe eq 'y';
}

# Name of lib to link
my $lib = 'js';

# Directories with include files
my @incs;

# Directories with libraries
my @libs;

#test for debian type libsmjs
#this could probably be done better, but I'm not sure how to
#get this platform independant
if (-f "/usr/lib/libsmjs.so" or -f "/usr/local/lib/libsmjs.so") {
    $lib = "smjs";
}
if (-f "/usr/include/smjs/jsapi.h") {
    push @incs, "/usr/include/smjs/";
    push @defines, "INCLUDES_IN_SMJS";
}
elsif(-f "/usr/local/include/smjs/jsapi.h") {
    push @incs, "/usr/local/include/smjs/";
    push @defines, "INCLUDES_IN_SMJS";
}

# test for gentoo
if(-f "/etc/gentoo-release") {
    # Gentoo puts libjs in a slightly hidden spot.
    @incs = qw(/usr/lib/MozillaFirefox/include/js/
              /usr/lib/MozillaFirefox/);

}

# Override with $ENV{JS_LIB} and $ENV{JS_INC}
if (exists $ENV{JS_LIB}) {
    @libs = get_paths($ENV{JS_LIB});
    $lib = 'js';
}
if (exists $ENV{JS_INC}) {
    @incs = get_paths($ENV{JS_INC});
    @defines = grep { $_ ne 'INCLUDES_IN_SMJS' } @defines;
}

my $libs = join(" ", map { "-L$_" } @libs);

# Check if we need to enable JS_C_STRINGS_ARE_UTF8?
my $enable_utf8 = prompt("Is your SpiderMonkey compiled with support for unicode (t/23-unicode.t will fail if you answer wrong) ? [y/N]", "N");
push @defines, "JS_C_STRINGS_ARE_UTF8" if $enable_utf8 eq 'y';


WriteMakefile('NAME'		=> 'JavaScript',
              'VERSION_FROM'	=> 'lib/JavaScript.pm', # finds $VERSION
              'PREREQ_PM'	=> {
                                    'Test::More' => 0,
                                    'Test::Exception' => 0,
                                }, # e.g., Module::Name => 1.1
              ($] >= 5.005 ?    ## Add these new keywords supported since 5.005
               (ABSTRACT_FROM   => 'lib/JavaScript.pm', # retrieve abstract from module
                AUTHOR          => 'claesjac@cpan.org>') : ()),
              'LIBS'		=> ["$libs -l${lib}"], # e.g., '-lm'
              'DEFINE'		=> join(" ", map { "-D$_"} @defines),
              'INC'		=> join(" ", map { "-I$_" } @incs),
          );

sub get_paths {
    my $paths = shift;
    my @paths = map { s/^\s+//; s/\s+$//; $_ } split/$path_separator/, $paths;
    return @paths;
}
