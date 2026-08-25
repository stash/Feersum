package Plack::Handler::Feersum;
use warnings;
use strict;
use Feersum::Runner;
use base 'Feersum::Runner';

sub assign_request_handler {
    my $self = shift;
    # no TERM watcher here: run() installs one right after this returns
    $self->{endjinn}->psgi_request_handler(shift);
    return;
}

sub _prepare {
    my $self = shift;
    $self->SUPER::_prepare(@_);
    $self->{server_ready}->($self)
        if $self->{server_ready};
    return;
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

Always use the C<--key=value> form for these options.  plackup turns a
valueless C<--flag> into C<< flag => <next argument> >>, so a bare C<--reuseport>
silently swallows the option that follows it (or the app filename).

A C<--pre-fork=N> parameter puts feersum into pre-forked mode with N child
processes.  C<--preload-app=0> is B<not> usable through plackup: plackup
compiles the app before the fork, so Feersum croaks with
C<preload_app =E<gt> 0 requires app_file>.  Adding C<--app-file> only silences
the croak: the workers still share the precompiled app.  For a per-worker
load, drive L<Feersum::Runner> directly with C<app_file> and no C<app>.

A C<--reuseport=1> parameter can be specified to enable SO_REUSEPORT support
for better multi-core scaling when combined with C<--pre-fork>. Requires
Linux 3.9+ or similar kernel support.

Watcher priority options C<--read-priority>, C<--write-priority>, and
C<--accept-priority> can be used to set libev I/O watcher priorities.
Valid range is -2 (lowest) to +2 (highest), default is 0.

TLS, HTTP/2, and PROXY protocol can be configured via plackup's
pass-through server options (use the C<--key=value> form so a flag's value
is not mistaken for the app filename):

    plackup -s Feersum \
      --tls-cert-file=server.crt --tls-key-file=server.key \
      --h2=1 --proxy-protocol=1 app.psgi

B<Note:> The C<sni> option (for virtual hosting with multiple TLS
certificates) takes an array of hashes and cannot be set on the command
line; use L<Feersum::Runner> directly for SNI configuration.

A C<server_ready> callback (a code reference, so only settable when the
handler is constructed programmatically, e.g. via L<Plack::Loader>) is
invoked once the listening sockets are bound; it receives the handler object
as its only argument.  With C<daemonize> it fires in the foreground process
before daemonization, and it is not invoked at all under C<hot_restart>
(generations bind their sockets outside the code path that calls it).

See L<Feersum::Runner> for full documentation of these options.

=head1 METHODS

=over 4

=item C<< assign_request_handler($app) >>

Assigns the PSGI request handler to Feersum.

SIGTERM is handled by C<< Feersum::Runner::run() >>, which calls C<quit()>, so
L<Plack::Loader::Restarter> works.

=back

=head1 SEE ALSO

Most of the functionality is in L<Feersum::Runner> (the base class)

=head1 AUTHOR

Jeremy Stashewsky, C<< stash@cpan.org >>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Jeremy Stashewsky & Socialtext Inc.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.14 or,
at your option, any later version of Perl 5 you may have available.

=cut
