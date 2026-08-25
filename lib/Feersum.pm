package Feersum;
use 5.014;
use strict;
use warnings;
use EV ();
use Carp ();
use Socket ();

our $VERSION = '1.507';

require Feersum::Connection;
require Feersum::Connection::Handle;
require XSLoader;
XSLoader::load('Feersum', $VERSION);

# dist-style string for --version; $VERSION is numified below
our $VERSION_STRING = $VERSION;

# numify as per http://www.dagolden.com/index.php/369/version-numbers-should-be-boring/
$VERSION = eval $VERSION; ## no critic (StringyEval, ConstantVersion)

our $INSTANCE;
my %_SOCKETS; # inside-out storage for socket refs (keyed by Scalar::Util::refaddr)

# advertised port when the socket cannot report its own; underscore hides it from Pod::Coverage
use constant _DEFAULT_HTTP_PORT => 80;

use Scalar::Util ();
use Exporter 'import';
our @EXPORT_OK = qw(HEADER_NORM_SKIP HEADER_NORM_UPCASE HEADER_NORM_LOCASE HEADER_NORM_UPCASE_DASH HEADER_NORM_LOCASE_DASH);

sub new {
    unless ($INSTANCE) {
        $INSTANCE = __PACKAGE__->_xs_default_server();
        $SIG{PIPE} = 'IGNORE';
    }
    return $INSTANCE;
}
*endjinn = *new;

sub new_instance {
    my $class = shift;
    $SIG{PIPE} = 'IGNORE';
    return $class->_xs_new_server();
}

sub DESTROY {
    my $self = shift;
    my $addr = Scalar::Util::refaddr($self);
    delete $_SOCKETS{$addr};
    # XS DESTROY is renamed to _xs_destroy and called here
    $self->_xs_destroy();
    return;
}

# hold $sock against GC while accepting on it, once per socket (respawns re-register listeners)
sub _hold_socket {
    my ($addr, $sock) = @_;
    my $held = $_SOCKETS{$addr} ||= [];
    for my $s (@$held) {
        return if defined $s && "$s" eq "$sock";
    }
    push @$held, $sock;
    return;
}

sub use_socket {
    my ($self, $sock) = @_;
    my $addr = Scalar::Util::refaddr($self);
    my $fd = fileno $sock;
    Carp::croak "Invalid socket: fileno returned undef" unless defined $fd;
    _hold_socket($addr, $sock);
    $self->accept_on_fd($fd);

    # Try socket methods first, fall back to getsockname() for raw sockets
    my ($host, $port) = ('localhost', _DEFAULT_HTTP_PORT);
    if ($sock->can('sockhost')) {
        $host = eval { $sock->sockhost() } || 'localhost';
        $port = eval { $sock->sockport() } || _DEFAULT_HTTP_PORT;
    } else {
        my $sockaddr = getsockname($sock);
        if ($sockaddr) {
            my $family = eval { Socket::sockaddr_family($sockaddr) };
            if (defined $family && $family == Socket::AF_INET()) {
                (my $packed_port, my $packed_addr) = Socket::sockaddr_in($sockaddr);
                $host = Socket::inet_ntoa($packed_addr) || 'localhost';
                # port 0 is valid
                $port = defined($packed_port) ? $packed_port : _DEFAULT_HTTP_PORT;
            } elsif (defined $family && eval { Socket::AF_INET6() } && $family == Socket::AF_INET6()) {
                (my $packed_port, my $packed_addr) = Socket::sockaddr_in6($sockaddr);
                $host = Socket::inet_ntop(Socket::AF_INET6(), $packed_addr) || 'localhost';
                $port = defined($packed_port) ? $packed_port : _DEFAULT_HTTP_PORT;
            } elsif (defined $family && eval { Socket::AF_UNIX() } && $family == Socket::AF_UNIX()) {
                # matches what the C side reports for REMOTE_ADDR on AF_UNIX
                ($host, $port) = ('unix', 0);
            }
        }
    }
    $self->set_server_name_and_port($host,$port);
    return;
}

# called from XS under G_EVAL when a header carries magic or overload, since FETCH or "" may die
sub _flatten_headers {
    my ($headers) = @_;
    my @out;
    for my $i (0 .. $#{$headers}) {
        my $v = $headers->[$i];
        push @out, defined($v) ? "$v" : undef;
    }
    return \@out;
}

# called from XS under G_EVAL when the body carries magic, since a tied FETCH may die
sub _flatten_body {
    my ($body) = @_;
    my @out;
    for my $e (@{$body}) {            # copying fires a tied element's FETCH
        if (ref($e) eq 'SCALAR') {    # ...and \$tied needs one level more
            my $copy = ${$e};
            push @out, \$copy;
        }
        else { push @out, $e }
    }
    return \@out;
}

# called from XS under G_EVAL with the error in $_[0]; a throw here is swallowed
sub DIED {
    # not carp: the caller is XS, and carp appends "at ... line N" regardless
    warn "DIED: $_[0]";  ## no critic (ErrorHandling::RequireCarping)
    return;
}

1;
__END__

=head1 NAME

Feersum - A fast PSGI/HTTP server for Perl based on EV/libev

=head1 SYNOPSIS

    use Feersum;
    use EV;
    use IO::Socket::INET;

    my $io_socket = IO::Socket::INET->new(
        LocalAddr => 'localhost:5000',
        Proto     => 'tcp',
        Listen    => 1024,
        Blocking  => 0,      # optional: use_socket sets O_NONBLOCK anyway
    ) or die $!;

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

    EV::run;   # nothing is served until the loop runs

See C<eg/hello.pl> for the same thing as a file you can run.

=head1 DESCRIPTION

Feersum is an HTTP server built on L<EV>.  It supports PSGI 1.1 including
C<psgi.streaming> and works with Plack.  It also has a "native" interface,
similar to PSGI but B<not compatible> with it or with PSGI middleware.

It is single-threaded and event-driven, with built-in TLS 1.3, HTTP/2, SNI and
PROXY protocol support, and runs either directly exposed or behind a reverse
proxy.

=head2 How It Works

Request parsing (picohttpparser) and I/O are done in C.  Network I/O uses the
same libev that L<EV> uses (via C<EV::MakeMaker>), so an app written with
L<EV> or L<AnyEvent> co-operates with the server's event loop.

The handler runs in the event loop's thread, so it must not block: use
L<AnyEvent>/L<EV> watchers, L<Coro>, or sub-processes (L<AnyEvent::Worker>,
L<AnyEvent::DBI>) for heavy work.

Response data is written with C<writev> and held by reference, not copied.
B<A scalar handed to Feersum as response body data must not be modified until
the response has been transmitted>, which happens after the handler returns;
reassigning it in the meantime corrupts the pending write.  Pass a fresh
scalar each time.  See L<Feersum::Connection::Handle/"Writer methods."> for
details.

Simple pre-forking is available via L<feersum>, L<Feersum::Runner> or
L<Plack::Handler::Feersum>.

=head1 INTERFACE

Feersum has two handler interfaces: PSGI (fully PSGI 1.1, with
C<psgi.streaming> and C<psgix.io>) and the "Feersum-native" interface, which
is inspired by PSGI but does some things differently for speed.

Streaming responses use C<Transfer-Encoding: chunked> for HTTP/1.1 clients
and C<Connection: close> streaming as a fallback.

Responses with 101, 204, 205, or 304 status codes are sent without a body;
any body the handler supplies is discarded.  Any other 1xx, or a status above
599, is refused with a 500.  A C<HEAD> response is sent
without a body too: the handler may return one, Feersum measures it for
C<Content-Length> and transmits only the headers.

Request bodies (including chunked transfer-encoding) are fully buffered
before the handler runs, so C<read()> on C<psgi.input> never blocks.
C<psgix.input.buffered> is deliberately I<not> set; see
L</"psgix.input.buffered">.

=head2 PSGI interface

Response strings (body parts, C<write()> chunks, header values and the status
message, native interface alike) are B<byte> strings.  A UTF8-flagged string
whose characters are all C<< <= 255 >> is sent as those bytes, exactly as the
C<syswrite>-based PSGI servers do; C<Content-Length> counts the same bytes.
Characters above 255 are forbidden by PSGI; Feersum does not police that and
transmits such a string in Perl's internal UTF-8 encoding with consistent
framing, so C<encode> such data yourself before returning it.

See also L<Plack::Handler::Feersum>, which provides a way to use Feersum with
L<plackup> and L<Plack::Runner>.

Call C<< psgi_request_handler($app) >> to register C<$app> as a PSGI handler.

    my $app = do $filename;
    Feersum->endjinn->psgi_request_handler($app);

The env hash always has these keys in addition to dynamic ones:

    psgi.version      => [1,1],
    psgi.nonblocking  => 1,
    psgi.multithread  => '',
    psgi.multiprocess => $bool,    # true when pre_fork or set_multiprocess($true)
    psgi.run_once     => '',
    psgi.streaming    => 1,
    psgi.errors       => \*STDERR,
    SCRIPT_NAME       => "",

and these extensions (see L</"PSGI extensions">):

    psgix.output.buffered  => 1,
    psgix.body.scalar_refs => 1,
    psgix.output.guard     => 1,
    psgix.io               => \$magical_io_socket,

SCRIPT_NAME is always blank (but defined).  PATH_INFO holds the path part of
the requested URI, B<fully percent-decoded and otherwise untouched, so
sanitise it before using it as a filename>:

    /a/%2e%2e%2fsecret   ->  /a/../secret     (a live traversal, not collapsed)
    /a%2Fb               ->  /a/b             (a separator that was not one)
    /a%00b               ->  /a\0b            (an embedded NUL)

Reject a decoded path containing a C<..> segment or a NUL.  The raw target is
always in C<REQUEST_URI>, and QUERY_STRING is B<not> decoded, as PSGI
requires.

B<Over HTTP/1.x only these request methods are accepted:> GET, HEAD, POST,
PUT, PATCH, DELETE, OPTIONS.  Anything else (CONNECT, WebDAV verbs, TRACE,
...) is answered with C<405 Method Not Allowed> plus an C<Allow> header
without the handler running.  HTTP/2 passes every method through to the
handler.

C<psgi.input> always contains a valid handle.  For a request without a body,
reads return 0 (end of file) whatever length is requested; C<undef>/C<EAGAIN>
only occurs in streaming-input mode (after C<< $input->poll_cb(...) >>) when
no data has arrived yet.

    my $r = delete $env->{'psgi.input'};
    $r->read($body, $env->{CONTENT_LENGTH});
    $r->close();   # optional: stop receiving input, discard buffers

The handle also implements C<getline>/C<getlines> and the diamond operator
(honouring C<$/>); see L<Feersum::Connection::Handle/"Reader methods">.

B<C<read()> appends to the buffer, it does not replace it>, unlike Perl's
built-in C<read> and every PSGI server whose C<psgi.input> is a real
filehandle.  The common portable idiom duplicates data here:

    my $buf;
    while (my $n = $input->read($buf, 8192)) { $body .= $buf }   # WRONG here

Read the whole body in one call, or use a fresh lexical per iteration:

    $input->read(my $body, $env->{CONTENT_LENGTH});
    while (my $n = $input->read(my $chunk, 8192)) { $body .= $chunk }

C<Plack::Request> and the usual body parsers declare the buffer inside the
loop, so they are unaffected.

C<psgi.streaming> is fully supported, including the writer's C<poll_cb>.  The
callback runs after all buffered data has been flushed and the socket is
write-ready; data written inside it is flushed when it returns.

    my $app = sub {
        my $env = shift;
        return sub {
            my $respond = shift;
            my $w = $respond->([200, ['Content-Type' => 'application/json']]);
            my $n = 0;
            $KEEP{0+$w} = $w;   # a poll_cb registration does not keep $w alive
            $w->poll_cb(sub {
                $_[0]->write(get_next_chunk());
                # $_[0] is a fresh handle per invocation, so key the stash off $w
                if ($n++ >= 100) { delete $KEEP{0+$w}; $_[0]->close }
            });
        };
    };

C<< $w->close() >> is called when the last reference to the writer is dropped.
B<Registering a C<poll_cb> does not count as a reference>, so a writer you do
not store anywhere is closed as soon as the handler returns: the callback
never fires and the client receives an empty body.

A client that goes away mid-stream is noticed on the next write to it, so a
long-lived stream (SSE, long-poll) that pushes nothing keeps its connection
and its C<active_conns> slot until the app writes again.  B<Send a periodic
heartbeat if you also set C<max_connections>>: dead streams are not idle
keepalive connections, so they are never evicted to make room, and once
enough accumulate the server stops serving and cannot recover.
C<write_timeout> does not help, since nothing is pending.

=head2 PSGI extensions

=over 4

=item psgix.body.scalar_refs

Scalar refs are accepted in the response body.  Passing by reference is
B<significantly> faster than copying, and useful when broadcasting one
message to many clients.  Few other PSGI servers support this.

=item psgix.output.buffered

C<< $w->write() >> never blocks.

=item psgix.input.buffered

B<Not set.>  The request body is fully buffered before the handler runs, so
reads never block, but the handle is forward-only: C<seek> cannot rewind, and
PSGI 1.1 says a true value promises that it can.  Consumers such as
L<Plack::Request> honour the flag by rewinding with C<seek(0,0)>, which would
lose the body; with it unset they buffer the body into their own rewindable
handle.

The reader handle also supports C<poll_cb()>.  On a normal request the
handler runs only after the whole body has arrived, so the callback drains an
already-complete buffer; it becomes an incremental reader only once the app
takes over the byte stream with C<io()>/C<psgix.io>, where each socket read
invokes it.

=item psgix.output.guard

The streaming responder has a C<response_guard()> method that attaches a
guard (an object with a DESTROY/DEMOLISH method, e.g. L<Guard>) to the
request.  The guard triggers when the request completes (all data written and
the connection started its close): a cheaper alternative to a
write-completion C<poll_cb()>, like C<on_drain> in L<AnyEvent::Handle>.

=item psgix.io

The raw socket for this connection, as defined in PSGI 1.1, for WebSockets
and L<Web::Hippie>.

B<Reading this key hands the connection to your application.>  The value
carries get-magic: fetching it takes over the socket, after which Feersum
sends no response of its own; a normal PSGI response returned anyway is
refused (reported through C<Feersum::DIED>) and the client receives nothing.
Consequently anything that reads B<every> value in C<%$env> (C<< my %copy =
%$env >>, C<< values %$env >>, C<Data::Dumper>) takes the socket as a side
effect.  C<keys> and C<exists> are safe.  If you must copy or dump the
environment, exclude this key or disable the extension with
C<< $server->set_psgix_io(0) >> (C<< psgix_io => 0 >> in L<Feersum::Runner>),
which removes it from C<%$env>.

On a plain connection the returned L<IO::Socket::INET> wraps the raw socket
descriptor (TCP or Unix domain), with C<O_NONBLOCK>, C<FD_CLOEXEC> and (TCP)
C<TCP_NODELAY> set.  On TLS connections and HTTP/2 Extended CONNECT (RFC
8441) streams it is a Unix socketpair relaying through the TLS/H2 layer.  On
a regular HTTP/2 stream it is C<undef> (the native C<io()> croaks; see
L<Feersum::Connection/"$req-E<gt>io">).

If you take the socket while part of the request body is still unread, the
bytes already buffered are pushed back into the handle.  On a plain
connection that push-back goes through the PerlIO layer, which C<sysread>
bypasses: buffered C<read>/C<getline> see them, C<sysread> does not.  Over
TLS and H2 tunnels they are real bytes on the socketpair and every read style
sees them.  An app that takes over mid-body and only C<sysread>s should drain
C<psgi.input> first.

PSGI apps B<MUST> use a C<psgi.streaming> response so Feersum does not flush
and close the connection, and on HTTP/1 B<MUST NOT> call the responder.  On
HTTP/2 Extended CONNECT, calling the responder with a C<200> accepts the
tunnel.

    my $env = shift;
    return sub {
        my $fh = $env->{'psgix.io'};
        syswrite $fh, "HTTP/1.1 101 Switching Protocols\r\n"
                     . "Upgrade: myproto\r\nConnection: Upgrade\r\n\r\n";
        # ... bidirectional I/O on $fh ...
    };

On H2 Extended CONNECT tunnels Feersum sends the 200 HEADERS itself and
swallows the HTTP/1.1 101 response written by the app, so the same handler
works for H1 and H2.  See L</"HTTP/2 Support">.

=item psgix.h2.trailers

Flat array-ref of alternating C<name, value> entries: the HTTP/2 trailers
received with the request.  Present only on HTTP/2 requests that carried
trailers.

=item psgix.h2.extended_connect

C<1> on HTTP/2 Extended CONNECT streams (RFC 8441); absent otherwise.

=item psgix.h2.protocol

The H2 C<:protocol> pseudo-header (e.g. C<"websocket">); present only on
Extended CONNECT streams.

=item psgix.proxy_tlvs

Hash ref mapping PROXY protocol v2 TLV type numbers to their raw values;
present only when the connection carried TLVs.  A repeated type keeps the
B<last> occurrence only.  See
L<Feersum::Connection/"my $tlvs = $req-E<gt>proxy_tlvs">.

=back

=head2 The Feersum-native interface

The native interface is inspired by PSGI but B<incompatible> with it; apps
written against it will not work as PSGI apps.  It has been stable since 1.0
and only changes in backwards-compatible ways.

The entry point is a sub-ref passed to C<request_handler>, called with a
L<Feersum::Connection> object once the request headers and, for
POST/PUT/etc., the full request body have been received.

The simplest way to respond is C<send_response>, with the body as an array
of parts or a single scalar ref:

    my $req = shift;
    $req->send_response(200, \@headers, ["body ", \"parts"]);
    $req->send_response(200, \@headers, \"whole body");

Both generate a C<Content-Length> header (replacing any in C<@headers>).
Response strings are bytes; see L</"PSGI interface">.

The environment hash is available via C<< $req->env() >> and holds the same
items as for a PSGI handler, except C<psgix.io>; use C<< $req->io() >>
instead.  Request bodies are read from its C<psgi.input> item:

    my $env = $req->env();
    if ($env->{REQUEST_METHOD} eq 'POST') {
        my $r = delete $env->{'psgi.input'};
        $r->read(my $body, $env->{CONTENT_LENGTH});   # or $r->getline, <$r>
        $r->close();   # optional
    }

Starting a response in stream mode enables C<write()>, which never blocks:

    my $w = $req->start_streaming(200, \@headers);
    $w->write(\"this is a reference to some shared chunk\n");
    $w->write("regular scalars are OK too\n");
    $w->close();

The writer supports C<poll_cb> as in PSGI: the callback runs only once all
data has been flushed at the socket level.  Use C<close()> or
C<< $w->poll_cb(undef) >> to stop it.

    my $w = $req->start_streaming("200 OK", ['Content-Type' => 'application/json']);
    my $n = 0;
    $KEEP{0+$w} = $w;   # a poll_cb registration does not keep $w alive
    $w->poll_cb(sub {
        $_[0]->write(get_next_chunk());
        # $_[0] is a fresh handle per invocation, so key the stash off $w
        if ($n++ >= 100) { delete $KEEP{0+$w}; $_[0]->close }
    });

B<Keep a reference to the writer alive> for as long as you stream: it is
closed when the last reference is dropped, and the C<poll_cb> registration is
not a reference, so a writer stored nowhere is closed as soon as the handler
returns and the client gets an empty body.

C<poll_cb> is also the only backpressured way to stream: it fires when the
socket has drained (see C<wbuf_low_water>), so an endless source paces itself
against the client.  A bare C<< $w->write() >> loop buffers whatever you give
it and can grow without bound against a peer that stops reading.

On Linux the writer also supports zero-copy file responses via
C<< $w->sendfile($fh [, $offset, $length]) >> (not for HTTP/2 streams); see
L<Feersum::Connection::Handle/"$w-E<gt>sendfile($fh [, $offset, $length])">.

=head1 METHODS

Methods on the Feersum server object.

=over 4

=item C<< new() >>

=item C<< endjinn() >>

Returns the C<Feersum> singleton.  Takes no parameters.

=item C<< new_instance() >>

Creates an independent server instance with its own listeners, configuration
and request handler, for running multiple servers in one process.

    my $http  = Feersum->new_instance();
    my $https = Feersum->new_instance();

Create instances at startup and keep them.  An instance is retained for the
life of the process even after you drop your reference (its watchers and live
connections point into it), and keeps serving with no handle left to stop it;
call C<unlisten()> or C<graceful_shutdown()> before letting one go out of
scope.  See C<eg/multi-instance.pl>.

=item C<< use_socket($sock) >>

Accept connections on the listen socket C<$sock>.  A reference to it is kept
(once per socket) to prevent garbage collection.  Feersum sets C<O_NONBLOCK>
on the descriptor, which affects a socket you continue to use elsewhere.

Pre-encrypted sockets (e.g. L<IO::Socket::SSL>) are not supported: Feersum
works on the raw descriptor.  Use C<set_tls()> after adding the socket
instead.

=item C<< accept_on_fd($fileno) >>

Like C<use_socket>, with a file descriptor number.  Feersum switches the
descriptor to non-blocking mode itself: it accepts several connections per
loop iteration, and a blocking C<accept()> would wedge the whole loop.

=item C<< unlisten() >>

Stop listening on all sockets added via C<use_socket()>/C<accept_on_fd()>.
The descriptors are B<not> closed, so they can be handed to C<accept_on_fd()>
again (how pre-fork worker respawn re-arms accept); C<graceful_shutdown()>
closes them.

A connection reads C<SERVER_NAME>/C<SERVER_PORT> from its listener slot at
request time, so if a keep-alive connection is still open when you unlisten
and then listen on a B<different> socket, its later requests report the new
listener's name and port.  Drain first when swapping sockets.

=item C<< pause_accept() >>

Stop accepting new connections; existing ones continue.  Returns true if any
listener was newly paused.

=item C<< resume_accept() >>

Resume accepting after C<pause_accept()>.  Returns true if any listener was
resumed.

=item C<< accept_is_paused() >>

Returns true if accepting is paused on all listeners.

=item C<< request_handler(sub { my $req = shift; ... }) >>

Sets the request handler, replacing any previous one.  The callback receives
a L<Feersum::Connection> object, after the entire request body
(Content-Length or chunked, up to C<max_body_len()>) has been received.

=item C<< psgi_request_handler(sub { my $env = shift; ... }) >>

Like C<request_handler>, but assigns a PSGI handler.

=item C<< read_timeout() >>

=item C<< read_timeout($duration) >>

Get or set the read timeout.  Default 5 seconds; must be positive (0 or a
negative value croaks).  New connections only.

Feersum waits this long for all headers of a request, then between
successful C<read()> calls while receiving a body.  It also serves as the
keepalive idle timeout between requests; there is no separate setting.

The idle reap is deferred while the socket send queue is still draining a
large response, so a client merely slow to read keeps its connection, while
one that stops reading altogether is reaped one interval later.  That
deferral needs a kernel send-queue count, which Feersum does not have on
OpenBSD or NetBSD; there, size C<read_timeout> above the time your slowest
client needs to drain your largest response.

On HTTP/2 this is the connection's only idle watchdog and counts silence in
either direction.  A dispatched stream exempts the connection, so a quiet SSE
or long-poll response is not reaped, but a peer that advertises a zero
flow-control window and goes silent with response bytes pending is reaped
after a few consecutive silent intervals.  A peer that keeps reading, however
slowly, is bounded by C<write_timeout> instead.

=item C<< header_timeout() >>

=item C<< header_timeout($seconds) >>

Get or set the header completion deadline (Slowloris protection).  Default
10 seconds; C<0> disables it.

A connection must complete its request headers within this many seconds of
being accepted or gets C<408 Request Timeout> (a TLS connection still in its
handshake is closed silently).  This is a hard deadline that does not reset
when data arrives, unlike C<read_timeout>.

It bounds the header phase only: the request body is governed by
C<read_timeout>, which resets on every read, so a client trickling one body
byte per interval holds its connection indefinitely and, never being idle,
cannot be evicted to make room under C<max_connections>.  For untrusted
clients, put a body-buffering reverse proxy in front and consider setting
C<write_timeout> for the response phase.

Unlike the other per-connection tunables this one is read at the start of
each request, so lowering it reaches connections that are already open.

Recommended: 30-60 seconds when directly internet-exposed; can be left
disabled behind a reverse proxy.

=item C<< graceful_shutdown(sub { .... }) >>

Stop accepting, close all listen socket descriptors, and call the callback
once every outstanding connection has been flushed and closed.

This is terminal: the retained Perl socket objects still hold the now-closed
descriptor numbers and will close them again when destroyed, so the process
should exit once the callback fires (as L<Feersum::Runner> does via
C<POSIX::_exit>) rather than continue and reuse those numbers.

    my $cv = AE::cv;
    my $death = AE::timer 2.5, 0, sub { warn "shutdown took too long"; exit 1 };
    Feersum->endjinn->graceful_shutdown(sub { undef $death; $cv->send });
    $cv->recv;

The deadline timer is not decoration: a socket taken over via C<psgix.io> and
an established RFC 8441 HTTP/2 tunnel are exempt from the read and write
timeouts (a websocket may sit idle for hours), so the callback will not fire
while one is open.  Impose your own deadline, as L<Feersum::Runner> does with
C<graceful_timeout>.

=item C<< DIED >>

A static function, not a method, similar to EV's/AnyEvent's error handler.
The default warns the error to STDERR.  To install your own:

    no strict 'refs';
    *{'Feersum::DIED'} = sub { warn "Error: $_[0]" };

The error is in C<$_[0]>; C<$@> is B<not> set, because the handler runs under
C<G_EVAL>.  For the same reason an exception thrown by the handler itself is
discarded and B<not reported anywhere>, so use C<Carp::cluck>, not
C<Carp::confess>, for a stack trace.

Called for errors before the request handler runs, when the handler throws,
and for some errors outside a request context.  Not called for read or header
timeouts.

The client still gets a 500 if the response has not started.  A handler (or
streaming callback) that dies B<mid-stream> instead has its response sealed
so the client can detect the truncation: HTTP/1.x closes without the
terminating chunk, HTTP/2 sends C<RST_STREAM>.  A response completed with
C<< $w->close >> before the die is delivered intact; letting the writer go
out of scope does not count, since that is what an exception unwind looks
like.

=item C<< set_server_name_and_port($host,$port) >>

Override SERVER_NAME and SERVER_PORT for the most recently added listener;
call it after each C<use_socket()>/C<accept_on_fd()> when running several
(C<use_socket()> already calls it with values derived from the socket).

=item C<< get_keepalive() >>

=item C<< set_keepalive($bool) >>

Enable or disable keepalive.  Default B<disabled>.  When enabled, HTTP/1.1
connections without C<Connection: close> are kept alive between requests.
New connections only.

=item C<< get_drain_accept_queue() >>

=item C<< set_drain_accept_queue($bool) >>

When enabled, C<graceful_shutdown()> accepts and serves whatever the kernel
has queued on each TCP listen socket before closing it.  Default
B<disabled>.

Enable it when this process alone owns the listen socket (a C<SO_REUSEPORT>
socket, most notably), since that socket's accept queue dies with the process
and the queued clients would be reset; L<Feersum::Runner> does so for
reuseport workers.  Leave it off for a socket shared with other processes,
where draining steals connections a sibling would serve.  Drained connections
respect C<max_connections>; UNIX-domain listeners are never drained.

Enabling it also turns C<TCP_DEFER_ACCEPT> off on the server's TCP listeners,
since a deferred connection is invisible to C<accept()>.

=item C<< set_reverse_proxy($bool) >>

Enable or disable reverse proxy mode, in which C<X-Forwarded-For> and
C<X-Forwarded-Proto> from the upstream proxy set C<REMOTE_ADDR> and
C<psgi.url_scheme> in C<env()>, and C<client_address()>/C<url_scheme()> on
L<Feersum::Connection> return the forwarded values.  C<remote_address()> and
C<remote_port()> always report the immediate peer.  New connections only.

B<Security:> Feersum uses the leftmost C<X-Forwarded-For> address, which
assumes a single-hop proxy that replaces the header.  If your proxy appends,
clients can spoof their address.  Separately, the CGI mapping folds dashes
and underscores, so a client-sent C<X_Forwarded_For> lands in
C<HTTP_X_FORWARDED_FOR> too; this mode reads the exact header name and is not
fooled, but an application reading C<HTTP_X_FORWARDED_FOR> itself can be.
Have the proxy drop underscore headers, as nginx does by default.

Combined with C<proxy_protocol>, C<REMOTE_ADDR> comes from C<X-Forwarded-For>
while C<REMOTE_PORT> keeps the PROXY header's value.  The PROXY header cannot
be forged by the client, so with a PROXY-protocol upstream prefer it alone.

=item C<< get_reverse_proxy() >>

Returns whether reverse proxy mode is enabled (1 or 0).

=item C<< max_connection_reqs() >>

=item C<< max_connection_reqs($count) >>

Get or set the maximum number of requests per keep-alive connection.  Default
0 (unlimited).  The connection is closed after that many requests.  New
connections only.

B<HTTP/1.1 only>: an HTTP/2 connection is not closed after this many streams.
Use C<max_h2_concurrent_streams()> and C<max_connections()> there.

=item C<< read_priority() >>

=item C<< read_priority($priority) >>

Get or set the libev watcher priority for read I/O, -2 to +2 (clamped),
default 0.  Higher runs first.  New connections only.

At -2 read watchers tie with Feersum's own dispatch watcher, so a request is
handled one loop iteration later than it was read, costing an extra syscall
per request.

=item C<< write_priority() >>

=item C<< write_priority($priority) >>

Get or set the libev watcher priority for write I/O, -2 to +2 (clamped),
default 0.  New connections only.

=item C<< accept_priority() >>

=item C<< accept_priority($priority) >>

Get or set the libev watcher priority for accept, -2 to +2 (clamped),
default 0.  Listeners added afterwards only.

=item C<< set_psgix_io($bool) >>

Enable or disable the C<psgix.io> extension (default enabled).  Disabling it
skips creating a raw I/O handle per request, a small PSGI-path speedup, and
is the fix when middleware copies or dumps the whole env hash; see
L</psgix.io>.

=item C<< get_psgix_io() >>

Returns whether C<psgix.io> is enabled (1 or 0).

=item C<< set_proxy_protocol($bool) >>

Enable or disable PROXY protocol support.  When enabled every new connection
must begin with a PROXY protocol header (v1 text or v2 binary,
auto-detected), as sent by HAProxy, AWS ELB/NLB, nginx and others; a valid
header sets C<REMOTE_ADDR> and C<REMOTE_PORT> to the original client, and a
connection without one is rejected with 400.  A v1 C<UNKNOWN>, v2 C<LOCAL>,
or v2 C<UNSPEC>/C<AF_UNIX> header keeps the original address (health checks).

B<Only enable this when all connections come from a proxy that sends PROXY
headers.>  See C<eg/proxy-protocol.pl>.

=item C<< get_proxy_protocol() >>

Returns true if PROXY protocol support is enabled.

=item C<< max_accept_per_loop() >>

=item C<< max_accept_per_loop($count) >>

Get or set the maximum connections accepted per event loop iteration.
Default 64.  Lower values favour existing connections under a connection
flood; higher values improve accept throughput.

=item C<< active_conns() >>

Returns the number of active connection objects.  Each HTTP/2 stream counts
in addition to its TCP connection, so one H2 connection with N streams
contributes N+1.

=item C<< total_requests() >>

Returns the number of requests processed since the server started (a native
unsigned integer, 64-bit on 64-bit perls).

=item C<< access_log() >>

=item C<< access_log($cb) >>

Get or set a callback invoked as each response completes with
C<($method, $uri, $elapsed_seconds)>.  C<undef> disables it.  Returns the
current callback.

Only requests that reached the handler are reported; one the server rejects
itself (malformed, over a limit, timed out) produces no call.  C<$elapsed>
runs from dispatch to the handler until the response is fully flushed.  An
exception from the callback is warned about and does not affect the
response.  L<Feersum::Runner>'s C<access_log> option uses this.

=item C<< max_requests_per_worker() >>

=item C<< max_requests_per_worker($limit, $cb) >>

=item C<< max_requests_per_worker($limit, $cb, $retiring_cb) >>

Retire this process after C<$limit> requests: Feersum stops accepting,
closes its listeners, lets in-flight requests drain, then calls C<$cb>.  0
disables it.  Returns the current limit.  Per-process, so under C<pre_fork>
it retires one worker, which the supervisor replaces.

C<$retiring_cb>, if given, is called the moment the limit is reached, before
the drain begins.  The drain has no deadline of its own, so a caller that
needs to bound it (as L<Feersum::Runner> does with C<graceful_timeout>) arms
its timer there.  An exception from it is warned about.

=item C<< max_connections() >>

=item C<< max_connections($limit) >>

Get or set the maximum number of concurrent connections.  Default 10000; 0
disables the limit.

At the limit Feersum first closes the oldest idle keep-alive connection to
make room; failing that the new connection is closed right after C<accept()>
and accepting pauses on that listener until a slot frees.  A connection whose
client vanished mid-stream is neither idle nor freeing itself and is never
evicted; see L</"PSGI interface"> for why a streaming app needs a heartbeat
before relying on this limit.

HTTP/2 streams count toward C<active_conns()> in addition to their TCP
connection, so open streams consume the budget for accepting further TCP
connections, but stream creation itself is B<not> checked against this
limit; use C<max_h2_concurrent_streams()>.

=item C<< max_read_buf() >>

=item C<< max_read_buf($bytes) >>

Get or set the maximum read buffer size per connection (default 64 MiB),
which bounds header parsing and chunked body reception.  A request that
exceeds it in its header block gets 431; a chunked body that outgrows it gets
413.  0 resets to the compile-time default.  New connections only.

The limit is approximate: on a plain connection the check precedes the
growth (rejected slightly below), on TLS it follows decryption (accepted
slightly above), a difference of a few tens of KiB.  It does not apply to
HTTP/2, which is bounded by C<max_body_len>, C<max_h2_concurrent_streams>
and the advertised SETTINGS_MAX_HEADER_LIST_SIZE.

=item C<< max_body_len() >>

=item C<< max_body_len($bytes) >>

Get or set the maximum request body size (default 64 MiB), applied to
C<Content-Length> and to cumulative chunked size.  Over the limit: 413 on
HTTP/1.1 and HTTP/2; an H2 body of unknown length that outgrows it mid-stream
is reset with C<ENHANCE_YOUR_CALM>.  0 resets to the compile-time default.
New connections only.

=item C<< max_uri_len() >>

=item C<< max_uri_len($bytes) >>

Get or set the maximum request URI length (default 8192).  Over the limit:
414 on HTTP/1.1 and HTTP/2.  0 resets to the compile-time default.  New
connections only.

=item C<< write_timeout() >>

=item C<< write_timeout($seconds) >>

Get or set the write timeout.  Default 0 (disabled).  New connections only.

When enabled, a connection that makes no write progress within this many
seconds is closed; the deadline is refreshed by each successful write.  On
HTTP/2 it applies per stream (a stalled stream gets C<RST_STREAM>) and to the
connection's outbound buffer, and progress on either refreshes it.  HTTP/2
tunnels are exempt like C<psgix.io>, until the connection's queued ciphertext
reaches 16MB.

"Progress" includes the peer draining the kernel send buffer: at each
deadline Feersum asks the kernel (C<SIOCOUTQ>/C<SO_NWRITE>/C<FIONWRITE>; see
C<has_outq_probe()>) whether queued bytes have left, and a peer that drains
nothing across three consecutive checks is closed.  So this bounds a
I<stalled> transfer, not a slow one: a client that keeps draining a trickle
holds its connection, which is why untrusted clients belong behind a reverse
proxy.  Where no probe exists (OpenBSD) a slow-but-active reader may be
closed once the send buffer stays backed up for a full interval.

Disabled while the application holds the socket via C<io()>/C<psgix.io>;
over TLS it applies again once the application closes its end with data
still queued.

B<On HTTP/2 the deadline is not cleared when the buffer drains, so it also
bounds the gap between an application's own writes>: once a streaming
response has called write (a zero-length write counts), it must write again
within this many seconds or the stream is reset.  An SSE or long-poll app
that pushes an event and goes quiet needs C<write_timeout> off or above its
heartbeat interval.  HTTP/1.x stops the timer once the data is gone.

Independently, an HTTP/2 connection's pending ciphertext is capped at 16MB:
past that Feersum stops draining nghttp2's output queue, so nghttp2's own
flood detection closes a peer that stops reading but keeps the session busy.
A response larger than the cap is unaffected.

=item C<< linger_timeout() >>

=item C<< linger_timeout($seconds) >>

Get or set the lingering-close deadline.  Default 5 seconds; 0 disables
lingering.

A completed HTTP/1.x close-response (also error responses and idle keepalive
reaps) does a lingering close: C<shutdown(SHUT_WR)> queues FIN behind the
response, then the server reads and discards until the peer closes, 256 KB
have been drained, or this many seconds pass.  Otherwise a byte arriving
after a plain C<close()> (a pipelined request, a speculative write) would
make the kernel answer RST and discard the queued response.  TLS and HTTP/2
connections, write-timeout teardowns, graceful-shutdown closes and
C<max_connections> evictions close immediately.

A lingering connection holds its descriptor and its C<max_connections> slot
for at most this long; with keepalive disabled every response pays it.

=item C<< wbuf_low_water() >>

=item C<< wbuf_low_water($bytes) >>

Get or set the write buffer low-water mark for C<poll_cb>.  Default 0: the
callback fires only when the buffer is empty.  A positive value fires it once
buffered data drops to or below that threshold, keeping the pipe full.  All
transports.  New connections only.

=item C<< get_multiprocess() >>

=item C<< set_multiprocess($bool) >>

Mark this instance as multi-process: sets C<psgi.multiprocess> true in the
PSGI env.  L<Feersum::Runner> sets it under C<pre_fork>.

=item C<< max_h2_concurrent_streams() >>

=item C<< max_h2_concurrent_streams($n) >>

Get or set the maximum concurrent HTTP/2 streams per connection (default
100), advertised in the SETTINGS frame.  Clamped to
1..C<FEER_H2_MAX_CONCURRENT_STREAMS> (compile-time, default 100).  Requires
H2.

=item C<< max_h2_conn_body() >>

=item C<< max_h2_conn_body($bytes) >>

Get or set an aggregate cap on request-body bytes buffered across all of a
connection's HTTP/2 streams before dispatch.  Default 0 (off);
C<max_body_len> applies per request regardless.  Requires H2.

Without it a peer can hold C<max_h2_concurrent_streams> bodies open at once
and dribble each toward C<max_body_len>, buffering the product (100 x 64 MiB
at the defaults), and C<read_timeout> resets on every byte.  A stream whose
data would push the total over the cap is reset with C<ENHANCE_YOUR_CALM>.
For untrusted H2 clients set it to the most you will buffer per connection
(a few times C<max_body_len>); behind a body-buffering proxy it can stay off.

=item C<< set_tls(cert_file => $path, key_file => $path, [listener => $idx]) >>

Enable TLS 1.3 on a listener.  Requires TLS support (picotls + OpenSSL; see
L<Alien::OpenSSL>).  C<cert_file> is a PEM certificate chain, C<key_file> the
matching PEM private key.  C<listener> is a 0-based index in
C<use_socket()>/C<accept_on_fd()> order, default the last-added.  Call it
after adding the listener; croaks with no listeners or an out-of-range index.
Listeners can have different TLS configurations or none.

    my $ngn = Feersum->endjinn;
    $ngn->use_socket($tls_socket);
    $ngn->set_tls(cert_file => 'default.crt', key_file => 'default.key');

For virtual hosting, add SNI entries (up to 32 per listener, matched
case-insensitively) after the default certificate; non-matching clients get
the default:

    $ngn->set_tls(sni => 'example.com', cert_file => 'ex.crt', key_file => 'ex.key');

With L<Alien::nghttp2> available at build time, C<< h2 => 1 >> enables
HTTP/2 via ALPN (otherwise only C<http/1.1> is offered).  A client whose ALPN
list shares no protocol with the server gets a fatal
C<no_application_protocol> alert; one that sends no ALPN gets HTTP/1.1.  It is
listener-wide: set it on the default-certificate call, not together with
C<sni>.  L<Feersum::Runner> accepts C<< h2 => 1 >> as a top-level option.

    $ngn->set_tls(cert_file => 'server.crt', key_file => 'server.key', h2 => 1);

=item C<< has_tls() >>

Returns true if compiled with TLS support (picotls).

=item C<< has_h2() >>

Returns true if compiled with HTTP/2 support (nghttp2).

=item C<< has_outq_probe() >>

Returns true if this build can ask the kernel how much of a socket's send
queue is undelivered (C<SIOCOUTQ>/C<SO_NWRITE>/C<FIONWRITE>), which
C<write_timeout> uses to spare slow-but-draining clients, plain and TLS
alike.

=back

=head1 GRITTY DETAILS

=head2 Compile Time Options

Constants defined in F<feersum_core.h>.  Mention any you changed in bug
reports.

=over 4

=item MAX_HEADERS

Default 64.  Maximum headers per request.  Over the limit the handler does
not run: 431 on HTTP/1.1 and HTTP/2 alike.

=item MAX_HEADER_NAME_LEN

Default 128.  Maximum header name length.  Over the limit: 431 on HTTP/1.1 and HTTP/2 alike.

=item MAX_TRAILER_HEADERS

Default 64.  Maximum trailer headers on a chunked (HTTP/1.1) or HTTP/2
request.  Over the limit: 400 on HTTP/1.1, a stream reset on HTTP/2.

=item MAX_CHUNK_COUNT

Default 100000.  Maximum chunks in one chunked request body; more is
rejected with 400.

=item MAX_PIPELINE_DEPTH

Default 15.  Pipelined HTTP/1.1 requests dispatched recursively off one
read; deeper pipelines are deferred to the next loop iteration.

=item FEER_MAX_LISTENERS

Default 16.  Listen sockets per server instance;
C<use_socket()>/C<accept_on_fd()> croak beyond it.

=item FEER_MAX_SNI_ENTRIES

Default 32.  SNI certificate entries per listener.

=item MAX_URI_LEN

Default 8192.  Default for C<max_uri_len()>: maximum request URI length
including the query string; over it both protocols get 414.

=item MAX_BODY_LEN

Default 64 MiB.  Default for C<max_body_len()>.  See also L</BUGS>.

=item READ_BUFSZ

=item READ_GROW_FACTOR

Defaults 4096 and 4.  Read buffers start at READ_BUFSZ bytes and grow by
READ_GROW_FACTOR * READ_BUFSZ whenever less than READ_BUFSZ is free before a
read (memory vs. system calls).

=item READ_TIMEOUT

Default for C<read_timeout()>, 5.0 seconds; also the keepalive idle timeout.

=item FEERSUM_IOMATRIX_SIZE

Size of the per-connection write-buffer structure, default 64 (under 4k per
connection on 64-bit platforms with the other structures).  Lower saves
memory at the cost of speed, most visibly with many sparse writes.  Where the
OS C<IOV_MAX>/C<UIO_MAXIOV> is smaller (Solaris: 16), the iovecs passed to
each C<writev(2)> are clamped at runtime; the struct size is unchanged.

=item FEER_H2_MAX_CONCURRENT_STREAMS

Default 100.  Default and ceiling for C<max_h2_concurrent_streams()>.

=item FEER_H2_MAX_HEADER_LIST_SIZE

Maximum header list size per HTTP/2 request (64 KB).

=item FEERSUM_STEAL

Enabled by default on non-threaded perls.  Feersum "steals" the contents of
non-magical string C<PADTMP> scalars used as response bodies instead of
copying them; they become C<undef>, which for temps does not matter.  If it
breaks on a new perl, send stash a note or a pull request on github.  A
similar zero-copy effect is available via C<psgix.body.scalar_refs>.

=back

=head2 Environment Variables

=over 4

=item C<FEERSUM_FREELIST_MAX>

Read at module BOOT.  Caps the per-process freelist of recycled
C<feer_req>/C<iomatrix> structs.  Default 32; C<0> disables struct caching.

=item C<FEERSUM_MAX_PRE_FORK>

Read by L<Feersum::Runner> at C<use>-time.  Caps the C<pre_fork> option;
default C<1000>.  Asking for more croaks.

=item C<FEERSUM_GRACEFUL_TIMEOUT>

Read by L<Feersum::Runner> at graceful shutdown; see
L<Feersum::Runner/graceful_timeout>.

=item C<FEERSUM_DEBUG>

Makes L<Feersum::Runner> keep STDERR attached to the terminal when
daemonizing instead of redirecting it to F</dev/null>.

=back

=head2 HTTP/2 Support

With TLS (picotls + L<Alien::OpenSSL>) and L<Alien::nghttp2> available at
build time, HTTP/2 is negotiated via ALPN on TLS connections.  It is
B<disabled by default>: pass C<< h2 => 1 >> to C<set_tls()> or to
L<Feersum::Runner>.

=over 4

=item *

B<TLS-only>: cleartext HTTP/2 (h2c) is not supported.

=item *

B<Request methods>: all methods pass through to the handler (HTTP/1.1
rejects non-standard ones with 405).  Request bodies are fully buffered
before the handler runs, as with HTTP/1.x.

=item *

B<Streaming responses>: C<psgi.streaming>/C<start_streaming()> work, each
C<write()> producing DATA frames.

=item *

B<Concurrent streams>: up to C<max_h2_concurrent_streams()> (default 100)
per connection.

=item *

B<Rapid-reset protection (CVE-2023-44487)>: a connection that opens and
resets more than C<FEER_H2_RST_FLOOD_THRESHOLD> (200) streams within
C<FEER_H2_RST_FLOOD_WINDOW> (10) seconds is closed.  Server-initiated resets
are not counted.

=item *

B<Not supported>: server push, server-sent trailers, incremental request
bodies, and C<sendfile> (use C<write()>).

=item *

B<IO::Handle response bodies>: a filehandle or C<getline>-style body is read
one C<getline> call at a time as the stream's buffer drains, like a
C<poll_cb> writer, so a client that stops reading stalls only its own stream.

=item *

B<PSGI environment>: C<psgi.url_scheme> is C<https>, C<SERVER_PROTOCOL> is
C<HTTP/2>.

=item *

B<Extended CONNECT / WebSocket tunnels (RFC 8441)>: Feersum advertises
C<SETTINGS_ENABLE_CONNECT_PROTOCOL=1> and translates an Extended CONNECT
into H1-equivalent env variables (as HAProxy/nghttpx do), so existing PSGI
WebSocket middleware works unchanged:

    REQUEST_METHOD       => 'GET'             # translated from CONNECT
    HTTP_UPGRADE         => 'websocket'       # synthesised from :protocol
    HTTP_CONNECTION      => 'Upgrade'         # synthesised
    psgix.h2.protocol    => 'websocket'       # raw :protocol value
    psgix.h2.extended_connect => 1

The native C<< $req->method() >> likewise returns C<GET>.  The handler writes
an C<HTTP/1.1 101> response with C<Upgrade:>/C<Connection:> headers to
C<psgix.io> (or C<< $req->io() >>) exactly as for HTTP/1.1; Feersum sends
the 200 HEADERS itself, swallows the 101, and relays the rest as DATA frames.
The handle is a Unix socketpair bridged to the stream in both directions.

=back

See C<eg/h2-server.pl> for a server serving h2 and HTTP/1.1 on one listener.

=head1 PERFORMANCE

Single process, loopback, C<wrk -t4 -c100 -d30>, "Hello World" response, on
a typical Linux server:

    Feersum native:  ~210K req/s
    Feersum PSGI:    ~132K req/s
    Gazelle:          ~44K req/s
    Starlet:          ~23K req/s
    Twiggy:           ~14K req/s
    Mojolicious:      ~2.8K req/s

Orientation only, not a controlled comparison: Feersum runs with keepalive
on, Gazelle has no keepalive, and Starlet serves one request per connection
by default.

The native C<request_handler> skips PSGI env construction and is roughly 50%
faster.  TLS 1.3 via picotls costs 25-35% on the native interface and
10-15% on PSGI; expect more without AES-NI.

Run C<bash bench/compare.sh> for numbers on your own hardware; see also
C<bench/run.sh>, C<bench/run_tls.sh>, C<bench/run_unix.sh> and
C<bench/pipeline.pl>.

=head1 DEPLOYMENT

=head2 Systemd

    # /etc/systemd/system/feersum.socket
    [Socket]
    ListenStream=80

    [Install]
    WantedBy=sockets.target

    # /etc/systemd/system/feersum.service
    [Service]
    ExecStart=/usr/bin/perl /path/to/app.pl
    NonBlocking=true
    User=www-data
    Group=www-data

See C<eg/systemd-socket.pl> for socket activation code.

=head2 Docker

    HEALTHCHECK --interval=5s CMD curl -sf http://localhost:5000/health

See C<eg/healthcheck.pl> for a health check endpoint pattern.

=head2 Reverse Proxy

Feersum works behind nginx, HAProxy, Caddy, or Envoy.  See C<eg/nginx.conf>,
C<eg/haproxy.cfg>, C<eg/Caddyfile>, C<eg/envoy.yaml> for example configs.
Enable C<reverse_proxy> or C<proxy_protocol> as appropriate.

=head2 Zero-Downtime Restart

For a B<PSGI> app use L<Plack::Handler::Feersum>:

    plackup -s Feersum --app-file=app.psgi --hot-restart=1 --pre-fork=4 \
        --listen 0.0.0.0:5000 app.psgi
    kill -HUP <master-pid>   # zero-downtime reload of app code

C<--app-file> is required: each generation re-reads the app from disk, and
the positional argument only supplies an already-compiled app.

L<Feersum::Runner> installs a B<native> handler, so use it directly only with
a native app file:

    perl -MFeersum::Runner -e '
        Feersum::Runner->new(
            listen      => ["0.0.0.0:5000"],
            app_file    => "app.feersum",
            hot_restart => 1,
            pre_fork    => 4,
        )->run;
    '

See C<eg/hot-reload.pl>.

=head1 UPGRADING

Upgrading from 1.505: most changes are additive, but the following can
affect a working application without code changes.  A plain PSGI handler
served over HTTP/1.1 with default settings usually needs no action, but check
the C<psgix.io> and graceful-stop notes below if you run a full framework or
collect logs from a container.

=head2 Requirements

Perl 5.14 or newer (was 5.8.7).

=head2 New and lowered default limits

Each is configurable; a request exceeding one is rejected before the handler
runs.

    setting            1.505             now
    -----------------  ----------------  ------------------
    max_body_len       2 GiB             64 MiB
    max_uri_len        (no limit)        8192      -> 414
    max_read_buf       (no limit)        64 MiB    -> 431/413
    max_connections    (no limit)        10000
    header_timeout     (none)            10 seconds
    write_timeout      (none)            0 (off)
    max_h2_conn_body   (n/a)             0 (off)   H2 only

Raise any of them with the corresponding method (L</METHODS>) if your
application accepts large uploads or long query strings.

=head2 Privilege drop now happens

1.505 silently ignored C<Feersum::Runner>'s C<user> and C<group> options
(C<plackup --user> included).  They now drop privileges: started as root, the
process switches user and clears supplementary groups; started as another
user, naming a different user croaks at startup (C<setgid> is refused).
Naming the user you already run as is a no-op.

=head2 Stricter request parsing

Now rejected:

=over 4

=item * An HTTP/1.1 request without C<Host:>: 400 (HTTP/1.0 without it is
still accepted).  Some hand-written health checks and load-balancer probes
omit it.

=item * Both C<Content-Length> and C<Transfer-Encoding> present: 400.

=item * Any C<Transfer-Encoding> on an HTTP/1.0 request: 400 (it was
ignored, a TE.CL desync risk; nginx's default C<proxy_http_version> is 1.0).

=item * A duplicate C<Host:>: 400.

=item * Obsolete line folding in a request header: 400.

=item * C<Transfer-Encoding> on a method that takes no body: 400.  An
unsupported transfer coding: 501.

=item * An C<Expect:> value other than C<100-continue>: 417.

=item * A header name longer than 128 bytes: 431.

=item * A C<Content-Length> with a leading sign (C<+5>): 400.  Surrounding
whitespace is still accepted.

=item * A PROXY protocol v2 TLV block ending in a 1 or 2 byte remainder:
rejected as malformed.

=back

An absolute-form request target (C<GET http://host/path HTTP/1.1>) now
yields the B<path> in C<PATH_INFO>; C<REQUEST_URI> still carries the raw
target.

=head2 Response behaviour

=over 4

=item * A response to C<HEAD> no longer carries a body; a returned body is
measured for C<Content-Length> only.

=item * 101 and 204 responses no longer pass through an application-supplied
C<Content-Length>, and 205 is now a no-body status.  Any other 1xx as a
final status, or a status above 599, answers 500.

=item * A no-body status returned with a body (array, filehandle or
C<sendfile>) sends none of it; those bytes used to arrive unframed and
desynchronise a keepalive connection.  Answering 304 with an open filehandle
is the usual case.

=item * A streaming response (including a filehandle body) honours an
application-supplied C<Content-Length> instead of discarding it.  Body bytes
past that length are dropped, and a body that ends short of it closes the
connection, so a file that changes size mid-response cannot desynchronise a
keepalive connection.

=item * A response header name or value containing a control character (a tab
is allowed in a value), or a status line containing CR or LF, is rejected
with 500 (response splitting).  Packing two C<Set-Cookie> values into one
string no longer works.

=item * A UTF8-flagged response string whose characters all fit in a byte is
sent as its downgraded bytes, like C<syswrite>-based servers, instead of in
Perl's internal encoding.  Strings with characters above 255 (illegal in
PSGI) still go out in the internal encoding.

=item * The native C<header()> joins duplicate request headers (with C<", ">,
or C<"; "> for C<Cookie>) instead of returning only the first.  In the PSGI
env and C<headers()>, which already joined with C<", ">, duplicate C<Cookie>
headers are now joined with C<"; ">.

=back

=head2 PSGI environment

=over 4

=item * C<psgi.input> is always a reader object, even without a body.  Test
C<CONTENT_LENGTH>, not the handle, for the presence of a body.

=item * C<psgix.input.buffered> is no longer advertised (the handle cannot
rewind; see L</"psgix.input.buffered">).  Reads still never block.  The
handle now supports C<getline>/C<getlines> and C<< <$fh> >>.

=item * C<psgi.multiprocess> is true under C<pre_fork>.

=item * C<psgix.io> is advertised by default, and reading its value takes the
socket (see L</"psgix.io">).  A framework or app that reads B<every> env
value (Mojolicious does, in its request parser) takes the socket by accident
and then returns an empty reply.  Disable the extension for such apps with
C<< $server->set_psgix_io(0) >> (C<< psgix_io => 0 >> in L<Feersum::Runner>).

=item * A UNIX-domain listener reports C<SERVER_NAME> C<unix> and
C<SERVER_PORT> C<0> (was C<localhost> and C<80>).

=back

=head2 Error reporting

The default C<Feersum::DIED> now warns the exception to STDERR; it used to
call C<Carp::confess>, whose exception was swallowed, so application
exceptions produced a 500 and no output.  Expect to see them in your logs;
install your own handler (L</DIED>) to change that.  A custom handler must
read the error from C<$_[0]>: it is no longer left in C<$@>.

=head2 Runner, C<plackup> and the CLI

=over 4

=item * C<plackup -s Feersum -D> now really daemonizes (redirecting STDERR
to F</dev/null>).  Remove it under a supervisor.

=item * C<SIGTERM> and C<SIGINT> trigger a graceful shutdown, up to
C<graceful_timeout> later: exit 0 on a clean drain, non-zero if the timeout
forces it.  Both used to kill the process at once.

=item * C<SIGHUP> without C<hot_restart> is ignored with a warning; it used to
kill the process.

=item * A graceful stop, a worker's C<max_requests_per_worker> retirement and
a hot-restart generation handover all exit via C<POSIX::_exit>, which runs no
C<END> blocks and does not flush buffered output.  An app logging to a pipe
(a container collecting STDOUT) should set C<< $| = 1 >> or log to STDERR, or
its last lines are lost at every stop; move any cleanup out of C<END>.

=item * C<--listen> in native mode accumulates instead of last-one-wins.

=item * C<bin/feersum --native> rejects unknown options.

=item * C<< read_timeout => 0 >> is rejected; it was silently ignored.

=item * The Feersum object is no longer a hash reference;
C<< Feersum->endjinn->{socket} >> no longer works.

=item * Per-connection tunables are snapshotted at accept, so runtime changes
no longer affect live connections, except C<header_timeout>, which is
re-read at each request start.

=back

=head1 BUGS

Please report bugs using L<https://github.com/stash/Feersum/issues>

Request bodies are capped at C<MAX_BODY_LEN> (64 MiB by default); for
untrusted clients run Feersum behind a reverse proxy that enforces tighter
entity-size limits.

SIGPIPE is ignored by the time your handler runs; use C<local $SIG{PIPE}>
(L<perlipc>) if you need to detect it.

Feersum is B<not thread-safe> and must not be used with Perl ithreads; it
uses unprotected global data.  Use pre-fork for parallelism.

=head1 SEE ALSO

Companion modules in this distribution:
L<Feersum::Runner>, L<Plack::Handler::Feersum>,
L<Feersum::Connection>, L<Feersum::Connection::Handle>.

Inspiration: L<https://en.wikipedia.org/wiki/Feersum_Endjinn>

picohttpparser: L<https://github.com/h2o/picohttpparser>

picotls: L<https://github.com/h2o/picotls>

=head1 AUTHORS

Jeremy Stashewsky, C<< stash@cpan.org >>

vividsnow - multi-instance, TLS 1.3 (picotls), HTTP/2 (nghttp2),
PROXY protocol v1/v2, security hardening

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
it under the same terms as Perl itself, either Perl version 5.14 or,
at your option, any later version of Perl 5 you may have available.

picohttpparser is Copyright 2009-2014 Kazuho Oku, Tokuhiro Matsuno, Daisuke
Murase, and Shigeo Mitsunari.  It is released under the same terms as Perl
itself (or, at your option, the MIT license).

picotls (bundled for TLS support) is Copyright (C) 2016-2025 DeNA Co., Ltd.,
Kazuho Oku, Fastly, and Christian Huitema, released under the MIT license
(the bundled PEM/base64 component is under the ISC license).  See the
per-file headers under F<picotls-git/> for the authoritative notices.

=cut
