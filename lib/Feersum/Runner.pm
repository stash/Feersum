package Feersum::Runner;
use strict;

use EV;
use Feersum;
use Socket qw/SOMAXCONN/;
use POSIX ();
use Scalar::Util qw/weaken/;

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
            Listen => SOMAXCONN,
            Blocking => 0,
        );
        die "couldn't bind to socket: $!" unless $sock;
    }
    $self->{sock} = $sock;
    my $f = Feersum->endjinn;
    $f->use_socket($sock);

    if ($self->{options}) {
        # Plack::Runner puts these here
        $self->{pre_fork} = delete $self->{options}{pre_fork};
        $self->{quiet} = 1;
    }

    $self->{endjinn} = $f;
}

# for overriding:
sub assign_request_handler {
    $_[0]->{endjinn}->request_handler($_[1]);
}

sub run {
    my $self = shift;
    weaken $self;

    $self->{quiet} or warn "Feersum [$$]: starting...\n";
    $self->_prepare();

    my $rh = shift || delete $self->{app} || do $self->{app_file};
    $self->assign_request_handler($rh);
    undef $rh;

    $self->{_quit} = EV::signal 'QUIT', sub { $self->quit };

    $self->pre_fork if $self->{pre_fork};
    EV::loop;
    $self->{quiet} or warn "Feersum [$$]: done\n";
}

sub fork_another {
    my ($self, $slot) = @_;
    weaken $self;

    my $pid = fork;
    die "failed to fork: $!" unless defined $pid;
    unless ($pid) {
        EV::default_loop()->loop_fork;
        $self->{quiet} or warn "Feersum [$$]: starting\n";
        delete $self->{_kids};
        delete $self->{pre_fork};
        eval { EV::loop; };
        warn $@ if $@;
        POSIX::exit($@ ? -1 : 0);
    }

    $self->{_n_kids}++;
    $self->{_kids}[$slot] = EV::child $pid, 0, sub {
        my $w = shift;
        $self->{quiet} or warn "Feersum [$$]: child $pid exited ".
            "with rstatus ".$w->rstatus."\n";
        $self->{_n_kids}--;
        if ($self->{_shutdown}) {
            EV::unloop(EV::UNLOOP_ALL) unless $self->{_n_kids};
            return;
        }
        $self->fork_another();
    };
}

sub pre_fork {
    my $self = shift;

    POSIX::setsid();

    $self->{_kids} = [];
    $self->{_n_kids} = 0;
    $self->fork_another($_) for (1 .. $self->{pre_fork});

    $self->{endjinn}->unlisten();
}

sub quit {
    my $self = shift;
    return if $self->{_shutdown};

    $self->{_shutdown} = 1;
    $self->{quiet} or warn "Feersum [$$]: shutting down...\n";
    my $death = 5;

    if ($self->{_n_kids}) {
        # in parent, broadcast SIGQUIT to the group
        kill 3, -$$; # kill process group, but not self
        $death += 2;
    }
    else {
        # in child or solo process
        $self->{endjinn}->graceful_shutdown(sub { POSIX::exit(0) });
    }

    $self->{_death} = EV::timer $death, 0, sub { POSIX::exit(1) };
}

1;
__END__

=head1 NAME

Feersum::Runner

=head1 SYNOPSIS

    use Feersum::Runner;
    my $runner = Feersum::Runner->new(
        listen => 'localhost:5000',
        pre_fork => 0,
        quiet => 1,
        app_file => 'app.feersum',
    );
    $runner->run($feersum_app);

=head1 DESCRIPTION

Much like L<Plack::Runner>, but with far fewer options.

=head1 ATTRIBUTES

The following initialization options are available.

=over 4

=item listen

Listen on this TCP socket (C<host:port> format).

=item pre_fork

Fork this many worker processes.

The fork is run immediately at startup and after the app is loaded (i.e. in
the C<run()> method).

=item quiet

Don't be so noisy.

=item app_file

Load this filename as a native feersum app.

=back

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
