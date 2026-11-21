#!/usr/bin/perl
# Test the integrated MagicDNS policy without an app build. The temporary wrapper
# delegates to Mimo's live native anchor; it never copies or grants an interface.
# The independent child restores on parent death. No services/profiles are changed.
use strict;
use warnings;
use POSIX qw(WNOHANG);
use Fcntl qw(:DEFAULT :flock);
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);
use IO::Select;
use JSON::PP;
use Time::HiRes qw(time sleep);

die "Usage: sudo /usr/bin/perl test-magicdns-candidate.pl peer.tailnet.ts.net\n"
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
my $dir = tempdir("mimo-dns-candidate-XXXXXX", DIR => "/private/tmp");
my $tag = "dns-test-$$-" . int(rand(1_000_000));
my $test = "$base/$tag";
my $line = "anchor \"/$test\" out quick inet proto tcp to 100.100.100.100 port 53 user 0\n";
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
    return 0 unless $value && ($value->{Status} // -1) == 0;
    # A synthetic fake-IP answer is not a successful MagicDNS lookup.
    return scalar grep {
        ($_->{type} // 0) == 1 && ($_->{data} // '') =~ /\A100\.(\d+)\.\d+\.\d+\z/ && $1 >= 64 && $1 <= 127
    } @{$value->{Answer} // []};
}

print "Mimo integrated MagicDNS candidate test. Keep Rule active; do not switch modes.\n";
print "Root TCP Quad100 DNS uses Mimo's live verified native policy, then restores.\n";
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
print "Baseline already succeeds. Candidate queries still clear the engine DNS cache each time.\n" if $baseline;

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


my $native = "$base/native-transport";
my $guard_pattern = qr/^block return out quick proto tcp from any to any port = 53 group != \d+\s*$/m;
my $native_rules = rules($native);
die "Mimo has no verified native rule for $iface.\n"
    unless $native_rules =~ /^pass out quick on \Q$iface\E inet from any to 100\.64\.0\.0\/10 no state\s*$/m;
# Match the source ordering, after loopback/TUN handling and before the DNS guard.
# The unique wrapper exists only for reliable cleanup. Its sole child call uses
# Mimo's actual native anchor, so Stop/disconnect/expiry can still revoke access.
my $candidate = $original;
die "Could not locate the ordinary DNS guard.\n"
    unless $candidate =~ s/($guard_pattern)/$line$1/;
mutate(sub {
    assert_open(); assert_route();
    die "Mimo changed its firewall policy; stopping.\n" unless rules($open) eq $original;
    $changed = 1;
    load_rules($test, "anchor \"/$native\" out quick\n");
    load_rules($open, $candidate);
});

for my $attempt (1..3) {
    print "\n=== Fresh engine lookup $attempt/3 ===\n";
    assert_open(); assert_route();
    die "Candidate reference was replaced; test is inconclusive.\n" unless index(rules($open), $test) >= 0;
    die "FAIL: fresh installed-engine MagicDNS lookup did not answer.\n" unless query();
}
for my $transport ('+tcp', '+notcp') {
    print "\n=== Local DNS listener $transport ===\n";
    api('--fail', '-X', 'POST', 'http://localhost/cache/dns/flush');
    my ($status, $text) = run(6, '/usr/bin/dig', '@127.0.0.1', '-p', '1053', $name, 'A',
                            $transport, '+time=2', '+tries=1', '+noall', '+comments', '+answer');
    print $text;
    die "FAIL: local DNS listener did not return an answer.\n"
        unless $status == 0 && $text =~ /status: NOERROR/ && $text =~ /ANSWER: [1-9]/
            && $text =~ /\sIN\s+A\s+100\.(\d+)\.\d+\.\d+/ && $1 >= 64 && $1 <= 127;
}
print "\n=== macOS system resolver ===\n";
api('--fail', '-X', 'POST', 'http://localhost/cache/dns/flush');
my ($system_status, $system_text) = run(6, '/usr/bin/dscacheutil', '-q', 'host', '-a', 'name', $name);
print $system_text;
die "FAIL: macOS did not resolve the full Tailnet name.\n"
    unless $system_status == 0 && $system_text =~ /^ip_address:\s+100\.(\d+)\.\d+\.\d+/m && $1 >= 64 && $1 <= 127;
assert_open(); assert_route();
die "Candidate reference was replaced; test is inconclusive.\n" unless index(rules($open), $test) >= 0;
restore();
print "\nRESTORED: temporary wrapper removed; live native policy and permission gate untouched.\n";
print "PASS: three uncached engine lookups, TCP/UDP local-listener lookups and macOS resolution succeeded.\n";
print "Candidate test passed. The installed app is unchanged.\n";
