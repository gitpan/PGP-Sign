# Makefile.PL for PGP::Sign module
# $Id: Makefile.PL,v 0.3 1998/07/05 10:45:36 eagle Exp $
use ExtUtils::MakeMaker;
WriteMakefile (NAME         => 'PGP::Sign',
	       DISTNAME     => 'PGP-Sign',
               VERSION_FROM => 'Sign.pm',
	       dist         => { COMPRESS => 'gzip', SUFFIX => 'gz' });
