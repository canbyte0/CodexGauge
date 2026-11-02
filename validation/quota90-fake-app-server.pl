#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP;

$| = 1;
my $mode = shift // 'before';
my $account_reads = 0;
my $limit_reads = 0;
my $email = 'first@example.invalid';
my $account_id = 'account-first';

sub encoded {
    return encode_json($_[0]) . "\n";
}
sub account_notification {
    return encoded({ method => 'account/updated', params => { authMode => 'chatgpt', planType => 'plus' } });
}
sub account_response {
    my ($id) = @_;
    return encoded({ id => $id, result => { account => { type => 'chatgpt', email => $email, planType => 'plus' } } });
}
sub limits_response {
    my ($id, $used_id) = @_;
    my $result = {
        rateLimits => { limitId => 'codex', primary => { windowDurationMins => 300, usedPercent => 25, resetsAt => 2_000_000_000 } }
    };
    $result->{accountId} = $used_id if defined $used_id;
    return encoded({ id => $id, result => $result });
}

while (my $line = <STDIN>) {
    my $message = eval { decode_json($line) };
    next unless ref($message) eq 'HASH';
    my $method = $message->{method} // '';
    my $id = $message->{id};
    if ($method eq 'initialize') {
        print encoded({ id => $id, result => {} });
    } elsif ($method eq 'account/read') {
        $account_reads++;
        my $notification = account_notification();
        my $response = account_response($id);
        if ($mode eq 'after' || ($mode eq 'account-switch' && $account_reads > 1)) {
            print $response;
            select undef, undef, undef, 0.03;
            print $notification;
        } elsif ($mode eq 'batch') {
            print $notification . $response;
        } else {
            print $notification;
            select undef, undef, undef, 0.03;
            print $response;
        }
    } elsif ($method eq 'account/rateLimits/read') {
        $limit_reads++;
        if ($mode eq 'account-switch' && $limit_reads == 1) {
            # The old result arrives with a second update after the initial account/read echo.
            print account_notification() . limits_response($id, 'account-first');
            $email = 'second@example.invalid';
            $account_id = 'account-second';
        } else {
            print limits_response($id, $mode eq 'null-id' ? undef : $account_id);
        }
    }
}
