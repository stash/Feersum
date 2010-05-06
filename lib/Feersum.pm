package Feersum;
use 5.008007;
use strict;
use warnings;
use EV ();
use Carp ();

=head1 NAME

Feersum - A scary-fast HTTP engine for Perl based on EV/libev

=cut

our $VERSION = '0.01';

=head1 SYNOPSIS

    use Feersum;
    my $endjinn = Feersum->new();
    $endjinn->use_socket($io_socket);
    $endjinn->request_handler(sub {
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
passed a reference to an object that represents an HTTP client connection.
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
    $req->write(\"this is a reference to some shared chunk\n");
    $req->write("regular scalars are OK too\n");
    # close off the stream
    $req->write(undef); # XXX: may change to ->close()

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
        $env{'psgi.input'}->read($body, $env{CONTENT_LENGTH});
    }

The C<psgi.streaming> interface is emulated with a call to
C<initiate_streaming>.  The "starter" code-ref and "writer" I/O object are
used roughly as they are in PSGI.  C<initiate_streaming> currently forces
C<Transfer-Encoding: chunked> for the response and needs to be called before
any C<write> or C<start_response> calls.

    my $req = shift;
    $req->initiate_streaming(sub {
        my $starter = shift;
        my $writer = $starter->(
            "200 OK", ['Content-Type' => 'application/json']);
        my $n = 0;
        $writer->write('[');

        my $t; $t = EV::timer 1, 1, sub {
            $writer->write(q({"time":).time."},");

            if ($n++ > 60) {
                // stop the stream
                $writer->write("{}]");
                $writer->write(undef); # XXX: this may change to ->close()
                undef $t;
            }
        };
    });

=head1 METHODS

TODO

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

package Feersum::Client;

sub send_response {
    # my ($self, $msg, $hdrs, $body) = @_;
    $_[0]->start_response($_[1], $_[2], 0);
    $_[0]->write_whole_body(ref($_[3]) ? $_[3] : \$_[3]);
}

sub initiate_streaming {
    my $self = shift;
    my $streamer = shift;
    Carp::croak "Feersum: Expected code reference argument to stream_response"
        unless ref($streamer) eq 'CODE';
    my $start_cb = sub {
        $self->start_response($_[0],$_[1],1);
        return $self;
    };
    @_ = ($start_cb);
    goto &$streamer;
}

package Feersum;

1;
__END__

=head1 SEE ALSO

http://en.wikipedia.org/wiki/Feersum_Endjinn

=head1 AUTHOR

Jeremy Stashewsky, C<< jstash@cpan.org >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Jeremy Stashewsky & Socialtext Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.7 or,
at your option, any later version of Perl 5 you may have available.

=cut
