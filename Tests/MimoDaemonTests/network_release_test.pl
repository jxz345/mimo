#!/usr/bin/perl
use strict;
our $support;
use warnings;
use Test::More;
use FindBin;
require "$FindBin::Bin/../../Sources/MimoDiagnostics/release-network.pl";
our ($anchor, $dns_key);
{
    no warnings 'redefine';
    my @calls;
    local *required = sub { push @calls, [@_]; return $_[1] =~ /^show / ? "  No such key\n" : ''; };
    ok(eval { remove_owned_resolver(); 1 }, 'persistent or temporary Mimo resolver is removed and read back');
    is_deeply([map { $_->[1] } @calls], ["remove $dns_key\nquit\n", "show $dns_key\nquit\n"],
        'DNS cleanup touches only Mimo, preserving native VPN and network service resolvers');
}
{
    no warnings 'redefine';
    local *required = sub { '<dictionary> { ServerAddresses : 127.0.0.1 }' };
    ok(!eval { remove_owned_resolver(); 1 }, 'successful scutil exit is not proof of DNS cleanup');
}
{
    no warnings 'redefine';
    local *anchor_present = sub { 1 };
    local *required = sub {
        my (undef, undef, undef, undef, $path) = @_;
        return "permission\nold-release\n" if $path eq $anchor;
        return "$anchor/old-release/dns-wrapper\n" if $path eq "$anchor/old-release";
        return '';
    };
    is_deeply([owned_anchors()], [$anchor, "$anchor/permission", "$anchor/old-release", "$anchor/old-release/dns-wrapper"],
        'finds old and nested children even without a parent anchor rule');
}
for my $child ('../other', '..', '.', 'com.apple/another-vpn', '/other', "safe\n/other") {
    no warnings 'redefine';
    local *anchor_present = sub { 1 };
    local *required = sub { $child };
    ok(!eval { owned_anchors(); 1 }, "rejects out-of-scope child: $child");
}
{
    no warnings 'redefine';
    my @calls;
    my $inventory = 0;
    local *read_file = sub { '' };
    local *remove_boot_block = sub {};
    local *owned_anchors = sub { ++$inventory == 1 ? ($anchor, "$anchor/legacy") : () };
    local *required = sub { push @calls, [@_[2..$#_]]; '' };
    clear_owned_firewall();
    is_deeply(\@calls, [map { my $path = $_; map { ['/sbin/pfctl', '-a', $path, '-F', $_] } qw(rules nat Tables) } ($anchor, "$anchor/legacy")],
        'flushes only owned filter/NAT/tables; no global states or PF disable');
}
{
    no warnings 'redefine';
    local *read_file = sub { '' };
    local *remove_boot_block = sub {};
    local *owned_anchors = sub { ($anchor) };
    local *required = sub { $_[-1] eq '-sr' ? 'block all' : '' };
    ok(!eval { clear_owned_firewall(); 1 }, 'surviving rules prevent success');
}
for my $status (0, 1, 124) {
    no warnings 'redefine';
    local *run_command = sub { ($status, '', '') };
    ok(!eval { require_stopped_jobs(); 1 }, 'running/unknown job state prevents release');
}
{
    no warnings 'redefine';
    my @commands;
    local *run_command = sub {
        push @commands, join(' ', @_[2..$#_]);
        return (0, ';; status: NOERROR' . "\n87.194.123.100.in-addr.arpa. 5 IN PTR vm.tail.ts.net.\n", '') if $_[2] eq '/usr/bin/dig';
        return (0, " interface: utun8\n", '');
    };
    local *required = sub { " inet 100.123.194.87 --> 100.123.194.87\n" };
    ok(eval { verify_tailnet(); 1 }, 'native route plus actual reverse MagicDNS response qualifies');
    like($commands[1], qr/dig \@100\.100\.100\.100 -x 100\.123\.194\.87 \+tcp/, 'queries native Quad100 without Mimo/proxy');
}
{
    no warnings 'redefine';
    local *run_command = sub { $_[2] eq '/usr/bin/dig' ? (0, 'status: SERVFAIL', '') : (0, "interface: utun8\n", '') };
    local *required = sub { "inet 100.123.194.87 --> 100.123.194.87\n" };
    ok(!eval { verify_tailnet(); 1 }, 'failed connected Tailnet DNS prevents completed uninstall');
}
{
    no warnings 'redefine';
    require File::Temp;
    local $support = File::Temp::tempdir(CLEANUP => 1);
    mkdir "$support/Runtime";
    local *secure_path = sub { 1 }; # Files belong to the unprivileged test runner.
    my @steps;
    local *remove_owned_resolver = sub { push @steps, 'dns-remove' };
    local *required = sub {
        my $command = join(' ', @_[2..$#_]);
        push @steps, $command;
        return "block drop out quick all label \"mimo:transition:deny\"\n" if $command =~ /-sr$/;
        return '';
    };
    prepare_network();
    ok(-s "$support/Runtime/pf-close.epoch" && -s "$support/Runtime/pf-mutation.epoch",
       'cleanup revokes older grants using the shared mutation epochs');
    my ($denial) = grep { $steps[$_] =~ /-sr$/ } 0..$#steps;
    my ($dns) = grep { $steps[$_] eq 'dns-remove' } 0..$#steps;
    ok($denial < $dns, 'cleanup confirms the guard before draining DNS');
    @steps = ();
    local *required = sub { '' };
    ok(!eval { prepare_network(); 1 }, 'failed close readback aborts cleanup');
    ok(!@steps, 'failed closure leaves the existing resolver untouched');
}
done_testing();
