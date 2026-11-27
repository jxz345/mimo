#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempfile);
require $ARGV[0];

is_deeply([main::outbound_state_sources("en0 tcp 192.0.2.5:22 <- 192.0.2.8:51234 ESTABLISHED:ESTABLISHED\n")], [], 'inbound SSH is never selected for revocation');
is_deeply([main::outbound_state_sources("all tcp 192.0.2.5:51234 -> 203.0.113.4:443 ESTABLISHED:ESTABLISHED\nen0 tcp 192.0.2.5:5900 <- 192.0.2.8:51234 ESTABLISHED:ESTABLISHED\nall udp 2001:db8::5[51515] -> 2001:db8::8[443] MULTIPLE:MULTIPLE\n")], ['192.0.2.5', '2001:db8::5'], 'only original outbound IPv4 and IPv6 sources are revoked');
is_deeply([main::outbound_state_sources('')], [], 'empty state table requires no kill');
for my $invalid ('unrecognized output', 'all tcp malicious:4 -> 192.0.2.1:3 CLOSED:CLOSED') {
    eval { main::outbound_state_sources($invalid) }; ok($@, 'unknown state format cannot silently confirm closure');
}

my $original = "# administrator rules\nscrub-anchor \"com.apple/*\"\nanchor \"com.apple/*\"\nload anchor \"com.apple\" from \"/etc/pf.anchors/com.apple\"\n";
my $installed = main::managed_configuration($original, 1);
like($installed, qr/^load anchor "com.apple\/000.mimo" from "\/etc\/pf.anchors\/com.mimo.boot"$/m, 'persistent blocking policy is loaded by the system PF configuration');
is(main::managed_configuration($installed, 1), $installed, 'installation is idempotent');
is(main::managed_configuration($installed, 0), $original, 'uninstall preserves administrator configuration exactly');
my $external = $installed . "# added later by administrator\n";
is(main::managed_configuration($external, 0), $original . "# added later by administrator\n", 'uninstall preserves later unrelated edits');
for my $text ($original . "# BEGIN MIMO BOOT GUARD\n", $installed . $installed,
              $original . "# BEGIN MIMO BOOT GUARD\npass out quick all\n# END MIMO BOOT GUARD\n") {
    eval { main::managed_configuration($text, 1) };
    ok($@, 'ambiguous or externally changed managed block is rejected');
}
eval { main::managed_configuration('block all', 1) };
ok($@, 'missing application anchor is rejected');
ok(main::main_rules_supported('anchor "com.apple/*" all'), 'normal root anchor accepted');
ok(!main::main_rules_supported("pass out quick all\nanchor \"com.apple/*\" all"), 'quick bypass rule rejected');
ok(main::reference_live('123', "TOKENS:\n7 pfctl 123 0 days\n"), 'live PF reference recognized');
ok(!main::reference_live('123', "TOKENS:\n123 pfctl 456 0 days\n"), 'PID cannot masquerade as PF reference');
ok(!main::reference_live('123', "TOKENS:\n"), 'cleared same-boot reference is not reused');

my $path = '/Library/LaunchDaemons/com.mimo.supervisor.plist';
my $program = '/Library/PrivilegedHelperTools/mimo-core';
my $job = "path = $path\nprogram = $program\narguments = {\n $program\n --supervisor\n}\nproperties = keepalive | runatload\n";
ok(main::job_matches($job, $path, $program, '--supervisor', 1), 'matching loaded supervisor accepted');
ok(!main::job_matches($job, $path, $program, undef, 1), 'wrong arguments cannot masquerade as core');
ok(!main::job_matches($job =~ s/keepalive/other/r, $path, $program, '--supervisor', 1), 'missing restart policy rejected');
ok(!main::job_matches($job =~ s/runatload/other/r, $path, $program, '--supervisor', 1), 'missing boot policy rejected');
my @jobs = main::intended_jobs({core => JSON::PP::true, engine => JSON::PP::true});
is_deeply([map { $_->[0] } @jobs], ['com.mimo.mihomo'],
    'repair only existing supervisor/core/engine; never recreate retired boot or infrastructure jobs');
my @stopped = main::intended_jobs({core => JSON::PP::false, engine => JSON::PP::false});
is_deeply([map { $_->[5] ? 1 : 0 } @stopped], [0], 'repair respects saved core and engine Stop intent');
ok(!main::release_intent({engine => JSON::PP::true}), 'old intent remains managed');
ok(main::release_intent({engine => JSON::PP::false, releaseNetwork => JSON::PP::true}), 'explicit stop survives independent boot/repair reads');
ok(!main::release_intent({engine => JSON::PP::true, releaseNetwork => JSON::PP::false}), 'explicit start resumes management');
for my $intent ({engine => JSON::PP::true, releaseNetwork => JSON::PP::true},
                {engine => JSON::PP::false, releaseNetwork => 'true'}, {releaseNetwork => JSON::PP::true}) {
    eval { main::release_intent($intent) }; ok($@, 'ambiguous intent is rejected');
}
{
    no warnings 'redefine';
    my ($file, $empty_path) = tempfile(UNLINK => 1);
    close $file;
    local *main::secure = sub { }; # Test runs without root; exercise the real file reader.
    my $active = main::read_file($empty_path);
    is($active, '', 'an existing empty expected-policy file is not missing');
    $active = "pass out quick on lo0 all no state label \"mimo:active:loopback\"\nblock drop out quick all label \"mimo:active:deny-native-fallback\"\n";
    my $live = $active;
    local *main::required = sub {
        my $query = join(' ', @_);
        return "TOKENS:\n7 pfctl 123 0 days\n" if $query =~ /References$/;
        return "Status: Enabled\n" if $query =~ /-s info$/;
        return "anchor \"com.apple/*\" all\n" if $query eq '/sbin/pfctl -sr';
        return $live if $query =~ /000\.mimo -sr$/;
        return '';
    };
    my $snapshot = [undef, 'active', $active, '', '', encode_json({boot => 'test', token => '123'})];
    ok(!main::inspect_pf_snapshot($snapshot, 'test')->{needs_block}, 'active access requires the persistent fallback guard');
    $live = '';
    ok(main::inspect_pf_snapshot($snapshot, 'test')->{needs_block}, 'empty active policy requires closure');
    $live = $active;
    $snapshot->[2] = undef;
    ok(main::inspect_pf_snapshot($snapshot, 'test')->{needs_block}, 'missing expected policy cannot qualify active access');
    $snapshot->[2] = $active;
    $live = $active . "block return out quick inet6 all\n";
    ok(main::inspect_pf_snapshot($snapshot, 'test')->{needs_block}, 'older active IPv6 filter is not accepted as the new policy');
    $live = '';
    $snapshot->[1] = 'direct'; $snapshot->[2] = '';
    ok(main::inspect_pf_snapshot($snapshot, 'test')->{needs_block}, 'ordinary Direct must preserve incoming tracking');
    $live = "pass in on ! utun239 inet proto tcp from any to 192.0.2.2 flags S/SA keep state (if-bound) label \"mimo:inbound:tcp\"\n"
        . "pass in on ! utun239 inet6 proto tcp from any to fe80::12 flags S/SA keep state (if-bound) label \"mimo:inbound:tcp\"\n"
        . "pass in on lo0 all no state label \"mimo:inbound:loopback\"\n";
    $snapshot->[2] = $live;
    ok(!main::inspect_pf_snapshot($snapshot, 'test')->{needs_block}, 'exact ordinary Direct tracking is healthy');
    my $canonical = $live;
    for my $bad ('any', '(self)', '192.0.2.0/24', '0.0.0.0', '224.0.0.1') {
        $live = $canonical; $live =~ s/192\.0\.2\.2/$bad/; $snapshot->[2] = $live;
        ok(main::inspect_pf_snapshot($snapshot, 'test')->{needs_block}, "Direct cannot qualify invalid destination $bad");
    }
    $live = $canonical; $snapshot->[2] = $live;
    $live .= "pass out quick all\n"; $snapshot->[2] = $live;
    ok(main::inspect_pf_snapshot($snapshot, 'test')->{needs_block}, 'extra rules cannot qualify as Direct tracking');
    $live = ''; $snapshot->[2] = '';
    $snapshot->[1] = 'blocked';
    ok(main::inspect_pf_snapshot($snapshot, 'test')->{needs_block}, 'an empty policy cannot qualify a closed transition');
    $live = "block drop out quick all label \"mimo:transition:deny\"\n";
    $snapshot->[2] = $live;
    ok(!main::inspect_pf_snapshot($snapshot, 'test')->{needs_block}, 'flat closed policy is accepted');
}
done_testing();
