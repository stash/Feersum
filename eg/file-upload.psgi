#!/usr/bin/env perl
# File upload example using PSGI streaming input.
#
# Usage:
#   plackup -s Feersum eg/file-upload.psgi
#   curl -F 'file=@somefile.txt' http://localhost:5000/upload
#
use strict;
use warnings;

my $app = sub {
    my $env = shift;

    if ($env->{REQUEST_METHOD} eq 'POST' && $env->{PATH_INFO} eq '/upload') {
        my $cl   = $env->{CONTENT_LENGTH} || 0;
        my $type = $env->{CONTENT_TYPE}   || '';
        my $input = $env->{'psgi.input'};

        # Read the full body
        my $body = '';
        my $remaining = $cl;
        while ($remaining > 0) {
            my $n = $input->read(my $buf, $remaining > 8192 ? 8192 : $remaining);
            last unless $n;
            $body .= $buf;
            $remaining -= $n;
        }

        my $size = length($body);
        my $resp = "Received $size bytes (Content-Type: $type)\n";
        return [200, ['Content-Type' => 'text/plain'], [$resp]];
    }

    # Upload form
    if ($env->{PATH_INFO} eq '/' || $env->{PATH_INFO} eq '') {
        my $html = <<'HTML';
<!DOCTYPE html>
<html>
<body>
<h2>File Upload</h2>
<form method="POST" action="/upload" enctype="multipart/form-data">
  <input type="file" name="file"><br><br>
  <button type="submit">Upload</button>
</form>
</body>
</html>
HTML
        return [200, ['Content-Type' => 'text/html'], [$html]];
    }

    [404, ['Content-Type' => 'text/plain'], ['Not Found']];
};
