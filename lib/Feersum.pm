package Feersum;
use 5.008007;
use strict;
use warnings;
use EV ();
use Carp ();

our $VERSION = '1.505';

require Feersum::Connection;
require Feersum::Connection::Handle;
require XSLoader;
XSLoader::load('Feersum', $VERSION);

# numify as per
# http://www.dagolden.com/index.php/369/version-numbers-should-be-boring/
$VERSION = eval $VERSION; ## no critic (StringyEval, ConstantVersion)

our $INSTANCE;

use Exporter 'import';
our @EXPORT_OK = qw(HEADER_NORM_UPCASE HEADER_NORM_LOCASE HEADER_NORM_LOCASE_DASH);

sub new {
    unless ($INSTANCE) {
        $INSTANCE = bless {}, __PACKAGE__;
    }
    $SIG{PIPE} = 'IGNORE';
    return $INSTANCE;
}
*endjinn = *new;

sub use_socket {
    my ($self, $sock) = @_;
    $self->{socket} = $sock;
    my $fd = fileno $sock;
    $self->accept_on_fd($fd);

    my $host = eval { $sock->sockhost() } || 'localhost';
    my $port = eval { $sock->sockport() } || 80; ## no critic (MagicNumbers)
    $self->set_server_name_and_port($host,$port);
    return;
}

# overload this to catch Feersum errors and exceptions thrown by request
# callbacks.
sub DIED { Carp::confess "DIED: $@"; }

1;
__END__

=head1 NAME

Feersum - A PSGI engine for Perl based on EV/libev

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
PSGI 1.1, which has yet to be published formally, is also supported.  Feersum
also has its own "native" interface which is similar in a lot of ways to PSGI,
but is B<not compatible> with PSGI or PSGI middleware.

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

For even faster results, Feersum can support very simple pre-forking (See
L<feersum>, L<Feersum::Runner> or L<Plack::Handler::Feersum> for details).

=head1 INTERFACE

There are two handler interfaces for Feersum: The PSGI handler interface and
the "Feersum-native" handler interface.  The PSGI handler interface is fully
PSGI 1.03 compatible and supports C<psgi.streaming>. The
C<psgix.input.buffered> and C<psgix.io> features of PSGI 1.1 are also
supported.  The Feersum-native handler interface is "inspired by" PSGI, but
does some things differently for speed.

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

Feersum adds these extensions (see below for info)

    psgix.input.buffered   => 1,
    psgix.output.buffered  => 1,
    psgix.body.scalar_refs => 1,
    psgix.output.guard     => 1,
    psgix.io               => \$magical_io_socket,

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
writer-object C<poll_cb> callback feature defined in PSGI 1.03.  B<Note that
poll_cb is removed from the preliminary PSGI 1.1 spec>.  Feersum calls the
poll_cb callback after all data has been flushed out and the socket is
write-ready.  The data is buffered until the callback returns at which point
it will be immediately flushed to the socket.

    my $app = sub {
        my $env = shift;
        return sub {
            my $respond = shift;
            my $w = $respond->([
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

C<psgix.input.buffered> is defined as part of PSGI 1.1. It means that calls to
read on the input handle will never block because the complete input has been
buffered in some way.

Feersum currently buffers the entire input in memory calling the callback.

B<Feersum's input behaviour MAY eventually change to not be
psgix.input.buffered!>  Likely, a C<poll_cb()> method similar to how the
writer handle works could be registered to have input "pushed" to the app.

=item psgix.output.guard

The streaming responder has a C<response_guard()> method that can be used to
attach a guard to the request.  When the request completes (all data has been
written to the socket and the socket has been closed) the guard will trigger.
This is an alternate means to doing a "write completion" callback via
C<poll_cb()> that should be more efficient.  An analogy is the "on_drain"
handler in L<AnyEvent::Handle>.

A "guard" in this context is some object that will do something interesting in
its DESTROY/DEMOLISH method. For example, L<Guard>.

=item psgix.io

The raw socket extension B<psgix.io> is provided in order to support
L<Web::Hippie> and websockets.  C<psgix.io> is defined as part of PSGI 1.1.
To obtain the L<IO::Socket> corresponding to this connection, read this
environment variable.

The underlying file descriptor will have C<O_NONBLOCK>, C<TCP_NODELAY>,
C<SO_OOBINLINE> enabled and C<SO_LINGER> disabled.

PSGI apps B<MUST> use a C<psgi.streaming> response so that Feersum doesn't try
to flush and close the connection.  Additionally, the "respond" parameter to
the streaming callback B<MUST NOT> be called for the same reason.

    my $env = shift;
    return sub {
        my $fh = $env->{'psgix.io'};
        syswrite $fh,
    };

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

=item C<< new() >>

=item C<< endjinn() >>

Returns the C<Feersum> singleton. Takes no parameters.

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

=item C<< unlisten() >>

Stop listening to the socket specified by use_socket or accept_on_fd.

=item C<< request_handler(sub { my $req = shift; ... }) >>

Sets the global request handler.  Any previous handler is replaced.

The handler callback is passed a L<Feersum::Connection> object.

B<Subject to change>: if the request has an entity body then the handler will
be called B<only> after receiving the body in its entirety.  The headers
*must* specify a Content-Length of the body otherwise the request will be
rejected.  The maximum size is hard coded to 2147483647 bytes (this may be
considered a bug).

=item C<< psgi_request_handler(sub { my $env = shift; ... }) >>

Like request_handler, but assigns a PSGI handler instead.

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

=item C<< set_server_name_and_port($host,$port) >>

Override Feersum's notion of what SERVER_HOST and SERVER_PORT should be.

=item C<< set_keepalive($bool) >>

Override Feersum's default keepalive behavior.

=back

=cut

=head1 GRITTY DETAILS

=head2 Compile Time Options

There are a number of constants at the top of Feersum.xs.  If you change any
of these, be sure to note that in any bug reports.

=over 4

=item MAX_HEADERS

Defaults to 64.  Controls how many headers can be present in an HTTP request.

If a request exceeds this limit, a 400 response is given and the app handler does not run.

=item MAX_HEADER_NAME_LEN

Defaults to 128.  Controls how long the name of each header can be.

If a request exceeds this limit, a 400 response is given and the app handler does not run.

=item MAX_BODY_LEN

Defaults to ~2GB.  Controls how large the body of a POST/PUT/etc. can be when
that request has a C<Content-Length> header.

If a request exceeds this limit, a 413 response is given and the app handler does not run.

See also BUGS

=item READ_BUFSZ

=item READ_INIT_FACTOR

=item READ_GROW_FACTOR

READ_BUFSZ defaults to 4096, READ_INIT_FACTOR 2 and READ_GROW_FACTOR 8.

Together, these tune how data is read for a request.

Read buffers start out at READ_INIT_FACTOR * READ_BUFSZ bytes.
If another read is needed and the buffer is under READ_BUFSZ bytes
then the buffer gets an additional READ_GROW_FACTOR * READ_BUFSZ bytes.
The trade-off with the grow factor is memory usage vs. system calls.

=item AUTOCORK_WRITES

Controls how response data is written to sockets.  If enabled (the default)
the event loop is used to wait until the socket is writable, otherwise a write
is performed immediately.  In either case, non-blocking writes are used.
Using the event loop is "nicer" but perhaps introduces latency, hence this
option.

=item KEEPALIVE_CONNECTION

Controls support of keepalive connections. Default is false.
If enabled or set via Feersum->set_keepalive(1), then
"Connection: keep-alive" for HTTP/1.0 and "Connection: close" for HTTP/1.1
are acknowledged.

=item READ_TIMEOUT

Controls read timeout. Default is 5.0 sec. It is also an keepalive timeout.

=item FEERSUM_IOMATRIX_SIZE

Controls the size of the main write-buffer structure in Feersum.  Making this
value lower will use slightly less memory per connection at the cost of speed
(and vice-versa for raising the value).  The effect is most noticeable when
you're app is making a lot of sparce writes.  The default of 64 generally
keeps usage under 4k per connection on full 64-bit platforms when you take
into account the other connection and request structures.

B<NOTE>: FEERSUM_IOMATRIX_SIZE cannot exceed your OS's defined IOV_MAX or
UIO_MAXIOV constant.  Solaris defines IOV_MAX to be 16, making it the default
on that platform.  Linux and OSX seem to set this at 1024.

=item FEERSUM_STEAL

For non-threaded perls >= 5.12.0, this defaults to enabled.

When enabled, Feersum will "steal" the contents of temporary lexical scalars
used for response bodies.  The scalars become C<undef> as a result, but due to
them being temps they likely aren't used again anyway.  Stealing saves the
time and memory needed to make a copy of that scalar, resulting in a mild to
moderate performance boost.

This egregious hack only extends to non-magical, string, C<PADTMP> scalars.

If it breaks for your new version of perl, please send stash a note (or a pull
request!) on github.

Worth noting is that a similar zero-copy effect can be achieved by using the
C<psgix.body.scalar_refs> feature.

=back

=head1 BUGS

Please report bugs using http://github.com/stash/Feersum/issues/

Currently there's no way to limit the request entity length of a B<streaming>
POST/PUT/etc.  This could lead to a DoS attack on a Feersum server.  Suggested
remedy is to only run Feersum behind some other web server and to use that to
limit the entity size.

Although not explicitly a bug, the following may cause undesirable behavior.
Feersum will have set SIGPIPE to be ignored by the time your handler gets
called.  If your handler needs to detect SIGPIPE, be sure to do a
C<local $SIG{PIPE} = ...> (L<perlipc>) to make it active just during the
necessary scope.

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

Luke Closs (lukec), Scott McWhirter (konobi), socialtexters and van.pm for
initial feedback and ideas.  Audrey Tang and Graham Termarsch for XS advice.

Hans Dieter Pearcey (confound) for docs and packaging guidance.

For bug reports: Chia-liang Kao (clkao), Lee Aylward (leedo)

Audrey Tang (au) for flash socket policy support.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2011 by Jeremy Stashewsky

Portions Copyright (C) 2010 Socialtext Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.7 or,
at your option, any later version of Perl 5 you may have available.

picohttpparser is Copyright 2009 Kazuho Oku.  It is released under the same
terms as Perl itself.

=cut
