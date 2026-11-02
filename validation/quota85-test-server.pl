#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP;
$| = 1;
my $mode = shift // 'good';
while (my $line = <STDIN>) {
    my $message = eval { decode_json($line) };
    next unless ref($message) eq 'HASH';
    my $method = $message->{method} // '';
    my $id = $message->{id};
    if ($method eq 'initialize') {
        exit 0 if $mode eq 'init-exit';
        print encode_json({ id => $id, result => {} }), "\n";
    } elsif ($method eq 'account/read') {
        exit 0 if $mode eq 'account-exit';
        print encode_json({ id => $id, result => { account => { type => 'chatgpt' } } }), "\n";
    } elsif ($method eq 'account/rateLimits/read') {
        if ($mode eq 'oversize') { print 'x' x 2000010; sleep 5; exit 0; }
        print encode_json({ id => $id, result => { rateLimits => { limitId => 'codex', primary => { windowDurationMins => 300, usedPercent => 25, resetsAt => 2000000000 } } } }), "\n";
    }
}
