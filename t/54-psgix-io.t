#!perl
use warnings;
use strict;
use constant CLIENTS => 10;
use constant ROUNDS => 4;
use Test::More tests => 3 + ROUNDS*(
    CLIENTS*3 + # server setup
    CLIENTS*3 + # client setup
    CLIENTS + # server msg
    CLIENTS + # client send
    CLIENTS*CLIENTS + # client msg
    4 # round
);
use lib 't'; use Utils;

BEGIN { use_ok('Feersum') };

my ($socket,$port) = get_listen_socket();
ok $socket, "made listen socket";

my $evh = Feersum->new();
{
    no warnings 'redefine';
    *Feersum::DIED = sub {
        my $err = shift;
        fail "Died during request handler: $err";
    };
}
$evh->use_socket($socket);

our $CRLF = "\015\012";
my $app = sub {
    my $env = shift;
    is $env->{HTTP_UPGRADE}, 'chatz', "server setup: got an upgrade req";
    my $n = $env->{HTTP_X_CLIENT};
    if ($n % 2) {
        # test psgi.streaming
        return sub {
            my $respond = shift;
            do_chat($n,$env);
        };
    }
    else {
        # test traditional responses (result should be ignored)
        do_chat($n,$env);
        return [];
    }
};
$evh->psgi_request_handler($app);

my $cv;

# read lines, broadcast to other server-side handles
my @ss_handles;
sub do_chat {
    my ($n, $env) = @_;
    $cv->begin;
    my $fh = $env->{'psgix.io'};
    isa_ok $fh, 'IO::Socket', "server setup: $n fh";

    # use AnyEvent::Handle here specifically as that's what Web::Hippie
    # uses.
    my $h = AnyEvent::Handle->new(fh => $fh);
    $ss_handles[$n] = $h;
    $h->{guard} = guard { pass "server setup: $n destroyed" };
    $h->push_write("HTTP/1.1 101 Switching Protocols$CRLF$CRLF");
    $h->push_read(line => sub {
        my $line = $_[1];
        is $line, "hello from $n", "server msg: read a line for server $n";
        $line .= "\n";
        $ss_handles[$_]->push_write($line) for (1..CLIENTS);
        $cv->end;
    });
    $h->on_error(sub {
        diag "server handle error: $_[2]";
        $h->destroy; # important self-ref
        $cv->croak("server handle: ".$_[2]);
    });
}

for my $round (1..ROUNDS) {
    $cv = AE::cv;

    # connect a number of clients, keeping the handle in a client-side handles
    # array.  Once all of the clients are connected ($connect_cv synchronizes
    # them) send a "hello from" line for each client.  Check that every client
    # gets every message.
    my @cs_handles;
    my $connect_cv = AE::cv(sub {
        pass "round $round : all clients connected, sending chats...";
        eval {
            for my $n (1 .. CLIENTS) {
                my $h = $cs_handles[$n];
                $h->push_write("hello from $n\n");
                pass "client send: wrote to $n";
            }
        };
        warn "during connect cv: $@" if $@;
    });

    $connect_cv->begin;
    for my $n (1 .. CLIENTS) {
        $connect_cv->begin;
        $cv->begin;
        my $h = AnyEvent::Handle->new(
            connect => ['127.0.0.1',$port],
            timeout => 3,
        );
        $cs_handles[$n] = $h;
        $h->{guard} = guard { pass "client setup: $n destroyed" };

        $h->on_error(sub {
            diag "client handle error: $_[2]";
            $h->destroy;
            $connect_cv->croak("client handle: ".$_[2]);
            $cv->croak("client handle: ".$_[2]);
        });

        $h->push_write("GET / HTTP/1.1$CRLF".
            "Upgrade: chatz$CRLF".
            "X-Client: $n$CRLF".
            $CRLF
        );

        # one line for the upgrade, CLIENTS lines for the chatting
        $h->push_read(line => qr/$CRLF$CRLF/, sub {
            my $line = $_[1];
            is $line, 'HTTP/1.1 101 Switching Protocols',
                "client setup: client $n got upgraded";
            $connect_cv->end;
        });
        my $to_read = CLIENTS;
        $h->push_read(line => sub {
            my $line = $_[1];
            $to_read--;
            like $line, qr/^hello from \d+$/,
                "client msg: $n got a chat, $to_read left";
            unless ($to_read) {
                pass "client setup: client $n is done";
                $cv->end;
            }
        }) for (1 .. CLIENTS);
    }
    $connect_cv->end;

    $connect_cv->recv;
    pass "round: all connected";
    $cv->recv;
    pass "round: done round $round";
    $_->destroy() for grep {defined} @cs_handles;
    @cs_handles = ();
    $_->destroy() for grep {defined} @ss_handles;
    @ss_handles = ();
    pass "round: cleaned up round $round";
}

pass "all done";
done_testing;
