package Feersum;
use 5.008007;
use strict;
use warnings;
use EV ();
use Carp ();

=head1 NAME

Feersum - A scary-fast HTTP engine for Perl based on EV/libev

=cut

our $VERSION = '0.02';

=head1 SYNOPSIS

    use Feersum;
    my $ngn = Feersum->new();
    $ngn->use_socket($io_socket);
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

=head1 DESCRIPTION

A C<PSGI>-like HTTP server framework based on EV/libev.

B<These interfaces are highly experimental and will most likely change.>
B<Please consider this module a proof-of-concept at best.>

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
has been received for POST/PUT/etc. (although support for streaming input is
in the works, hopefully).

There are a number of ways you can respond to a request.

Delayed responses are perfectly fine, just don't block the main thread or
other requests/responses won't get processed.

    # "0" tells Feersum to not use chunked encoding and to emit a
    # Content-Length header
    my $req = shift;
    $req->start_responding(200, \@headers, 0);
    my $t; $t = EV::timer 2, 0, sub {
        $req->write_whole_body(\@chunks);
        undef $t;
    };

Chunked responses are possible.  Starting a response in chunked mode enables
the C<write()> method (which really acts more like a buffered 'print').

    # "1" tells Feersum to send a Transfer-Encoding: chunked response
    my $req = shift;
    $req->start_responding(200, \@headers, 1);
    my $w = $req->write_handle;
    $w->write(\"this is a reference to some shared chunk\n");
    $w->write("regular scalars are OK too\n");
    # close off the stream
    $w->close()

A PSGI-like environment hash is easy to obtain.  Currently POST/PUT does not
stream input, but read() can be called on C<psgi.input> to get the body (which
has been buffered up before the request callback is called (and therefore will
never block).  Likely C<read()> will change to give EAGAIN responses and allow
for a callback to be registered on the arrival of more data.

    my $req = shift;
    my %env;
    $req->env(\%env);
    if ($req->{REQUEST_METHOD} eq 'POST') {
        my $body = '';
        my $r = delete $env{'psgi.input'};
        $r->read($body, $env{CONTENT_LENGTH});
        # optional: choose to stop receiving further input:
        # $r->close();
    }

The C<psgi.streaming> interface is emulated with a call to
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

=head1 METHODS

B<Notice> some methods are not documented yet.

=over 4

=item use_socket ($sock)

Use the file-descriptor attached to a listen-socket to accept connections.  If
you create this using IO::Socket::INET, you should keep a reference to $sock
to prevent closing the descriptor during garbage-collection.

=item request_handler ($code->($connection))

Sets the global request handler.  Any previous handler is replaced.

The handler callback is passed a C<Feersum::Connection> object.  See above for
how to use this for now.

B<Subject to change>: if the request has an entity body then the handler will
be called B<only> after receiving the body in its entirety.  The headers
*must* specify a Content-Length of the body otherwise the request will be
rejected.  The maximum size is hard coded to 2147483647 bytes (this may be
considered a bug).

=item read_timeout

=item read_timeout ($duration)

Get or set the global read timeout.

Feersum will wait about this long to receive all headers of a request (within
the tollerances provided by libev).  If an entity body is part of the request
(e.g. POST or PUT) it will wait this long between successful C<read()> system
calls.

=item DIED

Not really a method so much as a static function.  Works similar to
EV's/AnyEvent's error handler.

To install a handler:

    no strict 'refs';
    *{Feersum::DIED} = sub { warn "nuts $_[0]" };

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

require XSLoader;
XSLoader::load('Feersum', $VERSION);

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
}

# overload this to catch Feersum errors and exceptions thrown by request
# callbacks.
sub DIED {
    warn "DIED: $@";
}

package Feersum::Connection;
use strict;

sub send_response {
    # my ($self, $msg, $hdrs, $body) = @_;
    $_[0]->start_response($_[1], $_[2], 0);
    $_[0]->write_whole_body(ref($_[3]) ? $_[3] : \$_[3]);
}

sub initiate_streaming {
    my $self = shift;
    my $streamer = shift;
    Carp::croak "Feersum: Expected coderef"
        unless ref($streamer) eq 'CODE';
    @_ = (sub {
        $self->start_response($_[0],$_[1],1);
        return $self->write_handle;
    });
    goto &$streamer;
}

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

package Feersum;

1;
__END__

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

Chunked-encoding responses can be sent to HTTP/1.0 clients, which is only part
of the HTTP/1.1 spec.

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
