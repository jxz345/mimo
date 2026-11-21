#!/usr/bin/perl
# Temporary physical-Mac test. Never changes the permission/power guard, profile,
# provider, services or routing. The independent child restores on parent death.
use strict;
use warnings;
use POSIX qw(WNOHANG);
use Fcntl qw(:DEFAULT :flock);
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);
use IO::Select;
use JSON::PP;
use Time::HiRes qw(time sleep);

die "Usage: sudo /usr/bin/perl test-magicdns-firewall.pl peer.tailnet.ts.net\n"
    unless @ARGV == 1 && $ARGV[0] =~ /\A[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+\.ts\.net\.?\z/ && length($ARGV[0]) <= 253;
die "Run with sudo.\n" unless $> == 0;
my $name = shift;
my $base = "com.apple/000.mimo";
my $open = "$base/open-policy";
my $runtime = "/Library/Application Support/Mimo/Runtime";
my $controller = "/Library/Application Support/Mimo/Mihomo/controller.sock";
for my $path ("/Library", "/Library/Application Support", "/Library/Application Support/Mimo", $runtime,
              "/Library/Application Support/Mimo/Mihomo", $controller) {
    my @st = lstat($path);
    die "Unsafe or missing Mimo path: $path\n" unless @st && !-l _ && $st[4] == 0 && !($st[2] & 0022);
}
die "Mimo controller is unavailable.\n" unless -S $controller;
umask 0077;
$| = 1;
my $dir = tempdir("mimo-dns-rule-XXXXXX", DIR => "/private/tmp");
my $tag = "dns-test-$$-" . int(rand(1_000_000));
my $test = "$base/$tag";
my $line = "anchor \"/$test\" out quick all\n";
my ($command_pid, $guard_pid, $guard_write, $changed, $cleaned, $is_guard, $keep_evidence);

sub stop_child {
    my ($pid) = @_;
    return unless $pid;
    return if waitpid($pid, WNOHANG) != 0;
    kill 'TERM', $pid;
    for (1..20) { return if waitpid($pid, WNOHANG) != 0; sleep .05; }
    kill 'KILL', $pid;
    waitpid($pid, 0);
}

sub run {
    my ($seconds, @args) = @_;
    pipe(my $read, my $write) or die "pipe: $!\n";
    $command_pid = fork();
    die "fork: $!\n" unless defined $command_pid;
    if (!$command_pid) {
        close $guard_write if $guard_write;
        close $read;
        open STDIN, '<', '/dev/null' or POSIX::_exit(1);
        open STDOUT, '>&', $write or POSIX::_exit(1);
        # Keep installed endpoint/rule details in the root-private evidence directory.
        open STDERR, '>>', "$dir/commands.log" or POSIX::_exit(1);
        close $write;
        exec {$args[0]} @args or POSIX::_exit(127);
    }
    close $write;
    my ($text, $status) = ('', -1);
    my $ok = eval {
        local $SIG{ALRM} = sub { die "Command timed out: $args[0]\n"; };
        alarm $seconds;
        while (my $part = <$read>) { $text .= $part; }
        waitpid($command_pid, 0); $status = $?;
        alarm 0;
        1;
    };
    my $error = $@;
    alarm 0;
    stop_child($command_pid) unless $ok;
    undef $command_pid;
    close $read;
    if (!$ok) { $keep_evidence = 1; die $error; }
    return ($status, $text);
}

sub checked {
    my ($status, $text) = run(@_);
    if ($status) { $keep_evidence = 1; die "Command failed; private details: $dir/commands.log\n"; }
    return $text;
}

sub rules { return checked(4, '/sbin/pfctl', '-a', $_[0], '-sr'); }
sub write_file {
    my ($path, $text) = @_;
    open my $file, '>', $path or die "write: $!\n";
    print $file $text or die "write: $!\n";
    close $file or die "close: $!\n";
}

sub lock_file {
    my ($path) = @_;
    sysopen(my $file, $path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600) or die "lock open: $!\n";
    my @st = stat($file);
    die "Unsafe lock file.\n" unless -f $file && $st[4] == 0 && !($st[2] & 0077);
    return $file;
}

# Use Mimo's short PF mutation lock and revocation priority. Never keep the lock
# during DNS requests, and never restore a saved permission grant.
sub mutate {
    my ($operation) = @_;
    my $until = time + 5;
    while (time < $until) {
        my $admission = lock_file("$runtime/pf-revocation.lock");
        if (flock($admission, LOCK_EX | LOCK_NB)) {
            my $lock = lock_file("$runtime/pf-mutation.lock");
            if (flock($lock, LOCK_EX | LOCK_NB)) {
                close $admission;
                # Same-volume atomic publication, as used by the installed writer.
                write_file("$runtime/$tag.epoch", "$tag-" . time . "\n");
                rename "$runtime/$tag.epoch", "$runtime/pf-mutation.epoch" or die "epoch: $!\n";
                my $result = $operation->();
                close $lock;
                return $result;
            }
        }
        close $admission;
        sleep .05;
    }
    die "Firewall is busy or revoking access. No grant was changed.\n";
}

sub load_rules {
    my ($anchor, $text) = @_;
    write_file("$dir/rules.pf", $text);
    checked(4, '/sbin/pfctl', '-n', '-a', $anchor, '-f', "$dir/rules.pf");
    checked(4, '/sbin/pfctl', '-a', $anchor, '-f', "$dir/rules.pf");
}

sub restore {
    return if $cleaned;
    my $lock = lock_file("$dir/cleanup.lock");
    flock($lock, LOCK_EX) or die "cleanup lock: $!\n";
    mutate(sub {
        my $current = rules($open);
        # Remove only our anchor reference. If Mimo already replaced this policy,
        # leave its newer policy alone; never write an old snapshot over it.
        if ($current =~ s/^anchor "\/\Q$test\E"[^\n]*\n?//mg) {
            load_rules($open, $current);
        }
        load_rules($test, "\n");
        die "Temporary rule removal could not be confirmed.\n"
            if index(rules($open), $test) >= 0 || rules($test) =~ /\S/;
    });
    close $lock;
    $cleaned = 1;
}

END {
    my $exit_status = $?;
    if (!$is_guard && defined $dir) {
        stop_child($command_pid);
        my $ok = eval { restore() if $changed; 1 };
        if ($guard_write) {
            print $guard_write "done\n" if $ok;
            close $guard_write;
            waitpid($guard_pid, 0) if $guard_pid;
        }
        if ($ok && !$keep_evidence) { remove_tree($dir); }
        elsif ($ok) { print STDERR "Private command evidence retained at $dir\n"; }
        else {
            print STDERR "RESTORE ERROR: $@\nPrivate recovery evidence retained at $dir\n";
            $exit_status = 256;
        }
    }
    # Successful cleanup commands must not turn a failed/interrupted test into
    # exit status zero.
    $? = $exit_status;
}
$SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub { die "Interrupted; restoring temporary firewall rules.\n"; };
$SIG{PIPE} = 'IGNORE';

sub assert_open {
    die "The protected gate is no longer open; stopping without reopening it.\n"
        unless rules("$base/permission") =~ /anchor "\/\Q$open\E" out quick all/;
    die "Power guard is active; stopping.\n" if rules("$base/power-guard") =~ /\S/;
}

sub api {
    return checked(8, '/usr/bin/curl', '--silent', '--show-error', '--max-time', '6', '--unix-socket', $controller, @_);
}
sub query {
    # Only the engine's ordinary DNS cache is cleared; fake-IP mappings are kept.
    api('--fail', '-X', 'POST', 'http://localhost/cache/dns/flush');
    my $text = api("http://localhost/dns/query?name=$name&type=A");
    print "$text\n";
    my $value = eval { decode_json($text) };
    return $value && ($value->{Status} // -1) == 0 && @{$value->{Answer} // []};
}

print "Mimo temporary MagicDNS firewall test. Keep Rule active; do not switch modes.\n";
print "Tests TCP DNS to Quad100 only on the verified native interface, then restores.\n";
print "No app build/install, profile reload, service restart or provider change.\n";
assert_open();
my $provider = decode_json(api('http://localhost/providers/proxies/tailscale-live'));
my @native = grep { ($_->{name} // '') eq 'TS-NATIVE' && ($_->{type} // '') eq 'Direct' } @{$provider->{proxies} // []};
die "Exactly one live native provider is required.\n" unless @native == 1;
my $iface = $native[0]->{interface} // '';
die "Invalid native interface.\n" unless $iface =~ /\Autun\d+\z/ && $iface ne 'utun239';
sub assert_route {
    my $route = checked(3, '/sbin/route', '-n', 'get', '100.100.100.100');
    die "The native route changed; stopping.\n" unless $route =~ /interface:\s*\Q$iface\E\s/;
    my $config = checked(3, '/sbin/ifconfig', $iface);
    die "The native interface is down.\n" unless $config =~ /^\Q$iface\E:.*<[^>]*\bUP\b/;
}
assert_route();
print "Native interface: $iface\n\n=== Before ===\n";
my $baseline = query();
print "Baseline already succeeds; rule counters will distinguish a real test from a cached answer.\n" if $baseline;

my $original = rules($open);
die "Expected Mimo TCP DNS guard is missing.\n" unless $original =~ /^block return out quick proto tcp from any to any port = 53 group != \d+\s*$/m;
die "Another temporary DNS test is present.\n" if $original =~ /dns-test-/;
write_file("$dir/original-open-policy.pf", $original);

# The detached child also removes the test if the terminal or parent is killed.
# File descriptors are closed in every command child, so EOF reliably signals
# parent death. The watchdog cannot grant/reopen traffic.
pipe(my $guard_read, $guard_write) or die "pipe: $!\n";
my $parent_pid = $$;
$guard_pid = fork();
die "fork: $!\n" unless defined $guard_pid;
if (!$guard_pid) {
    $is_guard = 1;
    close $guard_write; undef $guard_write;
    POSIX::setsid();
    $SIG{INT} = $SIG{TERM} = $SIG{HUP} = 'IGNORE';
    my $ready = IO::Select->new($guard_read)->can_read(45);
    my $message = '';
    sysread($guard_read, $message, 32) if $ready;
    if ($message ne "done\n") {
        # A timed-out parent must not resume and reinstall the exception after
        # cleanup. Allow its signal handler to stop the current bounded command.
        if (!$ready && getppid() == $parent_pid) {
            kill 'TERM', $parent_pid;
            sleep 2;
            if (getppid() == $parent_pid) { kill 'KILL', $parent_pid; sleep 5; }
        }
        my $ok;
        for (1..3) { $ok = eval { restore(); 1 }; last if $ok; sleep .2; }
        print STDERR $ok ? "Watchdog restored the temporary firewall rules.\n" : "WATCHDOG RESTORE ERROR: $@\nEvidence: $dir\n";
        remove_tree($dir) if $ok;
    }
    POSIX::_exit(0);
}
close $guard_read;

my $until = time + 35;
my $passed = 0;
for my $owner ('user 0 ', '') {
    die "Test deadline reached.\n" if time >= $until;
    assert_route(); assert_open();
    my $label = length($owner) ? 'Root-owned Quad100 TCP exception' : 'Interface-scoped Quad100 TCP exception';
    print "\n=== $label ===\n";
    print "This brief second test permits Quad100 TCP DNS from any process on $iface. It is not a permanent policy.\n" unless length($owner);
    mutate(sub {
        my $current = rules($open);
        die "Mimo changed its firewall policy; stopping.\n" unless $current eq $original || $current eq $line . $original;
        $changed = 1;
        load_rules($test, "pass out quick on $iface inet proto tcp to 100.100.100.100 port 53 ${owner}no state\n");
        load_rules($open, $line . $original) if $current eq $original;
    });
    my $answer = query();
    assert_open(); assert_route();
    my $counters = checked(4, '/sbin/pfctl', '-a', $test, '-vvsr');
    my ($packets) = $counters =~ /Packets:\s*(\d+)/;
    print "Temporary pass-rule packets: ", $packets // 'unknown', "\n";
    if ($answer && ($packets // 0) > 0) {
        $passed = 1;
        print "PASS: the installed engine received a full-name answer through this rule.\n";
        print "\n=== Local DNS listener ===\n";
        my ($status, $text) = run(6, '/usr/bin/dig', '@127.0.0.1', '-p', '1053', $name, 'A', '+tcp', '+time=3', '+tries=1', '+noall', '+comments', '+answer');
        print $text;
        last;
    }
    print "No confirmed success through this rule.\n";
}
restore();
print "\nRESTORED: temporary rule and anchor reference removed; permission gate untouched.\n";
print $passed ? "Candidate firewall test passed. This result does not qualify a permanent app fix.\n"
              : "Candidate firewall test did not restore DNS.\n";
exit($passed ? 0 : 1);
