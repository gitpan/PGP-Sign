# PGP::Sign -- Create a PGP signature for data, securely.  -*- perl -*-
# $Id: Sign.pm,v 0.9 1998/07/05 10:31:55 eagle Exp $
#
# Copyright 1997, 1998 by Russ Allbery <rra@stanford.edu>
#
# This program is free software; you can redistribute it and/or modify it
# under the same terms as Perl itself.
#
#                     THIS IS NOT A GENERAL PGP MODULE
#
# For a general PGP module that handles encryption and decryption, key ring
# management, and all of the other wonderful things you want to do with PGP,
# see the PGP module directory on CPAN.  This module is designed to do one
# and only one thing and do it fast, well, and securely -- create and check
# detached signatures for some block of data.
#
# This above all: to thine own self be true,
# And it must follow, as the night the day,
# Thou canst not then be false to any man.
#                               -- William Shakespeare, _Hamlet_

############################################################################
# Modules and declarations
############################################################################

package PGP::Sign;
require 5.003;

use Exporter ();
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use FileHandle ();
use IPC::Open3 qw(open3);

use strict;
use vars qw(@ERROR @EXPORT @EXPORT_OK @ISA $MUNGE $PGP $TMPDIR $VERSION);

@ISA       = qw(Exporter);
@EXPORT    = qw(pgp_sign pgp_verify);
@EXPORT_OK = qw(pgp_error);

($VERSION = (split (' ', q$Revision: 0.9 $ ))[1]) =~ s/\.(\d)$/.0$1/;


############################################################################
# Global variables
############################################################################

# The path to PGP.  This should probably be set when the module is
# installed.  The default is /usr/local/bin/pgp.
$PGP = '/usr/local/bin/pgp';

# The directory in which temporary files should be created.
$TMPDIR = $ENV{TMPDIR} || '/tmp';

# The text of any errors resulting from the last call to pgp_sign().
@ERROR = ();

# Whether or not to perform some standard munging to make other signing and
# checking routines happy.
$MUNGE = 0;


############################################################################
# Implementation
############################################################################

# This function actually sends the data to a file handle.  It's necessary to
# implement munging (stripping trailing spaces on a line).
{
    my $spaces = '';
    sub output {
        my ($fh, $string) = @_;
        if ($MUNGE) {
            $string = $spaces . $string;
            $string =~ s/ +(\n.)/$1/g;
            my $newline = ($string =~ s/\n$//);
            $string =~ s/( +)$//;
            if ($newline) { $string .= "\n" } else { $spaces = $1 }
        } else {
            $spaces = '';
        }
        print $fh $string;
    }
}

# This is our generic "take this data and shove it" routine, used both for
# signature generation and signature checking.  The first argument is the
# file handle to shove all the data into, and the remaining arguments are
# sources of data.  Scalars, references to arrays, references to FileHandle
# or IO::Handle objects, file globs, references to code, and references to
# file globs are all supported as ways to get the data, and at most one line
# at a time is read (cutting down on memory usage).
#
# References to code are an interesting subcase.  A code reference is
# executed repeatedly, whatever it returns being passed to PGP using the ORS
# specified if any, until it returns undef.
sub write_data {
    my $fh = shift;

    # Deal with all of our possible sources of input, one at a time.  We
    # really want perl 5.004 here, since we want UNIVERSAL::isa().
    # Unfortunately, we can't rely on 5.004 yet.  *But*, the main reason we
    # want isa() is to handle the various derived IO::Handle classes, and
    # 5.003 should only have FileHandle, so we can hack our way around that.
    # We can't do anything interesting or particularly "cool" with
    # references to references, so those we just print.  (Perl allows
    # circular references, so we can't just dereference references to
    # references until we get something interesting.)  Hashes are treated
    # like arrays.
    my $source;
    for $source (@_) {
        if (ref $source eq 'ARRAY' or ref $source eq 'HASH') {
            for (@$source) { output ($fh, $_) }
        } elsif (ref $source eq 'GLOB' or ref \$source eq 'GLOB') {
            local $_;
            while (<$source>) { output ($fh, $_) }
        } elsif (ref $source eq 'SCALAR') {
            output ($fh, $$source);
        } elsif (ref $source eq 'CODE') {
            local $_;
            while (defined ($_ = &$source ())) { output ($fh, $_) }
        } elsif (ref $source eq 'REF') {
            output ($fh, $source);
        } elsif (ref $source)  {
            if ($] > 5.003) {
                if (UNIVERSAL::isa ($source, 'IO::Handle')) {
                    local $_;
                    while (<$source>) { output ($fh, $_) }
                } else {
                    output ($fh, $source);
                }
            } else {
                if (ref $source eq 'FileHandle') {
                    local $_;
                    while (<$source>) { output ($fh, $_) }
                } else {
                    output ($fh, $source);
                }
            }
        } else {
            output ($fh, $source);
        }
    }
}

# Create a detached signature for the given data.  The first argument should
# be a key id and the second argument the PGP passphrase, and then all
# remaining arguments are considered to be part of the data to be signed and
# are handed off to write_data().
#
# In a scalar context, the signature is returned as an ASCII-armored block
# with embedded newlines.  In array context, a list consisting of the
# signature and the PGP version number is returned.  Returns undef in the
# event of an error, and the error text is then stored in @PGP::Sign::ERROR
# and can be retrieved with pgp_error().
sub pgp_sign {
    my $keyid = shift;
    my $passphrase = shift;

    # Ignore SIGPIPE, since we're going to be talking to PGP.
    local $SIG{PIPE} = 'IGNORE';

    # We need to send the password to PGP, but we don't want to use either
    # the command line or an environment variable, since both may expose us
    # to snoopers on the system.  So we create a pipe, stick the password in
    # it, and then pass the file descriptor for the password to PGP via an
    # environment variable.
    my $passfh = new FileHandle;
    my $writefh = new FileHandle;
    pipe ($passfh, $writefh);
    print $writefh $passphrase;
    close $writefh;
    local $ENV{PGPPASSFD} = $passfh->fileno ();

    # Fork off a pgp process that we're going to be feeding data to, and
    # tell it to just generate a signature using the given key id and pass
    # phrase.
    my $pgp = new FileHandle;
    my $signature = new FileHandle;
    my $errors = new FileHandle;
    my @command = ($PGP, '+batchmode', '-sbaft', '-u', $keyid);
    my $pid = eval { open3 ($pgp, $signature, $errors, @command) };
    if ($@) {
        @ERROR = ($@, "Execution of pgp failed.\n");
        return undef;
    }

    # Send the rest of the arguments off to write_data().
    unshift (@_, $pgp);
    &write_data;

    # All done.  Close the pipe to PGP, clean up, and see if we succeeded.
    # If not, save the error output and return undef.
    close $pgp;
    local $/ = "\n";
    my @errors = <$errors>;
    my @signature = <$signature>;
    close $signature;
    close $errors;
    close $passfh;
    waitpid ($pid, 0);
    if ($? != 0) {
        @ERROR = (@errors, "PGP returned exit status $?\n");
        return undef;
    }

    # Now, clean up the returned signature and return it, along with the
    # version number if desired.
    while ((shift @signature) ne "-----BEGIN PGP MESSAGE-----\n") {
        unless (@signature) {
            @ERROR = ("No signature from PGP (command not found?)\n");
            return undef;
        }
    }
    my $version;
    while ($signature[0] ne "\n" && @signature) {
        ($version) = ((shift @signature) =~ /^Version:\s+(.*?)\s*$/);
    }
    shift @signature;
    $#signature = $#signature - 1;
    $signature = join ('', @signature);
    chomp $signature;
    undef @ERROR;
    wantarray ? ($signature, $version) : $signature;
}

# Check a detatched signature for given data.  Takes a signature block (in
# the form of an ASCII-armored string with embedded newlines), a version
# number (which may be undef), and some number of data sources that
# write_data() can handle and returns the key id of the signature, the empty
# string if the signature didn't check, and undef in the event of an error.
# In the event of some sort of an error, we stick the error in @ERROR.
sub pgp_verify {
    my $signature = shift;
    my $version = shift;
    chomp $signature;

    # Ignore SIGPIPE, since we're going to be talking to PGP.
    local $SIG{PIPE} = 'IGNORE';

    # Because this is a detached signature, we actually need to save both
    # the signature and the data to files and then run PGP on the signature
    # file to make it verify the signature.  Because this is a detached
    # signature, though, we don't have to do any data mangling, which makes
    # our lives much easier.  It would be nice to do this without having to
    # use temporary files.  Maybe with PGP 5.0.
    my $umask = umask 077;
    my $filename = $TMPDIR . '/pgp' . time . '.' . $$;
    my $sigfile = new FileHandle "$filename.asc", O_WRONLY|O_EXCL|O_CREAT;
    unless ($sigfile) {
        @ERROR = ("Unable to open temp file $filename.asc: $!\n");
        return undef;
    }
    print $sigfile "-----BEGIN PGP MESSAGE-----\n";
    if (defined $version) { print $sigfile "Version: $version\n\n" }
    print $sigfile $signature;
    print $sigfile "\n-----END PGP MESSAGE-----\n";
    close $sigfile;
    my $datafile = new FileHandle "$filename", O_WRONLY|O_EXCL|O_CREAT;
    unless ($datafile) {
        unlink "$filename.asc";
        @ERROR = ("Unable to open temp file $filename: $!\n");
        return undef;
    }
    unshift (@_, $datafile);
    &write_data;
    close $datafile;

    # Now, call PGP to check the signature.  Because we've written
    # everything out to a file, this is actually fairly simple; all we need
    # to do is grab stdout.  PGP prints its banner information to stderr
    # (??), so just ignore stderr.
    my $command = "$PGP +batchmode $filename.asc $filename";
    my $pgp = new FileHandle "$command 2> /dev/null |";
    unless ($pgp) {
        unlink $filename, "$filename.asc";
        @ERROR = ("Execution of pgp failed: $!\n");
        return undef;
    }

    # Check for the message that gives us the key status and return the
    # appropriate thing to our caller.
    local $_;
    local $/ = "\n";
    my $signer;
    while (<$pgp>) {
        if (/^Good signature from user(?::\s+(.*)|\s+\"(.*)\"\.)$/) {
            $signer = $+;
            last;
        } elsif (/^Bad signature /) {
            last;
        }
    }
    close $pgp;
    undef @ERROR;
    unlink $filename, "$filename.asc";
    umask $umask;
    $signer ? $signer : '';
}

# Return the errors resulting from the last call to pgp_sign() or
# pgp_verify() or the empty list if there are none.
sub pgp_error {
    wantarray ? @ERROR : join ('', @ERROR);
}


############################################################################
# Module return value and documentation
############################################################################

# Make sure the module returns true.
1;

__DATA__

=head1 NAME

PGP::Sign - Create detached PGP signatures for data, securely

=head1 SYNOPSIS

    use PGP::Sign;
    ($signature, $version) = pgp_sign ($keyid, $passphrase, @data);
    $signer = pgp_verify ($signature, $version, @data);
    @errors = PGP::Sign::pgp_error;

=head1 DESCRIPTION

This module is designed to do one and only one thing securely and well;
namely, generate and check detached PGP signatures for some arbitrary data.
It doesn't do encryption, it doesn't manage keyrings, it doesn't verify
signatures, it just signs things.  This is ideal for applications like
PGPMoose or control message generation that just need a fast signing
mechanism.

The interface is very simple; just call pgp_sign() with a key ID, a pass
phrase, and some data, or call pgp_verify() with a signature (in the form
generated by pgp_sign()), a version number (which can be undef if you don't
want to give a version), and some data.  The data can be specified in pretty
much any form you can possibly consider data and a few you might not.
Scalars and arrays are passed along to PGP; references to arrays are walked
and passed one element at a time (to avoid making a copy of the array); file
handles, globs, or references to globs are read a line at a time and passed
to PGP; and references to code are even supported (see below).  About the
only thing that we don't handle are references to references (which are just
printed to PGP, which probably isn't what you wanted) and hashes (which are
treated like arrays, which doesn't make a lot of sense).

If you give either function a reference to a sub, it will repeatedly call
that sub, sending the results to PGP to be signed, until the sub returns
undef.  What this lets you do is pass the function an anonymous sub that
walks your internal data and performs some manipulations on it a line at a
time, thus allowing you to sign a slightly modified form of your data
(with initial dashes escaped, for example) without having to use up memory
to make an internal copy of it.

In a scalar context, pgp_sign() returns the signature as an ASCII armored
block with embedded newlines (but no trailing newline).  In a list
context, it returns a two-element list consisting of the signature as
above and the PGP version that signed it.  pgp_sign() will return undef in
the event of any sort of error.

pgp_verify() returns the signer of the message in the case of a good
signature, the empty string in the case of a bad signature, and undef in
the event of some error.

pgp_error() (which isn't exported by default) returns the error encountered
by the last pgp_sign() or pgp_verify(), or undef if there was no error.  In
a list context, a list of lines is returned; in a scalar context, a long
string with embedded newlines is returned.

Two global variables can be modified:

=over 4

=item $PGP::Sign::PGP

The path to PGP.  This defaults to F</usr/local/bin/pgp>, but may have
been fixed to point at the right place by the module installer during
installation.

=item $PGP::Sign::TMPDIR

The directory in which temporary files are created.  Defaults to TMPDIR if
set, and F</tmp> if not.

=item $PGP::Sign::MUNGE

If this variable is set to a true value, PGP::Sign will automatically
strip trailing spaces when signing or verifying signatures.  This will
make the resulting signatures and verification compatible with programs
that generate attached signatures (since PGP ignores trailing spaces when
generating or checking attached signatures).

=back

=head1 ENVIRONMENT

=over 4

=item TMPDIR

The directory in which to create temporary files.  Can be overridden by
changing $PGP::Sign::TMPDIR.  If not set, defaults to F</tmp>.

=back

=head1 DIAGNOSTICS

Mostly the contents of @PGP::Sign::ERROR (returned by pgp_error()) are
completely determined by PGP.  The only thing that this module may stick
in there is "Execution of PGP failed" if we couldn't fork off a PGP
process and "PGP returned exit status %d" in the event of a non-zero exit
status from PGP.

=head1 BUGS

The implementation of pgp_verify() uses temporary files.  Unfortunately,
given the current implementation of PGP, there isn't any way to avoid
this, since we want to generate detached signatures.  It would be possible
to do everything through pipes if we generated attached signatures, but
then we would have to deal with PGP data munging, which is ugly and
underdocumented.  We also wouldn't be able to work with applications that
want detached signatures, and since we are returning a signature that's
logically detached from the signed data, it doesn't make any sense to have
the signature be of the form used for attached signatures.

=head1 CAVEATS

This module uses a pipe and the environment variable PGPPASSFD to give the
pass phrase to PGP, since this is the only secure method (both command
line switches and environment variables can potentially be read by other
users on the same machine using ps).  This requires a version of PGP that
supports that feature, however.  I know for certain that PGP 2.6.2 does,
but I can't be sure about other versions.

This module forks, uses a pipe, and relies on the ability to pass an open
pipe to an exec()ed subprocess.  This may cause portability problems to
certain substandard operating systems.

The signature generated is a detached signature.  If you intend to pass it
to an application that will attempt to verify it by creating a signed
document (the way pgpverify does), you'll need to set $PGP::Sign::MUNGE
before creating the signature.

=head1 AUTHOR

Russ Allbery E<lt>rra@stanford.eduE<gt>.

=head1 HISTORY

Based heavily on work by Andrew Gierth
E<lt>andrew@erlenstar.demon.co.ukE<gt> and benefitting greatly from input,
comments, suggestions, and help from him, this module came about in the
process of implementing PGPMoose signatures and control message signatures
for Usenet.  PGPMoose is the idea of Greg Rose E<lt>ggr@usenix.orgE<gt>,
and signcontrol and pgpverify are the idea of David Lawrence
E<lt>tale@isc.orgE<gt>.

=cut