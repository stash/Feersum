package Utils;
use strict;
use base 'Exporter';
use Test::More ();
use IO::Socket::INET;
use bytes; no bytes;
use blib;
use Carp qw(carp cluck confess croak);
use Encode ();
use AnyEvent ();
use AnyEvent::Handle ();
use Guard ();
use Scalar::Util qw/blessed weaken/;
use utf8;

$SIG{__DIE__} = \&Carp::confess;
$SIG{PIPE} = 'IGNORE';

my $CRLF = "\015\012";

sub import {
    my ($pkg) = caller;
    no strict 'refs';
    *{$pkg.'::carp'} = \&Carp::carp;
    *{$pkg.'::cluck'} = \&Carp::cluck;
    *{$pkg.'::confess'} = \&Carp::confess;
    *{$pkg.'::croak'} = \&Carp::croak;
    *{$pkg.'::guard'} = \&Guard::guard;
    *{$pkg.'::scope_guard'} = \&Guard::scope_guard;
    *{$pkg.'::weaken'} = \&Scalar::Util::weaken;
    *{$pkg.'::blessed'} = \&Scalar::Util::blessed;
    *{$pkg.'::get_listen_socket'} = \&get_listen_socket;
    *{$pkg.'::simple_client'} = \&simple_client;

    return 1;
}

our $last_port;
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
            $last_port = $i;
            return $socket unless wantarray;
            return ($socket,$i);
        }
    }
}

sub _cb_ewrapper {
    my ($code, $name) = @_;
    return(sub {}) unless $code;
    return sub {
        eval { $code->(@_) };
        if ($@) {
            Test::More::fail "$name callback failed";
            Test::More::diag $@
        }
    };
}

sub simple_client ($$;@) {
    my $done_cb = pop;
    my $method = shift;
    my $uri = shift;
    my %opts = @_;

    my $name = delete $opts{name} || 'simple_client';
    my $port = delete $opts{port} || $last_port;

    $done_cb = _cb_ewrapper($done_cb, "$name done");
    my $conn_cb = _cb_ewrapper(delete $opts{on_connect}, "$name connect");
    my $buf = '';
    my %hdrs;
    my $err_cb = sub {
        my ($h,$fatal,$msg) = @_;
        $hdrs{Status} = 599;
        $hdrs{Reason} = $msg;
        $h->destroy;
        $done_cb->(undef,\%hdrs);
    };

    require AnyEvent::Handle;
    my $h; $h = AnyEvent::Handle->new(
        connect => ['127.0.0.1',$port],
        on_connect => sub {
            my $h = shift;
            Test::More::pass("$name connected");
            $conn_cb->($h);
            return;
        },
        on_error => $err_cb,
        timeout => $opts{timeout} || 30,
    );
    my $strong_h = $h;
    weaken($h);

    my $done = sub { $done_cb->($buf,\%hdrs); $h->destroy if $h; };

    $h->on_read(sub {
        Test::More::fail "$name got extra bytes!";
    });
    $h->push_read(line => "$CRLF$CRLF", sub {
        {
            my @hdrs = split($CRLF, $_[1]);
            my $status_line = shift @hdrs;
            %hdrs = map {
                my ($k,$v) = split(/:\s+/,$_);
                (lc($k),$v);
            } @hdrs;
            # $hdrs{OrigHead} = $head;
            if ($status_line =~ m{HTTP/(1.\d) (\d{3}) +(.+)\s*}) {
                $hdrs{HTTPVersion} = $1;
                $hdrs{Status} = $2;
                $hdrs{Reason} = $3;
            }
        }

        $hdrs{'content-length'} = 0 if ($hdrs{Status} == 204);

        if ($hdrs{Status} == 304) {
            # should have no body
            $h->on_read(sub {
                $buf .= substr($_[0]->{rbuf},0,length($_[0]->{rbuf}),'');
            });
            $h->on_eof($done);
        }
        elsif (exists $hdrs{'content-length'}) {
            return $done->() unless ($hdrs{'content-length'});
#             Test::More::diag "$name waiting for C-L body";
            $h->push_read(chunk => $hdrs{'content-length'}, sub {
                $buf = $_[1];
                return $done->();
            });
        }
        elsif (($hdrs{'transfer-encoding'}||'') eq 'chunked') {
#             Test::More::diag "$name waiting for T-E:chunked body";
            my $len = 0;
            my ($chunk_reader, $chunk_handler);
            $chunk_handler = sub {
                if ($len == 0) {
                    undef $chunk_reader;
                    undef $chunk_handler;
                    return $done->();
                }
                # remove CRLF at end of chunk:
                $buf .= substr($_[1],0,-2);
                $h->push_read(line => $CRLF, $chunk_reader);
            };
            $chunk_reader = sub {
                my $hex = $_[1];
                $len = hex $hex;
                if (!defined($len)) {
                    $err_cb->($h,0,"invalid chunk length '$hex'");
                    undef $chunk_reader;
                    undef $chunk_handler;
                    return;
                }
                else {
                    # add two for after-chunk CRLF
                    $h->push_read(chunk => $len+2, $chunk_handler);
                }
            };
            $h->push_read(line => $CRLF, $chunk_reader);
        }
        elsif ($hdrs{HTTPVersion} eq '1.0' or
               ($hdrs{connection}||'') eq 'close')
        {
#             Test::More::diag "$name waiting for conn:close body";
            $h->on_read(sub {
                $buf .= substr($_[0]->{rbuf},0,length($_[0]->{rbuf}),'');
            });
            $h->on_eof($done);
        }
        else {
            $err_cb->($h,0,
                "got a response that I don't know how to handle the body for");
            return;
        }
    });

    my $host = 'localhost'; #delete $opts{host}
    my $headers = delete $opts{headers};
    my $proto = delete $opts{proto} || '1.1';
    my $body = delete $opts{body} || '';

    $headers->{'User-Agent'} ||= 'FeersumSimpleClient/1.0';
    $headers->{'Host'} ||= $host.':'.$port;
    if (length($body)) {
        $headers->{'Content-Length'} ||= length($body);
        $headers->{'Content-Type'} ||= 'text/plain';
    }

    # HTTP/1.1 default is 'keep-alive'
    $headers->{'Connection'} ||= 'close';

    my $head = join($CRLF, map {$_.': '.$headers->{$_}} sort keys %$headers);

    my $http_req = "$method $uri HTTP/$proto$CRLF";
    $strong_h->push_write($http_req);

    $strong_h->push_write($head.$CRLF.$CRLF.$body)
        unless $opts{skip_head};

#     $http_req =~ s/$CRLF/<CRLF>\n/sg;
#     Test::More::diag($http_req);
    
    return $strong_h;
}

1;
