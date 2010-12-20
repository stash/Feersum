package Plack::Handler::Feersum;
use strict;
use Feersum::Runner;
use base 'Feersum::Runner';
use Scalar::Util qw/weaken/;

sub assign_request_handler {
    my $self = shift;
    weaken $self;
    $self->{endjinn}->psgi_request_handler(shift);
    # Plack::Loader::Restarter will SIGTERM the parent
    $self->{_term} = EV::signal 'TERM', sub { $self->quit };
}

1;
__END__

=head1 NAME

Plack::Handler::Feersum - plack adapter for Feersum

=head1 SYNOPSIS

    plackup -s Feersum app.psgi
    plackup -s Feersum --listen localhost:8080 app.psgi
    plackup -s Feersum --pre-fork=4 -MMy::App -L delayed app.psgi

=head1 DESCRIPTION

This is a stub module that allows Feersum to be loaded up under C<plackup> and
other Plack tools.  Set C<< $ENV{PLACK_SERVER} >> to 'Feersum' or use the -s
parameter to plackup to use Feersum under Plack.

=head2 Experimental Features

A C<--pre-fork=N> parameter can be specified to put feersum into pre-forked
mode where N is the number of child processes.  The C<--preload-app> parameter
that L<Starlet> supports isn't supported yet.  The fork is run immediately
after startup and after the app is loaded (i.e. in the C<run()> method).

=head1 METHODS

=over 4

=item C<< assign_request_handler($app) >>

Assigns the PSGI request handler to Feersum.

Also sets up a SIGTERM handler to call the C<quit()> method so that
L<Plack::Loader::Restarter> will work.

=back

=head1 SEE ALSO

Most of the functionality is in L<Feersum::Runner> (the base class)

=head1 AUTHOR

Jeremy Stashewsky, C<< stash@cpan.org >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Jeremy Stashewsky & Socialtext Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.7 or,
at your option, any later version of Perl 5 you may have available.

=cut
