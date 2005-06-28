use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

$define = "";
# Make sure we know what platform we are compiling for
if($^O eq 'MSWin32') {
	$define .= " -DXP_PC";
} else {
	$define .= " -DXP_UNIX";
}

my $inc = '';

if(-f "/etc/gentoo-release") {
	# Gentoo puts libjs in a slightly hidden spot.
	$inc = '-I/usr/lib/MozillaFirefox/include/js/ -I/usr/lib/MozillaFirefox/';
}

#test for debian type include files...
if (-f "/usr/include/smjs/jsapi.h" or -f "/usr/local/include/smjs/jsapi.h") {
    $define .= " -DINCLUDES_IN_SMJS"
}

if($ENV{JS_THREADSAFE}) {
  $define .= " -DJS_THREADSAFE";
}

my $lib = "-ljs";
#test for debian type libsmjs
#this could probably be done better, but I'm not sure how to
#get this platform independant
if (-f "/usr/lib/libsmjs.so" or -f "/usr/local/lib/libsmjs.so") {
    $lib = "-lsmjs";
}


WriteMakefile(
    'NAME'		=> 'JavaScript',
    'VERSION_FROM'	=> 'JavaScript.pm', # finds $VERSION
    'PREREQ_PM'		=> {}, # e.g., Module::Name => 1.1
    ($] >= 5.005 ?    ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM => 'JavaScript.pm', # retrieve abstract from module
       AUTHOR     => 'claesjac@cpan.org>') : ()),
    'LIBS'		=> [$lib], # e.g., '-lm'
    'DEFINE'		=> $define, # e.g., '-DHAVE_SOMETHING'
	# Insert -I. if you add *.h files later:
    'INC'		=> $inc, # e.g., '-I/usr/include/other'
	# Un-comment this if you add C files to link with later:
    # 'OBJECT'		=> '$(O_FILES)', # link all the C files too
);
