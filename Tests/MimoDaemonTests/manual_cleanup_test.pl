#!/usr/bin/perl
# Fixture and mocked-command checks. Never load PF rules or operate on launchd.
use strict;
use warnings;
no warnings 'once'; # Functions are locally replaced to isolate every OS mutation.
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
require "$FindBin::Bin/../../Scripts/cleanup-mimo-v1.pl";

our ($support, $helper, $pf_conf, $recovery);
my $boot = '11111111-2222-3333-4444-555555555555';
my $block = "# BEGIN MIMO BOOT GUARD\nload anchor \"com.apple/000.mimo\" from \"/etc/pf.anchors/com.mimo.boot\"\n# END MIMO BOOT GUARD\n";
my $other = "set skip on lo0\nanchor \"com.apple/*\"\nload anchor \"other-vpn\" from \"/etc/pf.anchors/other-vpn\"\n";
is(without_boot_block($other . $block), $other, 'only the exact Mimo boot block is removed');
is(without_boot_block($other), $other, 'already removed boot block is unchanged');
is(without_boot_block($block . $other), $other, 'unrelated trailing rules survive');
for my $text ($block . $block, "# BEGIN MIMO BOOT GUARD\n$other", "$block load anchor \"com.apple/000.mimo\" from \"/tmp/other\"\n", $block =~ s/load anchor/pass out quick\nload anchor/r) {
    ok(!eval { without_boot_block($text); 1 }, 'malformed, duplicate or unexpected boot references refuse automation');
}
my $crlf = $block =~ s/\n/\r\n/gr;
is(without_boot_block($other . $crlf), $other, 'CRLF managed block preserves surrounding bytes');

my $live = "TOKENS:\n1234 pfctl 987654321 today\n1235 other 9876543210 today\n";
is(reference_token(qq({"boot":"$boot","token":"987654321"}), $boot, $live), '987654321', 'current boot and exact live token can be released');
ok(!defined reference_token(qq({"boot":"$boot","token":"98765432"}), $boot, $live), 'token prefix is not a match');
ok(!defined reference_token(qq({"boot":"$boot","token":"987654321"}), 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE', $live), 'old-boot reference is never released');
ok(!eval { reference_token('{"token":"-d"}', $boot, $live); 1 }, 'malformed token cannot become a pfctl option');
ok(!eval { reference_token(qq({"boot":"$boot","token":"987654321\\n"}), $boot, $live); 1 }, 'token with a trailing newline is rejected');

{
    no warnings 'redefine';
    local *run_command = sub { return (113, '', 'Could not find service "com.mimo.core" in domain for system'); };
    ok(!defined job_state('com.mimo.core'), 'known missing-job error is absence');
}
for my $status (1, 124, 113) {
    no warnings 'redefine';
    local *run_command = sub { return ($status, '', 'Permission denied'); };
    ok(!eval { job_state('com.mimo.core'); 1 }, "inspection error $status is not absence");
}

for my $case (
    ['', undef, 0],
    ["  com.apple\n  other-vpn\n", "  another-child\n", 0],
    ["  com.apple\n", "  000.mimo\n", 1],
    ["  com.apple\n", "  com.apple/000.mimo\n", 1]
) {
    my @answers = @$case[0, 1];
    no warnings 'redefine';
    local *required = sub { return shift @answers; };
    is(anchor_present(), $case->[2], 'anchor inventory distinguishes missing and loaded Mimo scopes');
}

{
    no warnings 'redefine';
    local *required = sub { die "PF inspection failed\n"; };
    ok(!eval { anchor_present(); 1 }, 'failed PF inventory cannot be interpreted as absence');
}

{
    no warnings 'redefine';
    local *run_command = sub { return (0, <<'PROCESSES', ''); };
 100 /Library/PrivilegedHelperTools/mimo-core --supervisor
 101 /Library/Application Support/Mimo/Runtime/mihomo -d /private/profile
 102 /usr/bin/perl5.34 /Library/Application Support/Mimo/Guard/pf-guard.pl --check
 103 /Library/Application Support/clash-verge-service/cores/verge-mihomo
 104 /opt/homebrew/bin/mihomo
 105 /Applications/Mimo.app/Contents/MacOS/mimo-gui
 106 /usr/bin/perl /tmp/cleanup-mimo-v1.pl --apply
PROCESSES
    my ($workers, $guis) = processes();
    is_deeply($workers, [100, 101, 102], 'only Mimo worker paths match; unrelated engines and this script are excluded');
    is_deeply($guis, [105], 'Mimo GUI is detected separately');
}

{
    my @events;
    my %loaded = map { $_ => 1 } @main::labels;
    no warnings 'redefine';
    local *required = sub {
        my ($seconds, $input, $program, $verb, $target) = @_;
        push @events, "$verb $target";
        delete $loaded{$target =~ s{^system/}{}r} if $verb eq 'bootout';
        return '';
    };
    local *job_state = sub { return $loaded{$_[0]} ? 'loaded' : undef; };
    local *wait_for_workers = sub { push @events, 'workers exited'; };
    stop_jobs(\@main::labels);
    is_deeply([@events[0..4]], [map { "disable system/$_" } @main::labels], 'all disable requests precede unloading');
    is_deeply([@events[5..6]], ['bootout system/com.mimo.infrastructure', 'bootout system/com.mimo.pf-boot'], 'repair and boot guards unload first');
    is($events[10], 'workers exited', 'wait for worker exit before final disable checks');
    is_deeply([@events[11..15]], [map { "disable system/$_" } @main::labels], 'disable overrides reasserted after repair writers exit');
}

{
    my $after_wait = 0;
    no warnings 'redefine';
    local *required = sub { return ''; };
    local *job_state = sub { return $after_wait ? 'repair registered a job again' : undef; };
    local *wait_for_workers = sub { $after_wait = 1; };
    ok(!eval { stop_jobs(['com.mimo.core']); 1 }, 'a re-registered job prevents progress to firewall cleanup');
}

for my $failure ('none', 'stop', 'ipv6') {
    my @events;
    my $context = {jobs => [], paths => [], original => 'old', candidate => 'new'};
    no warnings 'redefine';
    local *backup_records = sub { push @events, 'backup'; };
    local *stop_jobs = sub { push @events, 'stop'; die "shutdown failed\n" if $failure eq 'stop'; };
    local *clear_network_policy = sub { push @events, 'PF and DNS'; };
    local *release_references = sub { push @events, 'references'; };
    local *restore_ipv6 = sub { push @events, 'ipv6'; die "restore failed\n" if $failure eq 'ipv6'; };
    local *wait_for_workers = sub { push @events, 'verify workers'; };
    local *anchor_present = sub { return 0; };
    local *required = sub { return "  No such key\n"; };
    local *archive_components = sub { push @events, 'archive'; };
    my $ok = eval { apply_recovery($context); 1 };
    if ($failure eq 'none') {
        ok($ok, 'complete recovery path succeeds with mocked OS commands');
        is_deeply(\@events, ['backup', 'stop', 'PF and DNS', 'references', 'ipv6', 'verify workers', 'archive'], 'network restoration and verification precede archiving');
    } elsif ($failure eq 'stop') {
        ok(!$ok, 'failed shutdown stops recovery');
        is_deeply(\@events, ['backup', 'stop'], 'failed shutdown cannot flush PF or remove DNS');
    } else {
        ok(!$ok, 'IPv6 restoration failure is reported');
        ok(!grep($_ eq 'archive', @events), 'IPv6 failure retains installed helper and journals');
        ok(grep($_ eq 'PF and DNS', @events), 'IPv6 failure does not withhold earlier connectivity recovery');
    }
}

{
    my @commands;
    no warnings 'redefine';
    local *remove_boot_block = sub {};
    local *anchor_present = sub { return 1; };
    local *required = sub {
        my ($seconds, $input, @args) = @_;
        push @commands, [@args];
        return "No such key\n" if defined $input && $input =~ /^show /;
        return '';
    };
    clear_network_policy('old', 'new');
    is_deeply($commands[0], ['/sbin/pfctl', '-a', 'com.apple/000.mimo', '-F', 'rules'], 'only the owned PF parent anchor is flushed');
    ok(!grep({ my $line = join(' ', @$_); $line =~ /pfctl (?:-d|-F|-f)/ } @commands), 'no global disable, flush or reload');
}

{
    my $dir = tempdir(CLEANUP => 1);
    local $support = $dir;
    local $helper = "$dir/missing-core";
    make_path("$dir/Runtime");
    open my $fh, '>', "$dir/Runtime/ipv6-original.plist" or die $!;
    print {$fh} 'saved settings'; close $fh;
    no warnings 'redefine';
    local *secure_path = sub { die "missing helper\n" if $_[0] eq $helper; return 1; };
    ok(!eval { restore_ipv6(); 1 }, 'missing helper with saved journal requires manual restoration');
    ok(-f "$dir/Runtime/ipv6-original.plist", 'saved IPv6 journal remains available');
}

{
    my $dir = tempdir(CLEANUP => 1);
    local $support = "$dir/Mimo";
    local $recovery = "$dir/backup";
    make_path("$support/Runtime", "$support/Service", $recovery);
    for my $path ("$support/Runtime/engine", "$support/Service/state.plist") {
        open my $fh, '>', $path or die $!;
        print {$fh} 'fixture'; close $fh;
    }
    no warnings 'redefine';
    local *secure_path = sub { return 1; }; # Fixture belongs to the test user, not root.
    archive_components(["$support/Runtime"]);
    ok(!-e "$support/Runtime", 'runtime directory is removed from its installed location');
    ok(-f "$recovery/removed$support/Runtime/engine", 'runtime is retained in the private backup');
    ok(-f "$support/Service/state.plist", 'machine source settings remain in place');
    make_path("$support/Runtime");
    ok(!eval { archive_components(["$support/Runtime"]); 1 }, 'existing backup is never overwritten by a resumed archive');
    ok(-d "$support/Runtime", 'collision leaves the new source intact');
}

{
    my $dir = tempdir(CLEANUP => 1);
    local $pf_conf = "$dir/pf.conf";
    open my $fh, '>', $pf_conf or die $!;
    print {$fh} 'changed by another owner'; close $fh;
    no warnings 'redefine';
    local *secure_path = sub { return 1; };
    ok(!eval { remove_boot_block($other . $block, $other); 1 }, 'concurrent PF configuration changes stop replacement');
    is(read_file($pf_conf), 'changed by another owner', 'concurrent configuration is preserved byte-for-byte');
}

# Exercise the real bounded runner only with harmless fixture commands.
my ($status, $stdout, $stderr) = run_command(3, undef, '/usr/bin/perl', '-e', 'print "out"; warn "err\n"; exit 7');
is($status, 7, 'runner preserves command exit code');
is($stdout, 'out', 'runner captures stdout separately');
is($stderr, "err\n", 'runner captures stderr separately');
($status, $stdout) = run_command(3, "fixture\n", '/usr/bin/perl', '-e', 'print while <STDIN>');
is($stdout, "fixture\n", 'runner delivers bounded stdin');
ok(!eval { run_command(.15, undef, '/usr/bin/perl', '-e', 'sleep 10'); 1 }, 'stalled child is terminated at its deadline');
done_testing();
