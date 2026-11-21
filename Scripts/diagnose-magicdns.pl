#!/usr/bin/perl
# Compare native, installed-engine and isolated-engine DNS without changing
# Mimo's profile, provider, firewall, services or native Tailscale connection.
use strict;
use warnings;
use POSIX qw(setgid WNOHANG);
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);
use JSON::PP;
use Digest::SHA;

my $trace = @ARGV == 2 && $ARGV[0] eq "--trace";
shift if $trace;
die "Usage: sudo /usr/bin/perl Scripts/diagnose-magicdns.pl [--trace] peer.tailnet.ts.net\n"
    unless @ARGV == 1 && $ARGV[0] =~ /\A[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+\.ts\.net\.?\z/ && length($ARGV[0]) <= 253;
die "Run with sudo.\n" if $> != 0;
my $name = shift;
my $engine = "/Library/Application Support/Mimo/Runtime/mihomo";
my $controller = "/Library/Application Support/Mimo/Mihomo/controller.sock";
for my $path ("/Library", "/Library/Application Support", "/Library/Application Support/Mimo",
              "/Library/Application Support/Mimo/Runtime", $engine) {
    my @info = lstat($path);
    die "Unsafe or missing installed runtime: $path\n" unless @info && !-l _ && $info[4] == 0 && !($info[2] & 0022);
}
die "Installed engine is not executable.\n" unless -f $engine && -x $engine;
die "Installed engine controller is unavailable. Keep Rule active during this check.\n" unless -S $controller;
my $gid = getgrnam("_mimo");
die "Mimo runtime group is missing.\n" unless defined $gid;
setgid($gid) == 0 or die "setgid: $!\n";
umask 0077;
$| = 1;
my ($dir, $engine_pid, $command_pid, $trace_pid);

sub stop_child {
    my ($pid, $signal) = @_;
    return unless $pid;
    kill($signal || "TERM", $pid);
    for (1..40) {
        return if waitpid($pid, WNOHANG) != 0;
        select undef, undef, undef, 0.05;
    }
    kill "KILL", $pid;
    waitpid($pid, 0);
}
END {
    stop_child($command_pid);
    stop_child($engine_pid);
    stop_child($trace_pid);
    remove_tree($dir) if defined $dir;
}
$SIG{INT} = $SIG{TERM} = sub { die "Interrupted; cleaning up temporary engine.\n"; };

# All commands have a wall-clock limit, including commands that do not offer
# one themselves. Never print an installed profile or an entire peer list.
sub capture {
    my ($seconds, @args) = @_;
    pipe(my $read, my $write) or die "pipe: $!\n";
    $command_pid = fork();
    die "fork: $!\n" unless defined $command_pid;
    if ($command_pid == 0) {
        close $read;
        open STDIN, "<", "/dev/null" or POSIX::_exit(1);
        open STDOUT, ">&", $write or POSIX::_exit(1);
        open STDERR, ">&", $write or POSIX::_exit(1);
        close $write;
        exec {$args[0]} @args or POSIX::_exit(127);
    }
    close $write;
    my $output = "";
    my $finished = eval {
        local $SIG{ALRM} = sub { die "timeout\n"; };
        alarm $seconds;
        while (my $line = <$read>) { $output .= $line; }
        waitpid($command_pid, 0);
        alarm 0;
        1;
    };
    alarm 0;
    if (!$finished) { stop_child($command_pid); $output .= "[command timed out]\n"; }
    undef $command_pid;
    close $read;
    return $output;
}
sub query {
    my ($socket) = @_;
    return capture(8, "/usr/bin/curl", "--silent", "--show-error", "--max-time", "6", "--unix-socket", $socket,
                   "http://localhost/dns/query?name=$name&type=A");
}
sub print_result {
    my ($label, $value) = @_;
    print "\n=== $label ===\n$value";
    print "\n" unless $value =~ /\n\z/;
}
print "Mimo MagicDNS comparison. Keep Rule active until this finishes.\n";
print "This report includes the requested hostname, its answer and native interface.\n";
print_result("Installed app build", capture(4, "/usr/libexec/PlistBuddy", "-c", "Print :CFBundleVersion", "/Applications/Mimo.app/Contents/Info.plist"));
open my $binary, "<", $engine or die "$engine: $!\n";
binmode $binary;
print "Installed engine SHA256: ", Digest::SHA->new(256)->addfile($binary)->hexdigest, "\n";
close $binary;
print_result("Installed engine version", capture(5, "/usr/bin/curl", "--silent", "--show-error", "--max-time", "3",
             "--unix-socket", $controller, "http://localhost/version"));
print_result("Installed engine provider", capture(5, "/usr/bin/curl", "--silent", "--show-error", "--max-time", "3",
             "--unix-socket", $controller, "http://localhost/providers/proxies/tailscale-live"));
print_result("Installed engine DNS", query($controller));
my $route = capture(4, "/sbin/route", "-n", "get", "100.100.100.100");
my ($iface) = $route =~ /interface:\s*(utun\d+)/;
die "No native route to Tailscale DNS; cannot run the isolated comparison.\n" unless defined $iface && $iface ne "utun239";
print_result("Native route", $route);
my $config = capture(4, "/sbin/ifconfig", $iface);
print_result("Native interface", join("\n", grep { /^utun|^\s+inet / } split /\n/, $config));

if ($trace) {
    $dir = tempdir("mimo-dns-XXXXXX", DIR => "/private/tmp");
    print "Runtime primary group: $gid; real/effective UID: $</$>\n";
    # This capture is restricted to Quad100 DNS headers on the native interface.
    # It does not enable PF logging or alter any firewall rule/counter.
    $trace_pid = fork();
    die "fork: $!\n" unless defined $trace_pid;
    if ($trace_pid == 0) {
        open STDIN, "<", "/dev/null" or POSIX::_exit(1);
        open STDOUT, ">", "$dir/packets.txt" or POSIX::_exit(1);
        open STDERR, ">", "$dir/capture.txt" or POSIX::_exit(1);
        exec("/usr/sbin/tcpdump", "--immediate-mode", "-p", "-n", "-l", "-s", "128", "-i", $iface,
             "host 100.100.100.100 and port 53") or POSIX::_exit(127);
    }
    for (1..40) {
        my $value = "";
        if (open my $ready, "<", "$dir/capture.txt") {
            $value = do { local $/; <$ready> } // "";
            close $ready;
        }
        last if $value =~ /listening on|permission denied|No such device/i;
        select undef, undef, undef, 0.05;
    }
    for my $phase ("Before", "After") {
        for my $suffix ("", "/power-guard", "/permission", "/open-policy", "/native-transport") {
            my $anchor = "com.apple/000.mimo$suffix";
            my $rules = capture(4, "/sbin/pfctl", "-a", $anchor, "-vvsr");
            # Preserve the identity and counters of relevant rules, without
            # dumping public proxy/DERP endpoints or unrelated firewall rules.
            my @selected;
            my $include = 0;
            for my $line (split /\n/, $rules) {
                if ($line =~ /^\@/) {
                    $include = $suffix ne "/native-transport" && $suffix ne "/open-policy"
                        || $line =~ /\bblock\b|\banchor\b|\butun\d+\b|\bon lo0\b/;
                    push @selected, $line if $include;
                } elsif ($include && $line =~ /Evaluations:|Inserted:/) {
                    $line =~ s/^\s+//;
                    $selected[-1] .= " $line";
                }
            }
            print_result("$phase: $anchor", join("\n", @selected));
        }
        if ($phase eq "Before") {
            print_result("Native TCP DNS during capture", capture(5, "/usr/bin/dig", "\@100.100.100.100", $name,
                "A", "+tcp", "+time=3", "+tries=1", "+noall", "+comments", "+answer"));
            print_result("Installed engine DNS during capture", query($controller));
        }
    }
    stop_child($trace_pid, "INT");
    undef $trace_pid;
    for my $file ("packets.txt", "capture.txt") {
        open my $input, "<", "$dir/$file" or next;
        my $value = do { local $/; <$input> };
        close $input;
        print_result($file eq "packets.txt" ? "Quad100 packets on $iface" : "Capture status", $value || "(none)\n");
    }
    print "\nTrace finished; no firewall or routing settings were changed.\n";
    exit 0;
}
for my $tcp (0, 1) {
    print_result("Native DNS, runtime group, " . ($tcp ? "TCP" : "UDP"),
        capture(5, "/usr/bin/dig", "\@100.100.100.100", $name, "A", "+time=3", "+tries=1",
                "+noall", "+comments", "+answer", ($tcp ? "+tcp" : "+notcp")));
}

# A private Unix controller is the only listener. TUN, route detection, public
# proxies, DNS listeners and downloads are disabled. No active config is read.
$dir = tempdir("mimo-dns-XXXXXX", DIR => "/private/tmp");
delete @ENV{grep { /\ACLASH_/ } keys %ENV};
for my $case (["TCP, interface bound", "tcp", 1], ["UDP, interface bound", "udp", 1], ["TCP, system route", "tcp", 0]) {
    my ($label, $transport, $bound) = @$case;
    my $proxy = {name => "TS-NATIVE", type => "direct", udp => JSON::PP::true};
    $proxy->{"interface-name"} = $iface if $bound;
    open my $provider, ">", "$dir/provider.json" or die $!;
    print $provider encode_json({proxies => [$proxy]});
    close $provider;
    my $cfg = {
        "mixed-port" => 0, "port" => 0, "socks-port" => 0, "redir-port" => 0, "tproxy-port" => 0,
        mode => "rule", ipv6 => JSON::PP::false, "log-level" => "warning",
        "external-controller" => "", "external-controller-unix" => "$dir/controller.sock",
        tun => {enable => JSON::PP::false, "auto-route" => JSON::PP::false, "auto-detect-interface" => JSON::PP::false},
        dns => {enable => JSON::PP::true, listen => "", ipv6 => JSON::PP::false,
                "use-system-hosts" => JSON::PP::false, "use-hosts" => JSON::PP::false,
                "default-nameserver" => ["100.100.100.100"],
                nameserver => ["$transport://100.100.100.100:53#TS-DIRECT"]},
        "proxy-providers" => {"tailscale-live" => {type => "file", path => "$dir/provider.json"}},
        "proxy-groups" => [{name => "TS-DIRECT", type => "select", use => ["tailscale-live"]}],
        rules => ["MATCH,REJECT"]
    };
    open my $file, ">", "$dir/config.json" or die $!;
    print $file encode_json($cfg);
    close $file;
    unlink "$dir/controller.sock";
    $engine_pid = fork();
    die "fork: $!\n" unless defined $engine_pid;
    if ($engine_pid == 0) {
        open STDIN, "<", "/dev/null" or POSIX::_exit(1);
        open STDOUT, ">", "$dir/engine.log" or POSIX::_exit(1);
        open STDERR, ">&", STDOUT or POSIX::_exit(1);
        exec($engine, "-d", $dir, "-f", "$dir/config.json") or POSIX::_exit(127);
    }
    for (1..100) { last if -S "$dir/controller.sock"; select undef, undef, undef, 0.05; }
    print_result("Isolated engine: $label ($iface)", query("$dir/controller.sock"));
    stop_child($engine_pid);
    undef $engine_pid;
    open my $log, "<", "$dir/engine.log";
    if ($log) {
        while (my $line = <$log>) {
            print $line if $line =~ /level=(?:warning|error|fatal)/ && $line !~ /Mihomo shutting down/;
        }
        close $log;
    }
}
print_result("Installed engine DNS after comparison", query($controller));
print "\nFinished. Temporary engines stopped and temporary files removed on exit.\n";
