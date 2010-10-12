package Feersum::Connection::Handle;
use strict;

sub new {
    Carp::croak "Cannot instantiate Feersum::Connection::Handles directly";
}

package Feersum::Connection::Reader;
use strict;
use base 'Feersum::Connection::Handle';

sub write { Carp::croak "can't call write() on a read-only handle" }

package Feersum::Connection::Writer;
use strict;
use base 'Feersum::Connection::Handle';

sub read { Carp::croak "can't call read() on a write-only handle" }
sub seek { Carp::croak "can't call seek() on a write-only handle" }

package Feersum::Connection::Handle;

1;
__END__

=head1 NAME

Feersum::Connection::Handle - PSGI-style reader/writer objects.

=head1 SYNOPSIS

For read handles:

    my $buf;
    my $r = delete $env{'psgi.input'};
    $r->read($buf, 1, 1); # read the second byte of input without moving offset
    $r->read($buf, $env{CONTENT_LENGTH}); # append the whole input
    $r->close(); # discards any un-read() data

    # assuming the handle is "open":
    $r->seek(2,SEEK_CUR); # returns 1, discards skipped bytes
    $r->seek(-1,SEEK_CUR); # returns 0, can't seek back
    
    # not yet supported, throws exception:
    # $r->poll_cb(sub { .... });

For write handles:

    $w->write("scalar");
    $w->write(\"scalar ref");
    $w->poll_cb(sub {
        # use $_[0] instead of $w to avoid a closure
        $_[0]->write(\"some data");
        # can close() or unregister the poll_cb in here
        $_[0]->close();
    });

For both:

    $h->response_guard(guard { response_is_complete() });

=head1 DESCRIPTION

See the L<PSGI> spec for more information on how read/write handles are used
(The Delayed Response and Streaming Body section has details on the writer).

=head1 METHODS

=head2 Reader methods

The reader is obtained via C<< $env->{'psgi.input'} >>.

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

Seeking is partially supported.  Feersum discards skipped-over bytes to
conserve memory.

    $r->seek(0,SEEK_CUR);  # returns 1
    $r->seek(-1,SEEK_CUR); # returns 0
    $r->seek(-1,SEEK_SET); # returns 0
    $r->seek(2,SEEK_CUR); # returns 1, discards skipped bytes
    $r->seek(42,SEEK_SET); # returns 1 if room, discards skipped bytes
    $r->seek(-8,SEEK_END); # returns 1 if room, discards skipped bytes

=item C<< $r->close() >>

Discards the remainder of the input buffer.

=item C<< $r->poll_cb(sub { .... }) >>

B<NOT YET SUPPORTED>.  PSGI only defined poll_cb for the Writer object.

=back

=head2 Writer methods.

The writer is obtained under PSGI by sending a code/headers pair to the
"starter" callback.  Under Feersum, calls to C<< $req->start_streaming >>
return one.

=over 4

=item C<< $w->write("scalar") >>

Send the scalar as a "T-E: chunked" chunk.

The calls to C<< $w->write() >> will never block and data is buffered until
transmitted.  This behaviour is indicated by C<psgix.output.buffered> in the
PSGI env hash (L<Twiggy> supports this too, for example).

=item C<< $w->write(\"scalar ref") >>

Works just like C<write("scalar")> above.  This extension is indicated by
C<psgix.body.scalar_refs> in the PSGI env hash.

=item C<< $w->close() >>

Close the HTTP response (which triggers the "T-E: chunked" terminating chunk
to be sent).  This method is implicitly called when the last reference to the
writer is dropped.

=item C<< $w->poll_cb(sub { .... }) >>

Register a callback to be called when the write buffer is empty.  Pass in
C<undef> to unset.  The sub can call C<close()>.

A reference to the writer is passed in as the first and only argument to the
sub.  It's recommended that you use C<$_[0]> rather than closing-over on C<$w>
to prevent a circular reference.

=back

=head2 Common methods.

Methods in common to both types of handles.

=over 4

=item C<< $h->response_guard($guard) >>

Register a guard to be triggered when the response is completely sent and the
socket is closed.  A "guard" in this context is some object that will do
something interesting in its DESTROY/DEMOLISH method. For example, L<Guard>.

The guard is *not* attached to this handle object; the guard is attached to
the response.

C<psgix.output.guard> is the PSGI-env extension that indicates this method.

=back

=head1 AUTHOR

Jeremy Stashewsky, C<< stash@cpan.org >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Jeremy Stashewsky & Socialtext Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.7 or,
at your option, any later version of Perl 5 you may have available.

=cut
