package Feersum::Connection::Handle;
use strict;

sub new {
    Carp::croak "Cannot instantiate Feersum::Connection::Handles directly";
}

package Feersum::Connection::Reader;
use strict;
use base 'Feersum::Connection::Handle';

sub write { Carp::croak "can't call write method on a read-only handle" }

sub seek { Carp::carp "seek not supported."; return 0 }

package Feersum::Connection::Writer;
use strict;
use base 'Feersum::Connection::Handle';

sub read { Carp::croak "can't call read method on a write-only handle" }

package Feersum::Connection::Handle;

1;
__END__

=head1 NAME

Feersum::Connection::Handle - PSGI-style reader/writer objects.

=head1 SYNOPSIS

For read handles:

    my $buf;
    my $r = delete $env{'psgi.input'};
    $r->read($buf, $env{CONTENT_LENGTH});
    $r->close(); # discards any un-read() data
    
    # emits a warning and returns 0:
    $r->seek(....);
    
    # not yet supported, throws exception:
    # $r->poll_cb(sub { .... });

For write handles:

    $w->write("scalar");
    $w->write(\"scalar ref");
    $w->poll_cb(sub {
        # use $_[0] instead of $w to avoid a circular-reference.
        $_[0]->write(\"some data");
        # can close() or unregister the poll_cb in here
    });
    $w->close();

=head1 DESCRIPTION

See the L<PSGI> spec for more information on how read/write handles are used
(The Delayed Response and Streaming Body section has details on the writer).

=head1 METHODS

=head2 Reader methods

The reader is obtained via C<< $env{'psgi.input'} >>.

=over 4

=item C<< $r->read($buf, $len) >>

Read the first C<$len> bytes of the request body into the buffer specified by
C<$buf> (similar to how sysread works).

The calls to C<< $r->read() >> will never block.  Currently, the entire body
is read into memory (or perhaps to a temp file) before the Feersum request
handler is even called.  This behaviour B<MAY> change. Regardless, Feersum
will be doing some buffering so C<psgix.input.buffered> is set in the PSGI env
hash.

=item C<< $r->seek(...) >>

Seeking is not supported.  Feersum discards input data to conserve memory,
but only after it has been read.

=item C<< $r->close() >>

Discards the remainder of the input buffer.

=item C<< $r->poll_cb(sub { .... }) >>

B<NOT YET SUPPORTED>.  See L<PSGI> for how this could work.

=back

=head2 Writer methods.

=over 4

=item C<< $w->write("scalar") >>

Send the scalar as a "T-E: chunked" chunk.

The calls to C<< $w->write() >> will never block and data is buffered until
transmitted.  This behaviour is indicated by C<psgix.output.buffered> in the
PSGI env hash (L<Twiggy> supports this too, for example).

=item C<< $w->write(\"scalar ref") >>

Works just like C<write()>.  This extension is indicated by
C<psgix.body.scalar_refs> in the PSGI env hash.

=item C<< $w->close() >>

Close the HTTP response (which triggers the "T-E: chunked" terminating chunk
to be sent).

=item C<< $w->poll_cb(sub { .... }) >>

Register a callback to be called when the write buffer is empty.  Pass in
C<undef> to unset.  The sub can call C<close()>.

A reference to the writer is passed in as the first and only argument to the
sub.  It's recommended that you use C<$_[0]> rather than closing-over on C<$w>
to prevent a circular reference.

=back

=head1 AUTHOR

Jeremy Stashewsky, C<< stash@cpan.org >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Jeremy Stashewsky & Socialtext Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.7 or,
at your option, any later version of Perl 5 you may have available.

=cut
