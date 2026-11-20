#!/usr/bin/env perl
# Test double for ntfy.sh and the external IP lookup service.
#
# Usage: fake-http-server.pl DIR
#
# Listens on a free 127.0.0.1 port and writes it to DIR/port. Every request is
# appended to DIR/requests.log. POST requests are answered with the status in
# DIR/post-status, GET requests with the one in DIR/get-status (default 200).
use strict;
use warnings;
use IO::Socket::INET;

my $dir = shift or die "usage: $0 DIR\n";

my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Listen    => 5,
    ReuseAddr => 1,
) or die "listen: $!\n";

sub status_for {
    my ($name) = @_;
    open(my $fh, '<', "$dir/$name") or return 200;
    my $status = <$fh>;
    close $fh;
    chomp $status;
    return $status;
}

# Publish the port atomically: the test waits for this file.
open(my $port_file, '>', "$dir/port.tmp") or die "port: $!\n";
print $port_file $server->sockport, "\n";
close $port_file;
rename("$dir/port.tmp", "$dir/port") or die "port: $!\n";

while (my $client = $server->accept) {
    my $request = <$client>;
    if (!defined $request) {
        close $client;
        next;
    }
    $request =~ s/\r?\n$//;

    my ($headers, $length, $expect) = ('', 0, 0);
    while (defined(my $line = <$client>)) {
        $line =~ s/\r?\n$//;
        last if $line eq '';
        $headers .= "$line\n";
        $length = $1 if $line =~ /^Content-Length:\s*(\d+)/i;
        $expect = 1  if $line =~ /^Expect:\s*100-continue/i;
    }
    # curl waits for this before sending bodies larger than 1 KiB.
    print $client "HTTP/1.1 100 Continue\r\n\r\n" if $expect;

    my $body = '';
    while (length($body) < $length) {
        my $n = read($client, $body, $length - length($body), length($body));
        last unless $n;
    }

    open(my $log, '>>', "$dir/requests.log") or die "log: $!\n";
    print $log "=== REQUEST\n$request\n$headers\n$body\n";
    close $log;

    my $is_post = $request =~ /^POST /;
    my $status  = status_for($is_post ? 'post-status' : 'get-status');
    my $reply =
        $status != 200 ? "<html>error $status</html>\n"
      : $is_post       ? "{}\n"
      :                  "203.0.113.7\n";
    print $client "HTTP/1.1 $status Test\r\n",
      "Content-Type: text/plain\r\n",
      'Content-Length: ', length($reply), "\r\n",
      "Connection: close\r\n\r\n", $reply;
    close $client;
}
