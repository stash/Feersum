package Feersum::Connection;
use warnings;
use strict;
use Carp qw/croak/;
use IO::Socket::INET;

sub new {
    croak "Cannot instantiate Feersum::Connection directly";
}

sub _initiate_streaming_psgi {
    my ($self, $streamer) = @_;
    return $streamer->(sub { $self->_continue_streaming_psgi(@_) });
}

my $_pkg = "Feersum::";
sub _raw { ## no critic (RequireArgUnpacking)
    # don't shift; want to modify $_[0] directly.
    my $fileno = $_[1];
    my $name = "RAW$fileno";
    # make new_from_fd's gensym live in the Feersum package
    no warnings 'redefine';
    local *IO::Handle::gensym = sub {
        no strict;
        my $gv = \*{$_pkg.$name};
        delete $$_pkg{$name};
        $gv;
    };
    $_[0] = IO::Socket::INET->new_from_fd($fileno, '+<');
    # Feersum then PerlIO_unread()s any buffered remainder into it
    return;
}
1;
__END__

=encoding UTF-8

=head1 NAME

Feersum::Connection - HTTP connection encapsulation

=head1 SYNOPSIS

For a streaming response:

    Feersum->endjinn->request_handler(sub {
        my $req = shift; # this is a Feersum::Connection object
        my $env = $req->env();
        my $w = $req->start_streaming(200, ['Content-Type' => 'text/plain']);
        # then immediately or after some time:
        $w->write("Ergrates ");
        $w->write(\"FTW.");
        $w->close();
    });

For a response with a Content-Length header:

    Feersum->endjinn->request_handler(sub {
        my $req = shift; # this is a Feersum::Connection object
        my $env = $req->env();
        $req->send_response(200, ['Content-Type' => 'text/plain'], \"Ergrates FTW.");
    });

=head1 DESCRIPTION

Encapsulates an HTTP connection to Feersum.  It's roughly analogous to an
C<Apache::Request> or C<Apache2::Connection> object, but differs significantly
in functionality.

With HTTP/1.1 Keep-Alive support, multiple requests can be served over
the same connection.

See L<Feersum> for more examples on usage.

=head1 METHODS

=over 4

=item C<< my $env = $req->env() >>

Obtain an environment hash.  This hash contains the same entries as for a PSGI
handler environment hash, except C<psgix.io> (only added for PSGI handlers; use
C<< $req->io() >> instead).  See L<Feersum> for details on the contents.

=item C<< my $w = $req->start_streaming($code, \@headers) >>

A full HTTP header section is sent with "Transfer-Encoding: chunked" (or
"Connection: close" for HTTP/1.0 clients).  For responses that MUST NOT
have a body (1xx, 204, 205, 304), no Transfer-Encoding header is added
regardless of HTTP version.

Returns a C<Feersum::Connection::Writer> handle which should be used to
complete the response.  See L<Feersum::Connection::Handle> for methods.

=item C<< $req->send_response($code, \@headers, $body) >>

=item C<< $req->send_response($code, \@headers, \@body) >>

Respond with a full HTTP header (including C<Content-Length>) and body.

Returns the number of bytes calculated for the body.

B<Zero-copy:> a scalar-ref body (or the scalars inside an array-ref body) may
be queued by reference rather than copied, and the response is transmitted
after the handler returns.  Do not modify a scalar after handing it to
C<send_response>; see L<Feersum::Connection::Handle/"Writer methods."> for the
full contract and examples.  Building a fresh scalar per response, which is
what most code does anyway, is always safe.

B<Header validation:> response header names containing CR, LF or colon, and
header values or status messages containing CR or LF, are rejected to
prevent HTTP response splitting (CWE-113).  In the PSGI dispatch path a 500
is sent; in the native interface the call croaks (propagates via
L<Feersum/DIED>).

=item C<< $req->force_http10 >>

=item C<< $req->force_http11 >>

Force the response to use HTTP/1.0 or HTTP/1.1, respectively, instead of
matching the request version.  Streaming uses C<Transfer-Encoding: chunked>
under HTTP/1.1 and a C<Connection: close> stream under HTTP/1.0; use these to
override for user-agents that cannot handle one of them.

=item C<< $req->is_http11 >>

Returns true if the request was made using HTTP/1.1, false otherwise.
Useful for determining protocol capabilities before sending a response.
Also returns true for HTTP/2 streams (internally they reuse the HTTP/1.1
header semantics); check C<SERVER_PROTOCOL> in the env hash to distinguish
HTTP/2.

=item C<< $req->is_keepalive >>

Returns true if the connection has keep-alive enabled for this request.
This takes into account the HTTP version, Connection header, and server
configuration.

=item C<< $req->fileno >>

The socket file-descriptor number for this connection.

=item C<< $req->io >>

Returns an L<IO::Handle> for the underlying connection.  For plain (non-TLS)
connections this wraps the raw socket file descriptor (an L<IO::Socket::INET>,
whether the underlying connection is TCP or Unix domain).
For TLS and HTTP/2 Extended CONNECT connections, this returns one end of a
Unix socketpair; Feersum relays data between the other end and the TLS or
H2 layer transparently.  The handle is bidirectional and suitable for
WebSocket or other tunnel protocols.

This is the native interface equivalent of C<psgix.io> in the PSGI
environment.  Any buffered request data will be pushed back into the
handle's read buffer.

B<WARNING>: Once you call this method, Feersum relinquishes control of the
socket. You are responsible for all I/O and must not use other Feersum
response methods on this connection.  On HTTP/2, C<io()> is supported only
for Extended CONNECT tunnel streams (RFC 8441); calling it on a regular
(non-tunnel) HTTP/2 stream croaks, since handing out the shared TCP socket
would corrupt the other multiplexed streams.

=item C<< $req->return_from_io($io) >>

Returns control of the socket to Feersum after C<io()> was called, so
keep-alive can continue if the connection was not upgraded (a failed
WebSocket handshake, say).  Any data buffered in the IO handle is pulled back
into Feersum's read buffer; returns the number of bytes pulled back.

The hand-back ends the original request: C<env()> and C<method()> croak
afterwards, and a response sent from here is not shaped by the request (a
C<HEAD> answered after the hand-back gets a body), so decide before calling
C<io()>.

The hand-back takes a private duplicate of the descriptor, so C<$io> stays
usable and may be released at any time; the socket stays open until it is.

Croaks unless C<$io> wraps this connection's socket, and on TLS tunnel
connections and HTTP/2 streams, neither of which can be handed back.

=item C<< $req->response_guard($guard) >>

Register a guard to be triggered when the response is completely sent and the
socket is closed.  A "guard" in this context is some object that will do
something interesting in its DESTROY/DEMOLISH method. For example, L<Guard>.

B<On a keepalive connection this is not when the response finishes.>  The guard
is released at whichever comes first: the next C<response_guard()> call on the
same connection, which replaces it, or the connection closing.  So an app that
registers one on every request sees request N's guard fire during request N+1's
handler, and the last one only at close.  Do not use a guard to release a
per-request resource unless keepalive is off.

=item C<< my $method = $req->method >>

req method (GET/POST..) (psgi REQUEST_METHOD)

=item C<< my $uri = $req->uri >>

full request uri (psgi REQUEST_URI)

=item C<< my $protocol = $req->protocol >>

The HTTP version from the request line: C<HTTP/1.1> or C<HTTP/1.0>.

B<Note:> unlike C<< $env->{SERVER_PROTOCOL} >>, this returns C<HTTP/1.1> for
an HTTP/2 stream - it reports the request-line version, which HTTP/2 does not
have.  Check the env hash if you need to distinguish HTTP/2.

=item C<< my $path = $req->path >>

percent decoded request path (psgi PATH_INFO)

=item C<< my $query = $req->query >>

request query (psgi QUERY_STRING)

=item C<< my $len = $req->content_length >>

body content length (psgi CONTENT_LENGTH)

=item C<< my $input = $req->input >>

Input body handler (psgi.input).  Returns C<undef> when there is no body to
read -- i.e. the (decoded) body length is zero, as for GET/HEAD or a
zero-length POST.  Note a chunked request with a non-empty body has no
Content-Length yet still yields a handle.  Check with C<defined> before
use.  It is advised to close it after read is done.

=item C<< my $headers = $req->headers([normalization_style]) >>

Returns a hash reference of headers in form of { name => value, ... }.

normalization_style is one of (always use named constants, not numeric values):

HEADER_NORM_SKIP (0) - skip normalization (default)
HEADER_NORM_UPCASE_DASH (1) - "CONTENT_TYPE" (like PSGI, but without "HTTP_" prefix)
HEADER_NORM_LOCASE_DASH (2) - "content_type"
HEADER_NORM_UPCASE (3) - "CONTENT-TYPE"
HEADER_NORM_LOCASE (4) - "content-type"

One can export these constants via C<< use Feersum 'HEADER_NORM_LOCASE' >>

=item C<< my $value = $req->header(name) >>

Lookup a single header value by name (case-insensitive).  When multiple
headers share the same name, values are joined with C<", "> (or C<"; "> for
cookies per RFC 9113 section 8.2.3).  Returns C<undef> if the header is absent.

=item C<< my $addr = $req->remote_address >>

Remote address of the connection (psgi REMOTE_ADDR).  When PROXY protocol is
active, returns the client address from the PROXY header; otherwise returns
the socket peer address.

=item C<< my $port = $req->remote_port >>

Remote port of the connection (psgi REMOTE_PORT).  When PROXY protocol is
active, returns the client port from the PROXY header.

=item C<< my $addr = $req->client_address >>

Client address, respecting reverse proxy mode. When C<reverse_proxy> is
enabled and the leftmost entry of X-Forwarded-For is a valid IPv4 or IPv6
address, returns that address. If the header is absent or its first value is
not a valid IP (e.g. a hostname or spoofed string), returns the same as
C<remote_address>.

=item C<< my $scheme = $req->url_scheme >>

URL scheme (http or https). Resolution order: (1) "https" if the connection
uses TLS or HTTP/2, (2) "https" if PROXY protocol indicates SSL (PP2_TYPE_SSL
TLV) or original destination port 443, (3) X-Forwarded-Proto header value when
C<reverse_proxy> is enabled, (4) "http" otherwise.

=item C<< my $tlvs = $req->proxy_tlvs >>

Returns a hash reference of PROXY protocol v2 TLV (Type-Length-Value)
extensions, or C<undef> if no TLVs were received. Keys are TLV type
numbers (as integers), values are raw TLV data bytes. Only populated
when C<proxy_protocol> is enabled and the client sends a v2 header
with TLV extensions (e.g. PP2_TYPE_SSL, PP2_TYPE_AUTHORITY).

=item C<< my $trailers = $req->trailers >>

Returns an array reference of request trailers in form of [ name => value, ... ],
or C<undef> if no trailers were received. Only supported for HTTP/2
requests currently.

=back

=begin comment

=head2 Private Methods

=over 4

=item C<< new() >>

Croaks; connections cannot be constructed directly. Feersum creates these
objects internally.

=back

=end comment

=head1 AUTHOR

Jeremy Stashewsky, C<< stash@cpan.org >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Jeremy Stashewsky & Socialtext Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.14 or,
at your option, any later version of Perl 5 you may have available.

=cut
