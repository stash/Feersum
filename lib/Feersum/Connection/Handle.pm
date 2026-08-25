package Feersum::Connection::Handle;
use warnings;
use strict;
use Carp ();

sub new {
    Carp::croak "Cannot instantiate Feersum::Connection::Handle directly";
}

package Feersum::Connection::Reader;
use warnings;
use strict;
use base 'Feersum::Connection::Handle';
use Scalar::Util ();
# all three conversions explicit: a missing one is generated from the others, and
# bool alone made every reader stringify and numify to 1
use overload
    '<>'     => \&_diamond,
    'bool'   => sub { 1 },
    '""'     => sub { overload::StrVal($_[0]) },
    '0+'     => sub { Scalar::Util::refaddr($_[0]) },
    fallback => 1;

sub write { ## no critic (BuiltinHomonyms)
    Carp::croak "can't call write() on a read-only handle" }
sub write_array {
    Carp::croak "can't call write_array() on a read-only handle" }
sub sendfile {
    Carp::croak "can't call sendfile() on a read-only handle" }

sub getlines {
    my $self = shift;
    Carp::croak "getlines() called in scalar context" unless wantarray;
    my (@lines, $line);
    push @lines, $line while defined($line = $self->getline);
    return @lines;
}

# <> is called in the op's context, so wantarray here is deliberate
sub _diamond {
    my $self = shift;
    return wantarray ? $self->getlines : $self->getline;
}

package Feersum::Connection::Writer;
use warnings;
use strict;
use base 'Feersum::Connection::Handle';

sub read { ## no critic (BuiltinHomonyms)
    Carp::croak "can't call read() on a write-only handle" }
sub seek { ## no critic (BuiltinHomonyms)
    Carp::croak "can't call seek() on a write-only handle" }
sub getline {
    Carp::croak "can't call getline() on a write-only handle" }
sub getlines {
    Carp::croak "can't call getlines() on a write-only handle" }

package Feersum::Connection::Handle;
1;
__END__

=head1 NAME

Feersum::Connection::Handle - PSGI-style reader/writer objects.

=head1 SYNOPSIS

For read handles:

    my $buf;
    my $r = delete $env->{'psgi.input'};
    $r->read($buf, 1, 1); # read the second byte of input without moving offset
    $r->read($buf, $env->{CONTENT_LENGTH}); # append the whole input
    my $line = $r->getline;  # or <$r>: one record, honouring $/
    $r->close(); # discards any un-read() data

    # assuming the handle is "open":
    $r->seek(2,SEEK_CUR); # returns 1, discards skipped bytes
    $r->seek(-1,SEEK_CUR); # returns 0, can't seek back

    $r->poll_cb(sub { .... });

For write handles:

    $w->write("scalar");
    $w->write(\"scalar ref");
    $w->write_array(\@some_stuff);
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

Read up to C<$len> more bytes of the request body and B<append> them to
C<$buf>; unlike Perl's C<read>, C<$buf> is not truncated first, so a drain
loop must use a fresh scalar (or clear it) each time round:

    my $body = '';
    while ($r->read(my $chunk, 4096)) { $body .= $chunk }

Never read into a buffer that outlives the request (a closure variable or a
global): it accumulates, and on a keep-alive connection a later handler can
see an earlier client's body in front of its own.  The same goes for the
reader itself: it wraps the connection, not one request, and kept past its
response it reads the next request's body.

An optional third argument is an offset into the input to read from without
advancing the current position.  Returns the number of bytes read, or 0 at
end of input.

Never blocks: the whole body is buffered before the handler runs (use
C<poll_cb> for incremental delivery).  C<psgix.input.buffered> is still not
set, as that flag also promises a rewindable handle and this one is
forward-only; consumers such as L<Plack::Request> buffer the body themselves
when it is absent.

=item C<< $r->getline() >>

Read one record from the input, following C<readline>/C<< <$fh> >> semantics
for C<$/>: the default C<"\n"> and any plain-string separator return one
record I<including> the separator (the final record may lack it),
C<local $/ = undef> slurps all remaining input, C<\$n> reads fixed-size
records, and C<""> reads paragraphs.  Returns C<undef> at end of input.
Like C<read()>, it never blocks, and it stops at the end of the current
request's body.

=item C<< $r->getlines() >>

All remaining records as a list.  Croaks in scalar context, as
L<IO::Handle/getlines> does.

The reader also overloads C<< <> >> in both contexts:

    my $line  = <$r>;            # one record
    my @lines = <$r>;            # all remaining records (perl 5.18+)
    my $body  = do { local $/; <$r> };   # slurp

Before perl 5.18 an overloaded C<< <> >> does not see list context and
C<< my @lines = <$r> >> yields a single record; use C<getlines> there.

=item C<< $r->seek(...) >>

Seeking is partially supported.  Feersum discards skipped-over bytes to
conserve memory.  B<Note:> SEEK_SET is treated the same as SEEK_CUR (always
relative to the current position), since the underlying buffer is consumed
as it is read and absolute positioning is not supported.

    $r->seek(0,SEEK_CUR);  # returns 1
    $r->seek(-1,SEEK_CUR); # returns 0
    $r->seek(-1,SEEK_SET); # returns 0
    $r->seek(2,SEEK_CUR);  # returns 1, discards 2 bytes
    $r->seek(42,SEEK_SET); # same as SEEK_CUR: discards 42 bytes
    $r->seek(-8,SEEK_END); # returns 1 if room, discards skipped bytes

=item C<< $r->close() >>

Discards the remainder of the input buffer.  It does not affect connection
reuse: when the request body has already been received in full (the usual
case) the connection stays eligible for keep-alive and an already-pipelined
next request is still served.

=item C<< $r->poll_cb(sub { .... }) >>

Register a callback to be called when more request body data is available.
The callback receives the Reader object as its argument.  On a normal
HTTP/1.x or HTTP/2 request the handler runs only after the whole body has
arrived, so the callback drains an already-complete buffer; it becomes a true
incremental reader only after C<io()>/C<psgix.io> takes over the byte stream.
See L<Feersum/"PSGI interface">.

=back

=head2 Writer methods.

The writer is obtained under PSGI by sending a code/headers pair to the
"starter" callback.  Under Feersum, calls to C<< $req->start_streaming >>
return one.

=over 4

=item C<< $w->write("scalar") >>

Send the scalar as a chunk of the streaming response body.  For HTTP/1.1
clients this uses C<Transfer-Encoding: chunked> framing, unless the response
set its own C<Content-Length>: then the body goes out unframed and is held to
that length (bytes past it are dropped; ending short closes the connection).
For HTTP/1.0 (C<Connection: close>) streaming the data is written without
chunk framing.

The calls to C<< $w->write() >> will never block and data is buffered until
transmitted.  This behaviour is indicated by C<psgix.output.buffered> in the
PSGI env hash (L<Twiggy> supports this too, for example).

B<Zero-copy: do not modify a scalar after passing it to C<write()>.>  Feersum
keeps a reference to your scalar and points the pending C<writev()> at its
string buffer, and transmission happens I<after> your handler (or callback)
returns, so modifying the scalar in the meantime changes, or frees, the memory
about to be sent:

    # WRONG - all five chunks arrive as "line 5"
    my $line;
    for my $i (1 .. 5) {
        $line = sprintf("line %d\n", $i);
        $w->write($line);
    }

    # RIGHT - a fresh scalar per write
    for my $i (1 .. 5) {
        $w->write(sprintf("line %d\n", $i));
    }

Expressions and literals are always safe; only scalars you still hold are at
risk, and they are yours again once the data has gone out (from
C<< $w->close() >> onwards, or inside a C<poll_cb> that fires after the buffer
drained past them).  The same applies to C<< $w->write(\$scalar) >>,
C<< $w->write_array >> and scalar-ref bodies passed to
C<< $req->send_response >>.

=item C<< $w->write(\"scalar ref") >>

Works just like C<write("scalar")> above, including the zero-copy contract:
the referenced scalar must not be modified until the response completes.  This
extension is indicated by C<psgix.body.scalar_refs> in the PSGI env hash.

=item C<< $w->write_array(\@array) >>

Pass in an array-ref and it works much like the two C<write()> calls above,
except it's way more efficient than calling C<write()> over and over.
Undefined elements of the array are ignored.  The zero-copy contract applies
to every element: neither the array nor the scalars in it may be modified
until the response completes.

=item C<< $w->close() >>

Close the HTTP response (which triggers the "T-E: chunked" terminating chunk
to be sent).  This method is implicitly called when the last reference to the
writer is dropped.

=item C<< $w->poll_cb(sub { .... }) >>

Register a callback to be called when the write buffer drains to (or below)
the server's C<wbuf_low_water> threshold (default: 0, i.e. empty).  Pass in
C<undef> to unset.  The sub can call C<close()>.

The writer is passed as the first and only argument; use C<$_[0]> rather than
closing over C<$w> to avoid a circular reference.  That argument is good for
the duration of the call only and croaks "Handle is closed" if used later;
the writer C<start_streaming> gave you stays valid.

Each call is an invitation, not a busy-poll: a callback with nothing to say
yet can return without writing, and the response is parked and re-invited on
a backoff (roughly 1ms doubling to 100ms, reset by any write).  Writing from
another event source resumes the stream immediately, which is the recommended
shape for relays and SSE.  A zero-length C<< $w->write("") >> counts as
engagement and requests an immediate re-invitation, so use it only when data
really is imminent.  A parked response has no write deadline; a disconnected
client is normally noticed at the next paced retry (on TLS only for an abrupt
close; a graceful close_notify is noticed on the next write).  These rules
apply identically to HTTP/1.x and HTTP/2.

Something else must keep the writer alive: dropping the last reference closes
it (and clears the poll callback), so a writer held only by a lexical in the
handler is closed the moment the handler returns and sends an empty response.
Stash it for as long as the response is meant to last.

=item C<< $w->sendfile($fh [, $offset, $length]) >>

Send file contents using zero-copy sendfile(2) system call. Linux only.
The file handle should be a regular file opened for reading. After calling
sendfile(), call C<close()> on the writer.

The response B<must> carry an explicit C<Content-Length>; sendfile() croaks
otherwise, since the file bytes go out verbatim and cannot be chunk-framed.

Optional C<$offset> (bytes to skip from start, default 0) and C<$length>
(bytes to send, default remainder of file) allow sending a portion of
the file.

B<Note:> Not supported for HTTP/2 responses. Use C<write()> instead.

    my $w = $req->start_streaming(200, [
        'Content-Type' => 'application/octet-stream',
        'Content-Length' => -s $filename,
    ]);
    open my $fh, '<', $filename or die $!;
    $w->sendfile($fh);
    close $fh;
    $w->close();

=back

=head2 Common methods.

Methods in common to both types of handles.

=over 4

=item C<< $h->return_from_psgix_io($io) >>

Returns control of the socket back to Feersum after C<psgix.io> was used.
This is the PSGI-handle equivalent of C<< $req->return_from_io($io) >> on
the connection object.  As there, the hand-back takes a private duplicate of
the descriptor, so C<$io> stays usable and is safe to release at any time.
See L<Feersum::Connection/"$req-E<gt>return_from_io($io)">.

=item C<< $h->response_guard($guard) >>

Register a guard to be triggered when the response is completely sent and the
socket is closed.  A "guard" in this context is some object that will do
something interesting in its DESTROY/DEMOLISH method. For example, L<Guard>.

B<On a keepalive connection this is not when the response finishes.>  The guard
is released at whichever comes first: the next C<response_guard()> call on the
same connection, which replaces it, or the connection closing.  So an app that
registers one on every request sees request N's guard fire during request N+1's
handler, and the last one only at close.  Do not use a guard to release a
per-request resource (a database handle, a rate-limit slot) unless keepalive is
off, or it stays held for the life of the connection.

The guard is *not* attached to this handle object; the guard is attached to
the response.

C<psgix.output.guard> is the PSGI-env extension that indicates this method.

=item C<< $h->fileno >>

Returns the file descriptor number for this connection.

=back

=head1 AUTHOR

Jeremy Stashewsky, C<< stash@cpan.org >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Jeremy Stashewsky & Socialtext Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.14 or,
at your option, any later version of Perl 5 you may have available.

=cut
