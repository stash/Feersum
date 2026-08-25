
use strict;
use warnings;
use Test::More;
use lib 't'; use Utils;
use Feersum;
use AnyEvent;

my ($socket, $port) = get_listen_socket();
ok $socket, "made listen socket";

subtest 'max_uri_len configuration' => sub {
    my $f = Feersum->new();
    is $f->max_uri_len(), 8192, 'default max_uri_len is 8192';
    
    $f->max_uri_len(1024);
    is $f->max_uri_len(), 1024, 'max_uri_len can be set to 1024';
    
    $f->max_uri_len(0);
    is $f->max_uri_len(), 8192, 'setting max_uri_len to 0 resets to default';
};

subtest 'max_uri_len enforcement' => sub {
    my $f = Feersum->new();
    $f->use_socket($socket);
    $f->request_handler(sub {
        my $req = shift;
        eval {
            $req->send_response(200, ['Content-Type' => 'text/plain'], ["OK"]);
        };
        if ($@) {
            diag "Request handler failed: $@";
            die $@;
        }
    });
    
    $f->max_uri_len(64); # small limit
    
    my $cv = AnyEvent->condvar;
    my $long_path = "/" . ("x" x 100);
    
    my $w = simple_client GET => $long_path, sub {
        my ($body, $hdr) = @_;
        is $hdr->{Status}, 414, 'request with long URI rejected with 414';
        $cv->send;
    };
    $cv->recv;
    
    # Now set it larger and try again
    $f->max_uri_len(200);
    
    my $cv2 = AnyEvent->condvar;
    my $w2 = simple_client GET => $long_path, sub {
        my ($body, $hdr) = @_;
        is $hdr->{Status}, 200, 'request with previously long URI accepted after increasing limit';
        is $body, "OK", "got correct body";
        $cv2->send;
    };
    $cv2->recv;
};

# Negative values must croak, not wrap to a huge unsigned limit
subtest 'max_uri_len validation' => sub {
    my $f = Feersum->new();
    my $before = $f->max_uri_len;
    eval { $f->max_uri_len(-1) };
    like $@, qr/max_uri_len must be non-negative/, 'negative max_uri_len croaks';
    is $f->max_uri_len, $before, 'max_uri_len unchanged after rejected set';
};

done_testing;
