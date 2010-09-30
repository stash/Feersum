#!perl
use warnings;
use strict;
use Test::More tests => 33;
use lib 't'; use Utils;
use File::Temp qw/tempfile/;
use Encode qw/decode_utf8/;

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

{
    package FakeIOHandle;
    sub new { return bless {lines => $_[1]}, __PACKAGE__ }
    sub getline {
        my $self = shift;
        Test::More::ok(ref($/) && ${$/} == 4096, '$/ is \4096');
        return shift @{$self->{lines}};
    }
    sub close {}
}

my $APP = <<'EOAPP';
    my $app = sub {
        my $env = shift;
        Test::More::pass "called app";
        my $io = FakeIOHandle->new([
            "line one\n",
            "line two\n"
        ]);
        return [200,['Content-Type'=>'text/plain'],$io];
    };
EOAPP

my $app = eval $APP;
ok $app, 'got an app' || diag $@;
$evh->psgi_request_handler($app);

returning_mock: {
    my $cv = AE::cv;

    $cv->begin;
    my $h; $h = simple_client GET => '/', sub {
        my ($body, $headers) = @_;
        is $headers->{'Status'}, 200, "Response OK";
        is $headers->{'content-type'}, 'text/plain';
        is $body, qq(line one\nline two\n);
        $cv->end;
        undef $h;
    };

    $cv->recv;
    pass "all done app 1";
}

my ($tempfh, $tempname) = tempfile(UNLINK=>1);
print $tempfh "temp line one\n";
print $tempfh "temp line two\n";
close $tempfh;

my $APP2 = <<'EOAPP';
    my $app2 = sub {
        my $env = shift;
        Test::More::pass "called app2";
        open my $io, '<', $tempname;
        return [200,['Content-Type'=>'text/plain'],$io];
    };
EOAPP

my $app2 = eval $APP2;
ok $app2, 'got app 2' || diag $@;
$evh->psgi_request_handler($app2);

returning_glob: {
    my $cv = AE::cv;
    $cv->begin;
    my $h; $h = simple_client GET => '/', sub {
        my ($body, $headers) = @_;
        is $headers->{'Status'}, 200, "Response OK";
        is $headers->{'content-type'}, 'text/plain';
        is $body, qq(temp line one\ntemp line two\n);
        $cv->end;
        undef $h;
    };
    $cv->recv;
}

pass "all done app 2";

my $APP3 = <<'EOAPP';
    my $app3 = sub {
        my $env = shift;
        Test::More::pass "called app3";
        require IO::File;
        my $io = IO::File->new($tempname,"r");
        return [200,['Content-Type'=>'text/plain'],$io];
    };
EOAPP

my $app3 = eval $APP3;
ok $app3, 'got app 3' || diag $@;
$evh->psgi_request_handler($app3);

returning_io_file: {
    my $cv = AE::cv;
    $cv->begin;
    my $h; $h = simple_client GET => '/', sub {
        my ($body, $headers) = @_;
        is $headers->{'Status'}, 200, "Response OK";
        is $headers->{'content-type'}, 'text/plain', "C-T";
        is $body, qq(temp line one\ntemp line two\n), "body";
        $cv->end;
        undef $h;
    };
    $cv->recv;
}

pass "all done app 3";

{
    open my $fh, '>:encoding(UTF-16LE)',$tempname;
    print $fh "\x{2603}\n"; # U+2603 SNOWMAN, UTF-8: E2 98 83
    close $fh;
}

my $APP4 = <<'EOAPP';
    my $app4 = sub {
        my $env = shift;
        Test::More::pass "called app4";
        open my $io, '<:encoding(UTF-16LE)',$tempname;
        return [200,['Content-Type'=>'text/plain; charset=UTF-8'],$io];
    };
EOAPP

my $app4 = eval $APP4;
ok $app4, 'got app 4' || diag $@;
$evh->psgi_request_handler($app4);

returning_perlio_layer: {
    my $cv = AE::cv;
    $cv->begin;
    my $h; $h = simple_client GET => '/', sub {
        my ($body, $headers) = @_;
        is $headers->{'Status'}, 200, "Response OK";
        is $headers->{'content-type'}, 'text/plain; charset=UTF-8', "C-T";
        is decode_utf8($body), qq(\x{2603}\n), "utf8 body";
        $cv->end;
        undef $h;
    };
    $cv->recv;
}

pass "all done app 4";
