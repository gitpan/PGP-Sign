# Makefile.PL for PGP::Sign module
# $Id: Makefile.PL,v 0.1 1997/07/27 13:42:01 eagle Exp $
use ExtUtils::MakeMaker;
WriteMakefile (NAME         => 'PGP::Sign',
	       DISTNAME     => 'PGP-Sign',
               VERSION_FROM => 'Sign.pm',
	       dist         => { COMPRESS => 'gzip', SUFFIX => 'gz' });
