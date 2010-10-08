package Feersum;
use 5.008007;
use strict;
use warnings;
use EV ();
use Carp ();

our $VERSION = '0.980';

require Feersum::Connection;
require Feersum::Connection::Handle;
require XSLoader;
XSLoader::load('Feersum', $VERSION);

# numify as per
# http://www.dagolden.com/index.php/369/version-numbers-should-be-boring/
$VERSION = eval $VERSION;

our $INSTANCE;

sub new {
    unless ($INSTANCE) {
        $INSTANCE = bless {}, __PACKAGE__;
    }
    return $INSTANCE;
}
*endjinn = \&new;

sub use_socket {
    my ($self, $sock) = @_;
    $self->{socket} = $sock;
    my $fd = fileno($sock);
    $self->accept_on_fd($fd);

    my $host = eval { $sock->sockhost() } || 'localhost';
    my $port = eval { $sock->sockport() } || 80;
    $self->set_server_name_and_port($host,$port);
}

# overload this to catch Feersum errors and exceptions thrown by request
# callbacks.
sub DIED { Carp::confess "DIED: $@"; }

1;
__END__

=head1 NAME

Feersum - A scary-fast HTTP engine for Perl based on EV/libev

=head1 SYNOPSIS

    use Feersum;
    my $ngn = Feersum->endjinn; # singleton
    $ngn->use_socket($io_socket);
    
    # register a PSGI handler
    $ngn->psgi_request_handler(sub {
        my $env = shift;
        return [200,
            ['Content-Type'=>'text/plain'],
            ["You win one cryptosphere!\n"]];
    });
    
    # register a Feersum handler:
    $ngn->request_handler(sub {
        my $req = shift;
        my $t; $t = EV::timer 2, 0, sub {
            $req->send_response(
                200,
                ['Content-Type' => 'text/plain'],
                \"You win one cryptosphere!\n"
            );
            undef $t;
        };
    });

=head1 DESCRIPTION

Feersum is an HTTP server built on L<EV>.  It fully supports the PSGI 1.03
spec including the C<psgi.streaming> interface and is compatible with Plack.
Feersum also has its own "native" interface which is similar in a lot of
ways to PSGI, but is B<not compatible> with PSGI or PSGI middleware.

Feersum uses a single-threaded, event-based programming architecture to scale
and can handle many concurrent connections efficiently in both CPU and RAM.
It skips doing a lot of sanity checking with the assumption that a "front-end"
HTTP/HTTPS server is placed between it and the Internet.

=head2 How It Works

All of the request-parsing and I/O marshalling is done using C or XS code.
HTTP parsing is done by picohttpparser, which is the core of
L<HTTP::Parser::XS>.  The network I/O is done via the libev library. This is
made possible by C<EV::MakeMaker>, which allows extension writers to link
against the same libev that C<EV> is using.  This means that one can write an
evented app using C<EV> or L<AnyEvent> from Perl that completely co-operates
with the server's event loop.

Since the Perl "app" (handler) is executed in the same thread as the event
loop, one need to be careful to not block this thread.  Standard techniques
include using L<AnyEvent> or L<EV> idle and timer watchers, using L<Coro> to
multitask, and using sub-processes to do heavy lifting (e.g.
L<AnyEvent::Worker> and L<AnyEvent::DBI>).

Feersum also attempts to do as little copying of data as possible. Feersum
uses the low-level C<writev> system call to avoid having to copy data into a
buffer.  For response data, references to scalars are kept in order to avoid
copying the string values (once the data is written to the socket, the
reference is dropped and the data is garbage collected).

A trivial hello-world handler can process in excess of 5000 requests per
second on a 4-core Intel(R) Xeon(R) E5335 @ 2.00GHz using TCPv4 on the
loopback interface, OS Ubuntu 6.06LTS, Perl 5.8.7.  Your mileage will likely
vary.

=head1 INTERFACE

There are two handler interfaces for Feersum: The PSGI handler interface and
the "Feersum-native" handler interface.  The PSGI handler interface is fully
PSGI 1.03 compatible and supports C<psgi.streaming>.  The Feersum-native
handler interface is "inspired by" PSGI, but does some things differently for
speed.

Feersum will use "Transfer-Encoding: chunked" for HTTP/1.1 clients and
"Connection: close" streaming as a fallback.  Technically "Connection: close"
streaming isn't part of the HTTP/1.0 or 1.1 spec, but many browsers and agents
support it anyway.

Currently POST/PUT does not stream input, but read() can be called on
C<psgi.input> to get the body (which has been buffered up before the request
callback is called and therefore will never block).  Likely C<read()> will
change to raise EAGAIN responses and allow for a callback to be registered on
the arrival of more data. (The C<psgix.input.buffered> env var is set to
reflect this).

=head2 PSGI interface

Feersum fully supports the PSGI 1.03 spec including C<psgi.streaming>.

See also L<Plack::Handler::Feersum>, which provides a way to use Feersum with
L<plackup> and L<Plack::Runner>.

Call C<< psgi_request_handler($app) >> to register C<$app> as a PSGI handler.

    my $app = do $filename;
    Feersum->endjinn->psgi_request_handler($app);

The env hash passed in will always have the following keys in addition to
dynamic ones:

    psgi.version      => [1,0],
    psgi.nonblocking  => 1,
    psgi.multithread  => '', # i.e. false
    psgi.multiprocess => '',
    psgi.streaming    => 1,
    psgi.errors       => \*STDERR,
    SCRIPT_NAME       => "",
    # see below for info on these extensions:
    psgix.input.buffered   => 1,
    psgix.output.buffered  => 1,
    psgix.body.scalar_refs => 1,
    # warning: read notes below on this extension:
    psgix.io => \$magical_io_socket,

Note that SCRIPT_NAME is always blank (but defined).  PATH_INFO will contain
the path part of the requested URI.

For requests with a body (e.g. POST) C<psgi.input> will contain a valid
file-handle.  Feersum currently passes C<undef> for psgi.input when there is
no body to avoid unnecessary work.

    my $r = delete $env->{'psgi.input'};
    $r->read($body, $env->{CONTENT_LENGTH});
    # optional: choose to stop receiving further input, discard buffers:
    $r->close();

The C<psgi.streaming> interface is fully supported, including the
writer-object C<poll_cb> callback feature defined in PSGI 1.03.  Feersum calls
the poll_cb callback after all data has been flushed out and the socket is
write-ready.  The data is buffered until the callback returns at which point
it will be immediately flushed to the socket.

    my $app = sub {
        my $env = shift;
        return sub {
            my $starter = shift;
            my $w = $starter->([
                200, ['Content-Type' => 'application/json']
            ]);
            my $n = 0;
            $w->poll_cb(sub {
                $_[0]->write(get_next_chunk());
                # will also unset the poll_cb:
                $_[0]->close if ($n++ >= 100);
            });
        };
    };

Note that C<< $w->close() >> will be called when the last reference to the
writer is dropped.

=head2 PSGI extensions

=over 4

=item psgix.body.scalar_refs

Scalar refs in the response body are supported, and is indicated as an via the
B<psgix.body.scalar_refs> env variable. Passing by reference is
B<significantly> faster than copying a value onto the return stack or into an
array.  It's also very useful when broadcasting a message to many connected
clients.  This is a Feersum-native feature exposed to PSGI apps; very few
other PSGI handlers will support this.

=item psgix.output.buffered

Calls to C<< $w->write() >> will never block.  This behaviour is indicated by
B<psgix.output.buffered> in the PSGI env hash.

=item psgix.input.buffered

B<psgix.input.buffered> is also set, which means that calls to read on the
input handle will also never block.  Feersum currently buffers the entire
input before calling the callback.

This input behaviour will probably change to not be completely buffered. Users
of Feersum should expect that when no data is available read, the calls to get
data from the input filehandle will return an empty-string and set C<$!> to
C<EAGAIN>).  Feersum may also allow for registering a poll_cb() handler that
works similarly to the method on the "writer" object, although that isn't
currently part of the PSGI 1.03 spec.  The callback will be called once data
has been buffered.

=item psgix.io

The raw socket extension B<psgix.io> is provided in order to support
L<Web::Hippie>.  To obtain the L<IO::Socket> corresponding to this connection,
read this environment variable.

B<Caution>: This environment variable is magical!  Reading the value of this
environment variable will activate raw socket mode.  Once activated, the usual
means of responding to a request are B<disabled>.

PSGI apps must return undef or a streaming callback once psgix.io has been
activated.  Returning a response triplet will call the C<Feersum::DIED>
function (default behaviour is to confess).  Trying to call the streaming
starter callback will croak.

=back

=head2 The Feersum-native interface

The Feersum-native interface is inspired by PSGI, but is inherently
B<incompatible> with it.  Apps written against this API will not work as a
PSGI app.

B<This interface may have removals and is not stable until Feersum reaches
version 1.0>, at which point the interface API will become stable and will
only change for bug fixes or new additions.  The "stable" and will retain
backwards compatibility until at least the next major release.

The main entry point is a sub-ref passed to C<request_handler>.  This sub is
passed a reference to an object that represents an HTTP connection.  Currently
the request_handler is called during the "check" and "idle" phases of the EV
event loop.  The handler is always called after request headers have been
read.  Currently, the handler will B<only> be called after a full request
entity has been received for POST/PUT/etc.

The simplest way to send a response is to use C<send_response>:

    my $req = shift;
    $req->send_response(200, \@headers, ["body ", \"parts"]);

Or, if the app has everything packed into a single scalar already, just pass
it in by reference.

    my $req = shift;
    $req->send_response(200, \@headers, \"whole body");

Both of the above will generate C<Content-Length> header (replacing any that
were pre-defined in C<@headers>).

An environment hash is easy to obtain, but is a method call instead of a
parameter to the callback. (In PSGI, there is no $req object; the env hash is
the first parameter to the callback).  The hash contains the same items as it
would for a PSGI handler (see above for those).

    my $req = shift;
    my $env = $req->env();

To read input from a POST/PUT, use the C<psgi.input> item of the env hash.

    if ($req->{REQUEST_METHOD} eq 'POST') {
        my $body = '';
        my $r = delete $env->{'psgi.input'};
        $r->read($body, $env->{CONTENT_LENGTH});
        # optional:
        $r->close();
    }

Starting a response in stream mode enables the C<write()> method (which really
acts more like a buffered 'print').  Calls to C<write()> will never block.

    my $req = shift;
    my $w = $req->start_streaming(200, \@headers);
    $w->write(\"this is a reference to some shared chunk\n");
    $w->write("regular scalars are OK too\n");
    $w->close(); # close off the stream

The writer object supports C<poll_cb> as also specified in PSGI 1.03.  Feersum
will call the callback only when all data has been flushed out at the socket
level.  Use C<close()> or unset the handler (C<< $w->poll_cb(undef) >>) to
stop the callback from getting called.

    my $req = shift;
    my $w = $req->start_streaming(
        "200 OK", ['Content-Type' => 'application/json']);
    my $n = 0;
    $w->poll_cb(sub {
        # $_[0] is a copy of $w so a closure doesn't need to be made
        $_[0]->write(get_next_chunk());
        $_[0]->close if ($n++ >= 100);
    });

Note that C<< $w->close() >> will be called when the last reference to the
writer is dropped.

=head1 METHODS

These are methods on the global Feersum singleton.

=over 4

=item C<< use_socket($sock) >>

Use the file-descriptor attached to a listen-socket to accept connections.

TLS sockets are B<NOT> supported nor are they detected. Feersum needs to use
the socket at a low level and will ignore any encryption that has been
established (data is always sent in the clear).  The intented use of Feersum
is over localhost-only sockets.

A reference to C<$sock> is kept as C<< Feersum->endjinn->{socket} >>.

=item C<< accept_on_fd($fileno) >>

Use the specified fileno to accept connections.  May be used as an alternative
to C<use_socket>.

=item C<< request_handler(sub { my $req = shift; ... }) >>

Sets the global request handler.  Any previous handler is replaced.

The handler callback is passed a L<Feersum::Connection> object.

B<Subject to change>: if the request has an entity body then the handler will
be called B<only> after receiving the body in its entirety.  The headers
*must* specify a Content-Length of the body otherwise the request will be
rejected.  The maximum size is hard coded to 2147483647 bytes (this may be
considered a bug).

=item C<< read_timeout() >>

=item C<< read_timeout($duration) >>

Get or set the global read timeout.

Feersum will wait about this long to receive all headers of a request (within
the tollerances provided by libev).  If an entity body is part of the request
(e.g. POST or PUT) it will wait this long between successful C<read()> system
calls.

=item C<< graceful_shutdown(sub { .... }) >>

Causes Feersum to initiate a graceful shutdown of all outstanding connections.
No new connections will be accepted.  The reference to the socket provided
in use_socket() is kept.

The sub parameter is a completion callback.  It will be called when all
connections have been flushed and closed.  This allows one to do something
like this:

    my $cv = AE::cv;
    my $death = AE::timer 2.5, 0, sub {
        fail "SHUTDOWN TOOK TOO LONG";
        exit 1;
    };
    Feersum->endjinn->graceful_shutdown(sub {
        pass "all gracefully shut down, supposedly";
        undef $death;
        $cv->send;
    });
    $cv->recv;

=item C<< DIED >>

Not really a method so much as a static function.  Works similar to
EV's/AnyEvent's error handler.

To install a handler:

    no strict 'refs';
    *{'Feersum::DIED'} = sub { warn "nuts $_[0]" };

Will get called for any errors that happen before the request handler callback
is called, when the request handler callback throws an exception and
potentially for other not-in-a-request-context errors.

It will not get called for read timeouts that occur while waiting for a
complete header (and also, until Feersum supports otherwise, time-outs while
waiting for a request entity body).

Any exceptions thrown in the handler will generate a warning and not
propagated.

=back

=cut


=head1 LIMITS

=over 4

=item listening sockets

1 - this may be considered a bug

=item body length

2147483647 - about 2GiB.

=item request headers

64

=item request header name length

128 bytes

=item bytes read per read() system call

4096 bytes

=back

=head1 BUGS

Please report bugs using http://github.com/stash/Feersum/issues/

Keep-alive is ignored completely.

Currently there's no way to limit the request entity length of a POST/PUT/etc.
This could lead to a DoS attack on a Feersum server.  Suggested remedy is to
only run Feersum behind some other web server and to use that to limit the
entity size.

Something isn't getting set right with the TCP socket options and the last
chunk in a streamed response is sometimes lost.  This happens more frequently
under high concurrency.  Fiddling with TCP_NODELAY and SO_LINGER don't seem to
help.  Maybe threads are needed to do blocking close() and shutdown() calls?

=head1 SEE ALSO

http://en.wikipedia.org/wiki/Feersum_Endjinn

Feersum Git: C<http://github.com/stash/Feersum>
C<git://github.com/stash/Feersum.git>

picohttpparser Git: C<http://github.com/kazuho/picohttpparser>
C<git://github.com/kazuho/picohttpparser.git>

=head1 AUTHOR

Jeremy Stashewsky, C<< stash@cpan.org >>

=head1 THANKS

Tatsuhiko Miyagawa for PSGI and Plack.

Marc Lehmann for EV and AnyEvent (not to mention JSON::XS and Coro).

Kazuho Oku for picohttpparser.

lukec, konobi, socialtexters and van.pm for initial feedback and ideas.

Audrey Tang and Graham Termarsch for XS advice.

confound for docs input.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Jeremy Stashewsky & Socialtext Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.7 or,
at your option, any later version of Perl 5 you may have available.

picohttpparser is Copyright 2009 Kazuho Oku.  It is released under the same
terms as Perl itself.

=cut
