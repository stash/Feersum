package Feersum::Connection;
use strict;
use Carp qw/croak/;

sub new {
    croak "Cannot instantiate Feersum::Connection directly";
}

sub read_handle {
    croak "read_handle is deprecated; use psgi.input instead";
}

sub write_handle {
    croak "write_handle is deprecated; ".
        "use return value from start_streaming instead";
}

sub start_response {
    croak "start_response is deprecated; ".
        "use start_streaming() or start_whole_response() instead";
}

sub initiate_streaming {
    croak "initiate_streaming is deprecated; ".
        "use start_streaming() and its return value instead";
}

sub _initiate_streaming_psgi {
    my ($self, $streamer) = @_;
    @_ = (sub {
        my $strm = shift;
        if ($#$strm == 2) {
            $self->send_response($strm->[0],$strm->[1],$strm->[2]);
        }
        elsif ($#$strm == 1) {
            return $self->start_streaming($strm->[0],$strm->[1]);
        }
        else {
            croak "PSGI streaming starter expects an array";
        }
        return;
    });

    if (ref($streamer) eq 'CODE') {
        goto &$streamer;
    }
    # Maybe it's callable but not a CODE-ref:
    $streamer->(@_);
}

1;
__END__

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
        $req->start_whole_response(200, ['Content-Type' => 'text/plain']);
        $req->write_whole_body(\"Ergrates FTW.");
    });

=head1 DESCRIPTION

Encapsulates an HTTP connection to Feersum.  It's roughly analagous to an
C<Apache::Request> or C<Apache2::Connection> object, but differs significantly
in functionality.

Until Keep-Alive functionality is supported (if ever) this means that a
connection is B<also> a request.

See L<Feersum> for more examples on usage.

=head1 METHODS

=over 4

=item C<< my $env = $req->env() >>

Obtain an environment hash.  This hash contains the same entries as for a PSGI
handler environment hash.  See L<Feersum> for details on the contents.

This is a method instead of a parameter so that future versions of Feersum can
request a slice of the hash for speed.

=item C<< my $w = $req->start_streaming($code, \@headers) >>

A full HTTP header section is sent with "Transfer-Encoding: chunked" (or
"Connection: close" for HTTP/1.0 clients).  

Returns a C<Feersum::Connection::Writer> handle which should be used to
complete the response.  See L<Feersum::Connection::Handle> for methods.

=item C<< $req->send_response($code, \@headers, $body) >>

=item C<< $req->send_response($code, \@headers, \@body) >>

Respond with a full HTTP header (including C<Content-Length>) and body.

Returns the number of bytes calculated for the body.

=item C<< $req->force_http10 >>

=item C<< $req->force_http11 >>

Force the response to use HTTP/1.0 or HTTP/1.1, respectively.

Normally, if the request was made with 1.1 then Feersum uses HTTP/1.1 for the
response, otherwise HTTP/1.0 is used (this includes requests made with the
HTTP "0.9" non-declaration).

For streaming under HTTP/1.1 C<Transfer-Encoding: chunked> is used, otherwise
a C<Connection: close> stream-style is used (with the usual non-guarantees
about delivery).  You may know about certain user-agents that
support/don't-support T-E:chunked, so this is how you can override that.

Supposedly clients and a lot of proxies support the C<Connection: close>
stream-style, see support in Varnish at
http://www.varnish-cache.org/trac/ticket/400

=item C<< $req->fileno >>

The socket file-descriptor number for this connection.

=back

=head1 AUTHOR

Jeremy Stashewsky, C<< stash@cpan.org >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Jeremy Stashewsky & Socialtext Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.7 or,
at your option, any later version of Perl 5 you may have available.

=cut
