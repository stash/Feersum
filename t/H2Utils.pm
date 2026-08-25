package H2Utils;
# Shared H2 frame helpers for Feersum test suite.
# Used by t/44, t/46, t/47, t/48, xt/60, xt/61, xt/62.
use strict;
use warnings;

# Sub-second time(): the deadline arithmetic below is all fractional, and with
# the core whole-second time() a 0.2s read budget resolved to anywhere between
# ~0 and ~1 second.
use Time::HiRes qw(time);

use Exporter 'import';

our @EXPORT = qw(
    H2_DATA H2_HEADERS H2_RST_STREAM H2_SETTINGS H2_PING H2_GOAWAY H2_WINDOW_UPDATE
    FLAG_END_STREAM FLAG_END_HEADERS FLAG_ACK
    SETTINGS_ENABLE_CONNECT_PROTOCOL
    h2_frame h2_client_preface h2_read_frame h2_read_until
    hpack_encode_headers hpack_encode_string encode_varint
    hpack_decode_status hpack_decode_string
    h2_connect h2_handshake h2_fork_test
);

use constant {
    H2_DATA          => 0x00,
    H2_HEADERS       => 0x01,
    H2_RST_STREAM    => 0x03,
    H2_SETTINGS      => 0x04,
    H2_PING          => 0x06,
    H2_GOAWAY        => 0x07,
    H2_WINDOW_UPDATE => 0x08,

    FLAG_END_STREAM  => 0x01,
    FLAG_END_HEADERS => 0x04,
    FLAG_ACK         => 0x01,

    SETTINGS_ENABLE_CONNECT_PROTOCOL => 0x08,
};

# Scale the helpers' default per-operation timeouts on slow CI smokers.
# h2_fork_test already scales its outer watchdog via timeout_mult; this
# covers the inner read/connect/handshake helpers a child calls during
# the exchange (a TLS+H2 handshake can exceed a flat 5s on loaded VMs).
use constant TIMEOUT_MULT =>
    $ENV{PERL_TEST_TIME_OUT_FACTOR} || ($ENV{AUTOMATED_TESTING} ? 4 : 1);

sub h2_frame {
    my ($type, $flags, $stream_id, $payload) = @_;
    $payload //= '';
    my $len = length $payload;
    return pack('CnCCN', ($len >> 16) & 0xFF, $len & 0xFFFF,
                $type, $flags, $stream_id & 0x7FFFFFFF) . $payload;
}

sub h2_client_preface {
    return "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
         . h2_frame(H2_SETTINGS, 0, 0, '');
}

# Accumulate exactly $want bytes from a non-blocking socket, polling until
# the deadline. Returns the bytes read; a short return (length < $want)
# means EOF or deadline. Caller decides whether a short read is fatal.
sub _read_n {
    my ($sock, $want, $deadline) = @_;
    my $buf = '';
    while (length($buf) < $want && time < $deadline) {
        my $n = $sock->sysread(my $chunk, $want - length($buf));
        if    (defined $n && $n > 0)  { $buf .= $chunk; }
        elsif (defined $n && $n == 0) { last; }  # EOF
        else                          { select(undef, undef, undef, 0.01); }
    }
    return $buf;
}

# A frame still in flight must never come back looking complete.  _read_n stops
# at the deadline and returns what it has, so a frame split across the timeout
# used to yield a short payload with no error, and the leftover bytes were then
# parsed as the next frame header - desynchronising the connection silently.
# The caller's timeout decides whether a frame STARTS; once one has, finish it
# against a generous deadline and die rather than hand back a truncated frame.
use constant FRAME_FINISH_TIMEOUT => 10 * TIMEOUT_MULT;

sub h2_read_frame {
    my ($sock, $timeout) = @_;
    $timeout //= 5 * TIMEOUT_MULT;

    my $hdr = _read_n($sock, 9, time + $timeout);
    return undef if length($hdr) == 0;   # nothing arrived: a clean miss
    if (length($hdr) < 9) {
        $hdr .= _read_n($sock, 9 - length($hdr), time + FRAME_FINISH_TIMEOUT);
        die sprintf "h2_read_frame: truncated frame header, %d of 9 bytes\n",
            length $hdr if length($hdr) < 9;
    }

    my ($len_hi, $len_lo, $type, $flags, $stream_id) = unpack('CnCCN', $hdr);
    my $len = ($len_hi << 16) | $len_lo;
    $stream_id &= 0x7FFFFFFF;

    my $payload = $len ? _read_n($sock, $len, time + FRAME_FINISH_TIMEOUT) : '';
    die sprintf "h2_read_frame: truncated payload, %d of %d bytes "
              . "(type=%d stream=%d)\n", length($payload), $len, $type, $stream_id
        if length($payload) < $len;

    return { type => $type, flags => $flags, stream_id => $stream_id,
             payload => $payload, length => $len };
}

sub h2_read_until {
    my ($sock, $type, $stream_id, $timeout) = @_;
    $timeout //= 5 * TIMEOUT_MULT;
    my $deadline = time + $timeout;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        return undef unless $f;
        return $f if $f->{type} == $type
                  && (!defined $stream_id || $f->{stream_id} == $stream_id);
    }
    return undef;
}

# --- HPACK encoding (literals without indexing) ---

sub hpack_encode_headers {
    my (@pairs) = @_;
    my $out = '';
    for my $pair (@pairs) {
        my ($name, $value) = @$pair;
        $out .= chr(0x00) . hpack_encode_string($name) . hpack_encode_string($value);
    }
    return $out;
}

sub hpack_encode_string {
    my ($s) = @_;
    my $len = length $s;
    if ($len < 127) { return pack('C', $len) . $s; }
    return pack('C', 127) . encode_varint($len - 127) . $s;
}

sub encode_varint {
    my ($i) = @_;
    my $out = '';
    while ($i >= 128) { $out .= pack('C', ($i & 0x7F) | 0x80); $i >>= 7; }
    $out .= pack('C', $i);
    return $out;
}

# --- HPACK decoding (minimal, for status codes and literal headers) ---

# Advance $pos past the continuation bytes of an HPACK multi-byte integer
# (RFC 7541 5.1: bytes with the high bit set continue the value).
sub _skip_hpack_varint {
    my ($payload, $pos) = @_;
    while ($pos < length $payload) {
        last unless ord(substr($payload, $pos++, 1)) & 0x80;
    }
    return $pos;
}

sub hpack_decode_status {
    my ($payload) = @_;
    my $pos = 0;
    while ($pos < length $payload) {
        my $byte = ord(substr($payload, $pos, 1));
        $pos++;
        if ($byte & 0x80) {
            # Indexed header field (static or dynamic table)
            my $idx = $byte & 0x7F;
            $pos = _skip_hpack_varint($payload, $pos) if $idx == 127;
            return '200' if $idx == 8;
            return '204' if $idx == 9;
            return '206' if $idx == 10;
            return '304' if $idx == 11;
            return '400' if $idx == 12;
            return '404' if $idx == 13;
            return '500' if $idx == 14;
            # Dynamic table ref - can't decode without state, skip
        } elsif (($byte & 0xE0) == 0x20) {
            # Dynamic Table Size Update (RFC 7541 section 6.3): 001xxxxx
            my $sz = $byte & 0x1F;
            $pos = _skip_hpack_varint($payload, $pos) if $sz == 31;
            next;
        } else {
            # Literal header: 0x00-0x0F (no indexing), 0x10-0x1F (never indexed),
            # 0x40-0x7F (incremental indexing)
            my $name_idx;
            if (($byte & 0xC0) == 0x40) {
                $name_idx = $byte & 0x3F;
            } elsif (($byte & 0xF0) == 0x00) {
                $name_idx = $byte & 0x0F;
            } elsif (($byte & 0xF0) == 0x10) {
                $name_idx = $byte & 0x0F;
            } else {
                last; # unknown encoding
            }
            my ($name, $value);
            if ($name_idx == 0) {
                ($name, $pos) = hpack_decode_string($payload, $pos);
            } else {
                $name = $name_idx == 8 ? ':status' : "idx:$name_idx";
            }
            ($value, $pos) = hpack_decode_string($payload, $pos);
            return $value if defined $name && $name eq ':status';
        }
    }
    return undef;
}

sub hpack_decode_string {
    my ($buf, $pos) = @_;
    my $byte = ord(substr($buf, $pos, 1));
    $pos++;
    my $is_huffman = $byte & 0x80;
    my $len = $byte & 0x7F;
    if ($len == 127) {
        my $m = 0;
        while ($pos < length $buf) {
            my $b = ord(substr($buf, $pos, 1));
            $pos++;
            $len += ($b & 0x7F) << $m;
            $m += 7;
            last unless ($b & 0x80);
        }
    }
    my $raw = substr($buf, $pos, $len);
    if ($is_huffman) {
        my $decoded = _hpack_huffman_decode_digits($raw);
        $raw = $decoded if defined $decoded;
    }
    return ($raw, $pos + $len);
}

# Decode Huffman-encoded digit-only strings (status codes).
# HPACK Huffman codes (RFC 7541 App B):
#   '0'-'2' = 5-bit codes 00000-00010
#   '3'-'9' = 6-bit codes 011001-011111
sub _hpack_huffman_decode_digits {
    my ($data) = @_;
    my $bits = unpack('B*', $data);
    my $blen = length $bits;
    my $pos = 0;
    my $result = '';
    while ($pos < $blen) {
        if ($blen - $pos >= 5) {
            my $c5 = oct('0b' . substr($bits, $pos, 5));
            if ($c5 <= 2) { $result .= $c5; $pos += 5; next; }
        }
        if ($blen - $pos >= 6) {
            my $c6 = oct('0b' . substr($bits, $pos, 6));
            if ($c6 >= 0x19 && $c6 <= 0x1F) {
                $result .= chr(ord('3') + $c6 - 0x19);
                $pos += 6;
                next;
            }
        }
        last;
    }
    # Remaining bits must be all-1 EOS padding (RFC 7541 5.2)
    if ($pos < $blen) {
        my $tail = substr($bits, $pos);
        return undef unless $tail =~ /^1+$/;
    }
    return length($result) > 0 ? $result : undef;
}

# --- H2 connection setup ---

# Connect to server with TLS + H2 ALPN, perform H2 handshake.
# Returns ($sock, $settings_payload) in list context, $sock in scalar context.
sub h2_connect {
    my ($port, %opts) = @_;
    my $timeout = $opts{timeout} || 5 * TIMEOUT_MULT;

    require IO::Socket::SSL;
    my $sock = IO::Socket::SSL->new(
        PeerAddr           => '127.0.0.1',
        PeerPort           => $port,
        SSL_verify_mode    => IO::Socket::SSL::SSL_VERIFY_NONE(),
        SSL_alpn_protocols => ['h2'],
        Timeout            => $timeout,
    );
    return () unless $sock;

    my $settings_payload = h2_handshake($sock, timeout => $timeout);

    return wantarray ? ($sock, $settings_payload) : $sock;
}

# Perform H2 handshake on an already-connected SSL socket.
# Sends client preface, exchanges SETTINGS, drains init frames.
# Use this when the socket was established manually (e.g. after PROXY header).
sub h2_handshake {
    my ($sock, %opts) = @_;
    my $timeout = $opts{timeout} || 5 * TIMEOUT_MULT;

    $sock->syswrite(h2_client_preface());
    $sock->blocking(0);

    my $settings_payload;
    my $deadline = time + $timeout;
    while (time < $deadline) {
        my $f = h2_read_frame($sock, $deadline - time);
        last unless $f;
        if ($f->{type} == H2_SETTINGS && !($f->{flags} & FLAG_ACK)) {
            $settings_payload = $f->{payload};
            $sock->syswrite(h2_frame(H2_SETTINGS, FLAG_ACK, 0, ''));
            last;
        }
    }
    for (1..5) {
        my $f = h2_read_frame($sock, 0.2);
        last unless $f;
    }

    return $settings_payload;
}

# Fork a child that performs H2 client work, run event loop in parent.
# Emits 2 TAP tests ("did not hang" + "child succeeded").
# $child_code->($port) should exit(0) on success, non-zero on failure.
# Options: timeout => N (default 10), delay => N (default 0.3).
sub h2_fork_test {
    my ($label, $port, $child_code, %opts) = @_;
    # Default to the module's TIMEOUT_MULT, not 1: most callers pass no
    # timeout_mult, which gave the parent a flat 10s watchdog while the child
    # legitimately had up to 4x that under AUTOMATED_TESTING - producing
    # spurious 'did not hang' failures with no diagnostic.
    my $tmult = $opts{timeout_mult} || TIMEOUT_MULT;
    my $timeout = ($opts{timeout} || 10) * $tmult;
    my $delay = ($opts{delay} || 0.3) * $tmult;

    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if ($pid == 0) {
        select(undef, undef, undef, $delay);
        $child_code->($port);
        exit(255); # should not reach here
    }

    my $cv = AE::cv;
    my $child_status;
    my $t = AE::timer($timeout, 0, sub {
        Test::More::diag("timeout: $label");
        kill 'QUIT', $pid;
        $cv->send('timeout');
    });
    my $cw = AE::child($pid, sub {
        $child_status = $_[1] >> 8;
        $cv->send('child_done');
    });

    my $reason = $cv->recv;
    Test::More::isnt($reason, 'timeout', "$label: did not hang");
    Test::More::is($child_status, 0, "$label: child succeeded");
}

1;
