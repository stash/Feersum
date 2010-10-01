package Plack::Handler::Feersum;
use strict;
use Feersum::Runner;
use base 'Feersum::Runner';

sub run {
    my $self = shift;
    $self->_prepare();
    $self->{endjinn}->psgi_request_handler(shift);
    EV::loop;
}

1;
__END__

=head1 NAME

Plack::Handler::Feersum - plack adapter for Feersum

=head1 SYNOPSIS

    plackup -s Feersum app.psgi

=head1 DESCRIPTION

This is a stub module that allows Feersum to be loaded up under C<plackup> and
other Plack tools.  Set C<< $ENV{PLACK_SERVER} >> to 'Feersum' or use the -s
parameter to plackup to use Feersum under Plack.

=head1 AUTHOR

Jeremy Stashewsky, C<< stash@cpan.org >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Jeremy Stashewsky & Socialtext Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.7 or,
at your option, any later version of Perl 5 you may have available.

=cut
