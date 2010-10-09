#!perl
use strict;
use Test::More;
use blib;
use lib 't'; use Utils;
BEGIN {
    $ENV{PLACK_TEST_IMPL} = 'Server';
    $ENV{PLACK_SERVER} = 'Feersum';
    $ENV{PLACK_ENV} = 'deployment';

    plan skip_all => "Need Plack >= 0.9950 to run this test"
        unless eval 'require Plack; $Plack::VERSION >= 0.995';
}

plan tests => 6;

use Plack::Test;
use Plack::Test;
use Plack::Builder;
use Plack::App::File;
use Plack::App::Cascade;
use Plack::Request;
use Test::TCP;

via_map: test_psgi(
    app => builder {
        mount '/' => Plack::App::File->new(root => 't');
    },
    client => sub {
        my $cb = shift;
        my $req = HTTP::Request->new(GET =>
            "http://localhost/63-plack-apps.t");
        my $res = $cb->($req);
        my $s = "# IS THIS FILE"." STATICALLY SERVED?";
        is $res->code, 200;
        like $res->content, qr/^\Q$s\E$/m, "found static line";
    }
);

cascaded: test_psgi(
    app => builder {
        mount '/' => Plack::App::Cascade->new(apps => [
            Plack::App::File->new(root => 'notfound')->to_app,
            Plack::App::File->new(root => 'me-neither')->to_app,
            Plack::App::File->new(root => 't')->to_app,
        ]);
    },
    client => sub {
        my $cb = shift;
        my $req = HTTP::Request->new(GET =>
            "http://localhost/63-plack-apps.t");
        my $res = $cb->($req);
        my $s = "# IS THIS FILE"." STATICALLY SERVED?";
        is $res->code, 200;
        like $res->content, qr/^\Q$s\E$/m, "found static line (cascade)";
    }
);

via_redirect: test_psgi(
    app => builder {
        mount '/static' => Plack::App::Cascade->new(apps => [
            Plack::App::File->new(root => 'notfound')->to_app,
            Plack::App::File->new(root => 't')->to_app,
        ]);
        mount '/' => sub {
            my $env = shift;
            my $req = Plack::Request->new($env);
            my $res = $req->new_response(200);
            if ($req->path eq '/') {
                $res->redirect('/static/63-plack-apps.t');
            }
            else {
                $res->code(404);
            }
            $res->finalize;
        };
    },
    client => sub {
        my $cb = shift;
        my $req = HTTP::Request->new(GET =>
            "http://localhost/");
        my $res = $cb->($req);
        my $s = "# IS THIS FILE"." STATICALLY SERVED?";
        is $res->code, 200;
        like $res->content, qr/^\Q$s\E$/m, "found static line (cascade)";
    }
);

__END__
# IS THIS FILE STATICALLY SERVED?
