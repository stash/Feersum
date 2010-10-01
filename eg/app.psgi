#!perl
#
# Compare and contrast to app.feersum
#
my $counter = 0;
sub {
    my $env = shift;
    my $n = $counter++;
    return [200, [
        'Content-Type' => 'text/plain',
        'Connection' => 'close',
    ], ["Hello customer number 0x",sprintf('%08x',$n),"\n"]];
};
