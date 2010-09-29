package Feersum;
use 5.008007;
use strict;
use warnings;
use EV ();
use Carp ();

our $VERSION = '0.93';

require XSLoader;
XSLoader::load('Feersum', $VERSION);
require Feersum::Connection;
require Feersum::Connection::Handle;

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
sub DIED { warn "DIED: $@"; }

1;
__END__

=head1 NAME

Feersum - A scary-fast HTTP engine for Perl based on EV/libev

=head1 SYNOPSIS

    use Feersum;
    my $ngn = Feersum->endjinn; # singleton
    $ngn->use_socket($io_socket);
    
    # register a Feersum handler:
    $ngn->request_handler(sub {
        my $req = shift;
        my $t; $t = EV::timer 2, 0, sub {
            $req->send_response(
                200, ['Content-Type' => 'text/plain'],
                ["You win one cryptosphere!\n"]
            );
            undef $t;
        };
    });
    
    # register a PSGI handler
    $ngn->psgi_request_handler($app);

=head1 DESCRIPTION

A C<PSGI>-like HTTP server framework based on EV/libev.

B<WARNING: These interfaces are STILL highly experimental and will most likely
change.  Please consider this module a proof-of-concept at best.>

All of the request-parsing and I/O marshalling is done using C callbacks to
the libev library.  This is made possible by C<EV::MakeMaker>, which allows
extension writers to link against the same libev that C<EV> is using.

Since your Perl handler is executed in the same thread as the event loop, you
need to be careful to not block this thread.  Standard techniques include
using C<AnyEvent> or C<EV> idle and timer watchers, using C<Coro> to
multitask, and using sub-processes to do heavy lifting.

A trivial hello-world handler can process about 9000 requests per second on a
4-core Intel(R) Xeon(R) E5335 @ 2.00GHz using TCPv4 on the loopback interface,
OS Ubuntu 6.06LTS, Perl 5.8.7.  You mileage will likely vary.

Future versions of the module will hopefully increase PSGI compatiblity and
perhaps cooperate with C<Plack> and other middleware.

=head1 INTERFACE

The main entry point is the sub-ref passed to C<request_handler>.  This sub is
passed a reference to an object that represents an HTTP connection.
Currently the request_handler is called during the "check" and "idle" phases
of the EV event loop.  The handler is always called after request headers have
been read.  Currently it will also only be called after a full request entity
has been received for POST/PUT/etc.

There are a number of ways you can respond to a request.

First there's a PSGI-like response triplet.

    my $req = shift;
    $req->send_response(200, \@headers, ["body ", \"parts"]);

Or, if all you've got is a simple body, you can pass it in via scalar-ref.

    my $req = shift;
    $req->send_response(200, \@headers, \"whole body");

(Scalar refs in the response body are indicated by the
C<psgix.body.scalar_refs> env variable. Passing by reference rather than
copying onto the stack or into an array is B<significantly> faster.)

Delayed responses are perfectly fine, just don't block the main thread or
other requests/responses won't get processed.

    my $req = shift;
    # "0" tells Feersum to not use chunked encoding and to emit a
    # Content-Length header. Other headers are transmitted immediately.
    $req->start_response(200, \@headers, 0);
    my $t; $t = EV::timer 2, 0, sub {
        $req->write_whole_body(\@chunks);
        undef $t;
    };

Chunked responses are possible.  Starting a response in chunked mode enables
the C<write()> method (which really acts more like a buffered 'print').  Calls
to C<write()> will never block (as indicated by C<psgix.output.buffered> in
the PSGI env hash).  

    my $req = shift;
    # "1" tells Feersum to send a streaming response.
    $req->start_response(200, \@headers, 1);
    my $w = $req->write_handle;
    $w->write(\"this is a reference to some shared chunk\n");
    $w->write("regular scalars are OK too\n");
    # close off the stream
    $w->close()

Feersum will use "Transfer-Encoding: chunked" for HTTP/1.1 clients and
"Connection: close" streaming as a fallback.  technically "Connection: close"
streaming isn't part of the HTTP/1.0 or 1.1 spec, but many browsers and agents
support it anyway.

A PSGI-like environment hash is easy to obtain.

    my $req = shift;
    my $env = $req->env();

Currently POST/PUT does not stream input, but read() can be called on
C<psgi.input> to get the body (which has been buffered up before the request
callback is called and therefore will never block).  Likely C<read()> will
change to give EAGAIN responses and allow for a callback to be registered on
the arrival of more data. (The C<psgix.input.buffered> env var is set to
reflect this).

    my $req = shift;
    my $env = $req->env();
    if ($req->{REQUEST_METHOD} eq 'POST') {
        my $body = '';
        my $r = delete $env->{'psgi.input'};
        $r->read($body, $env->{CONTENT_LENGTH});
        # optional: choose to stop receiving further input:
        # $r->close();
    }

An interface close to C<psgi.streaming> is emulated with a call to
C<initiate_streaming>.  The "starter" code-ref and "writer" I/O object are
used roughly as they are in PSGI.  C<initiate_streaming> currently forces
C<Transfer-Encoding: chunked> for the response and needs to be called before
any C<write> or C<start_response> calls.

    my $req = shift;
    $req->initiate_streaming(sub {
        my $starter = shift;
        my $w = $starter->(
            "200 OK", ['Content-Type' => 'application/json']);
        my $n = 0;
        $w->write('[');

        my $t; $t = EV::timer 1, 1, sub {
            $w->write(q({"time":).time."},");

            if ($n++ > 60) {
                // stop the stream
                $w->write("{}]");
                $w->close();
                undef $t;
            }
        };
    });

The writer object supports C<poll_cb> as specified in PSGI 1.03.  Feersum will
call this method only when all data has been flushed out at the socket level.
Use C<close()> or unset the handler (C<< $w->poll_cb(undef) >>) to stop the
callback from getting called.

    my $req = shift;
    $req->initiate_streaming(sub {
        my $starter = shift;
        my $w = $starter->(
            "200 OK", ['Content-Type' => 'application/json']);
        my $n = 0;
        $w->poll_cb(sub {
            $_[0]->write(get_next_chunk());
            $_[0]->close if ($n++ >= 100);
        });
    });

And, finally, you can register a PSGI "app" reference:

    my $app = do $filename;
    Feersum->endjinn->psgi_request_handler($app);

See also L<Plack::Handler::Feersum>.

=head1 METHODS

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
connections have been flushed and closed.  This allows you to do something
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

=head1 SEE ALSO

http://en.wikipedia.org/wiki/Feersum_Endjinn

Feersum Git: C<http://github.com/stash/Feersum>
C<git://github.com/stash/Feersum.git>

picohttpparser Git: C<http://github.com/kazuho/picohttpparser>
C<git://github.com/kazuho/picohttpparser.git>

=head1 AUTHOR

Jeremy Stashewsky, C<< stash@cpan.org >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Jeremy Stashewsky & Socialtext Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.7 or,
at your option, any later version of Perl 5 you may have available.

picohttpparser is Copyright 2009 Kazuho Oku.  It is released under the same
terms as Perl itself.

=cut
