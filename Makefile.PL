# Makefile.PL for PGP::Sign module  -*- perl -*-
# $Id: Makefile.PL,v 0.4 1998/11/26 11:04:01 eagle Exp $
use ExtUtils::MakeMaker;
WriteMakefile (
    NAME         => 'PGP::Sign',
    DISTNAME     => 'PGP-Sign',
    PL_FILES     => { 'makepm.PL' => 'PGP/Sign.pm' },
    PM           => { 'PGP/Sign.pm' => '$(INST_LIBDIR)/Sign.pm' },
    VERSION_FROM => 'VERSION.pm',
    dist         => { COMPRESS => 'gzip', SUFFIX => 'gz' },
    realclean    => { FILES => 'PGP/Sign.pm' }
);
