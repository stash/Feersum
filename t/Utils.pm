package Utils;
use strict;
use base 'Exporter';
use IO::Socket::INET;
use bytes; no bytes;
use blib;
use Carp qw(carp cluck confess croak);
use Encode ();
use AnyEvent ();
use AnyEvent::Handle ();
use AnyEvent::HTTP ();
use Guard ();
use utf8;

$SIG{__DIE__} = \&Carp::confess;
$SIG{PIPE} = 'IGNORE';

sub import {
    my ($pkg) = caller;
    no strict 'refs';
    *{$pkg.'::get_listen_socket'} = \&get_listen_socket;
    *{$pkg.'::http_get'} = \&AnyEvent::HTTP::http_get;
    *{$pkg.'::http_post'} = \&AnyEvent::HTTP::http_post;
    *{$pkg.'::http_request'} = \&AnyEvent::HTTP::http_request;
    *{$pkg.'::carp'} = \&Carp::carp;
    *{$pkg.'::cluck'} = \&Carp::cluck;
    *{$pkg.'::confess'} = \&Carp::confess;
    *{$pkg.'::croak'} = \&Carp::croak;
    *{$pkg.'::guard'} = \&Guard::guard;
    *{$pkg.'::scope_guard'} = \&Guard::scope_guard;

    return 1;
}

sub get_listen_socket {
    my $start = shift || 10000;
    my $max = shift || $start + 10000;
    for (my $i=$start; $i <= $max; $i++) {
        my $socket = IO::Socket::INET->new(
            LocalAddr => "localhost:$i",
            ReuseAddr => 1,
            Proto => 'tcp',
            Listen => 1024,
            Blocking => 0,
        );
        if ($socket) {
            return $socket unless wantarray;
            return ($socket,$i);
        }
    }
}

1;
