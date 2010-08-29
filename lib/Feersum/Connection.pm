package Feersum::Connection;
use strict;

sub new {
    Carp::croak "Cannot instantiate Feersum::Connection directly";
}

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

1;
__END__

=head1 NAME

Feersum::Connection - HTTP connection encapsulation

=head1 SYNOPSIS

    Feersum->endjinn->request_handler(sub {
        my $req = shift; # this is a Feersum::Connection object
        my %env;
        $req->env(\%env);
        $req->start_response(200, ['Content-Type' => 'text/plain'], 0);
        $req->write_whole_body(\"Ergrates FTW.");
    });

=head1 DESCRIPTION

Encapsulates an HTTP connection to Feersum.  It's roughly analagous to an
C<Apache::Request> or C<Apache2::Connection> object, but differs significantly
in functionality.  Until Keep-Alive functionality is supported (if ever) this
means that a connection is B<also> a request.

=head1 METHODS

=over 4

=item C<< $o->start_response($code, \@headers, $streaming) >>

Begin responding.

If C<$streaming> is false, a partial HTTP response is sent.  The partial
response is missing the Content-Length header, which will be sent when
C<write_whole_body> is called.

If C<$streaming> is true, a full HTTP header section is sent with
"Transfer-Encoding: chunked" instead of a Content-Length.  The C<write_handle>
method or the C<write_whole_body> method should be used to complete the
response.

=item C<< $o->write_whole_body($data) >>

=item C<< $o->write_whole_body(\$data) >>

=item C<< $o->write_whole_body(\@chunks) >>

Emits the parameter(s) as the response body and closes the request.

References to scalars are supported (and are much faster than passing arround
scalars).

=item C<< $o->send_response($code, \@headers, ....) >>

Convenience macro.  Is equivalent to start_response with a streaming parameter
of 0 followed by a call to write_whole_body.

=item C<< $w = $o->write_handle; >>

Returns a L<Feersum::Connection::Handle> in Writer mode for this request.
Must only be used when the connection has been put into streaming mode.

=item C<< $o->initiate_streaming(sub { .... }) >>

For support of the C<psgi.streaming> feature, takes a sub (which is
immediately called).  The sub is, in turn, passed a code reference. The code
reference will return a Writer object when called with C<< $code, \@header >>
parameters.  See L<Feersum> for examples.

=back

=head1 AUTHOR

Jeremy Stashewsky, C<< stash@cpan.org >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Jeremy Stashewsky & Socialtext Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.7 or,
at your option, any later version of Perl 5 you may have available.

=cut
