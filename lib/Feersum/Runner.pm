package Feersum::Runner;
use strict;

use EV;
use Feersum;

sub new { my $c = shift; bless {@_},$c }

sub _prepare {
    my $self = shift;

    my @listen = @{$self->{listen} || [ ($self->{host} || '') . ":$self->{port}" ]};
    die "multiple listen directives not yet supported" if @listen > 1;
    my $listen = shift @listen;

    my $sock;
    if ($listen =~ m#^unix/#) {
        die "listening on a unix socket isn't supported yet";
    }
    else {
        require IO::Socket::INET;
        $sock = IO::Socket::INET->new(
            LocalAddr => $listen,
            ReuseAddr => 1,
            Proto => 'tcp',
            Listen => 1024,
            Blocking => 0,
        );
    }
    $self->{sock} = $sock;
    my $f = Feersum->endjinn;
    $f->use_socket($sock);

    $self->{endjinn} = $f;
}

sub run {
    my $self = shift;
    $self->_prepare();
    my $rh = shift || delete $self->{app};
    die "not a code ref" unless ref($rh) eq 'CODE';
    $self->{endjinn}->request_handler($rh);
    undef $rh;
    EV::loop;
}

1;
__END__

=head1 NAME

Feersum::Runner

=head1 SYNOPSIS

    use Feersum::Runner;
    my $runner = Feersum::Runner->new(
        listen => 'localhost:12345',
    );
    $runner->run($feersum_app);

=head1 DESCRIPTION

Much like L<Plack::Runner>, but with far fewer options (only a single 'listen'
or 'host'/'port' pair is currently supported).

=head1 METHODS

=over 4

=item C<< $runner->run($feersum_app) >>

Run Feersum with the specified app code reference.  Note that this is not a
PSGI app, but a native Feersum app.

=back

=head1 AUTHOR

Jeremy Stashewsky, C<< stash@cpan.org >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Jeremy Stashewsky & Socialtext Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.7 or,
at your option, any later version of Perl 5 you may have available.

=cut
