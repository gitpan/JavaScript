use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

# Make sure we know what platform we are compiling for
if($^O eq 'MSWin32') {
	$define = "-DXP_PC";
} else {
	$define = "-DXP_UNIX";
}

WriteMakefile(
    'NAME'		=> 'JavaScript',
    'VERSION_FROM'	=> 'JavaScript.pm', # finds $VERSION
    'PREREQ_PM'		=> {}, # e.g., Module::Name => 1.1
    ($] >= 5.005 ?    ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM => 'JavaScript.pm', # retrieve abstract from module
       AUTHOR     => 'A. U. Thor <a.u.thor@a.galaxy.far.far.away>') : ()),
    'LIBS'		=> ['-ljs'], # e.g., '-lm'
    'DEFINE'		=> $define, # e.g., '-DHAVE_SOMETHING'
	# Insert -I. if you add *.h files later:
    'INC'		=> '', # e.g., '-I/usr/include/other'
	# Un-comment this if you add C files to link with later:
    # 'OBJECT'		=> '$(O_FILES)', # link all the C files too
);
