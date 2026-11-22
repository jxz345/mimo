#!/usr/bin/perl
# Shared final network release for uninstall and Stop. Jobs must already be stopped.
# No global PF reset, Tailscale restart, or changes to another VPN.
# Never disable PF globally, reload its root rules, or stop another VPN's engine.
use strict;
use warnings;
use Fcntl qw(:DEFAULT :mode);
use File::Basename qw(dirname);
use File::Temp qw(tempfile);
use IO::Select;
use JSON::PP qw(decode_json);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);

our $support = '/Library/Application Support/Mimo';
our $helper = '/Library/PrivilegedHelperTools/mimo-core';
our $pf_conf = '/private/etc/pf.conf';
our $anchor = 'com.apple/000.mimo';
our $dns_key = 'State:/Network/Service/com.mimo.dns/DNS';
our $active_child;

sub stop_child {
    return unless $active_child;
    kill('TERM', -$active_child) || kill('TERM', $active_child);
    sleep .1;
    kill 'KILL', -$active_child;
    waitpid($active_child, 0);
    undef $active_child;
}

sub run_command {
    my ($seconds, $input, @args) = @_;
    pipe(my $out_r, my $out_w) or die "pipe: $!\n";
    pipe(my $err_r, my $err_w) or die "pipe: $!\n";
    pipe(my $in_r, my $in_w) or die "pipe: $!\n";
    $active_child = fork();
    die "fork: $!\n" unless defined $active_child;
    if (!$active_child) {
        POSIX::setpgid(0, 0) == 0 or POSIX::_exit(126);
        close $out_r; close $err_r; close $in_w;
        open STDIN, '<&', $in_r or POSIX::_exit(126);
        open STDOUT, '>&', $out_w or POSIX::_exit(126);
        open STDERR, '>&', $err_w or POSIX::_exit(126);
        close $in_r; close $out_w; close $err_w;
        exec {$args[0]} @args or POSIX::_exit(127);
    }
    close $in_r; close $out_w; close $err_w;
    my ($out, $err, $status) = ('', '', undef);
    my $ok = eval {
        local $SIG{PIPE} = 'IGNORE';
        # Only short scutil commands use stdin; PF candidates are passed as files.
        die "Command input too large\n" if length($input // '') > 1024;
        print {$in_w} $input or die "Command input failed: $!\n" if defined $input;
        close $in_w;
        my $reader = IO::Select->new($out_r, $err_r);
        my $out_fd = fileno($out_r);
        my $deadline = time() + $seconds;
        while ($reader->count || !defined $status) {
            die "Timed out: $args[0]\n" if time() >= $deadline;
            for my $fh ($reader->can_read(.05)) {
                my $size = sysread($fh, my $part, 8192);
                die "Cannot read command output: $!\n" unless defined $size;
                if (!$size) { $reader->remove($fh); close $fh; next; }
                if (fileno($fh) == $out_fd) { $out .= $part; } else { $err .= $part; }
                die "Command output exceeded limit\n" if length($out) + length($err) > 4 * 1024 * 1024;
            }
            if (!defined $status && waitpid($active_child, WNOHANG) == $active_child) {
                $status = ($? & 127) ? 128 + ($? & 127) : $? >> 8;
            }
        }
        1;
    };
    my $error = $@;
    if (!$ok) { stop_child(); die $error; }
    undef $active_child;
    return ($status, $out, $err);
}

sub required {
    my ($seconds, $input, @args) = @_;
    my ($status, $out, $err) = run_command($seconds, $input, @args);
    die "$args[0] failed ($status): $err$out\n" if $status;
    return $out;
}

sub secure_path {
    my ($path, $directory, $optional) = @_;
    my @st = lstat($path);
    return 0 if !@st && $optional && $!{ENOENT};
    die "Unsafe or missing path: $path\n" unless @st && !S_ISLNK($st[2])
        && ($directory ? S_ISDIR($st[2]) : S_ISREG($st[2]))
        && $st[4] == 0 && !($st[2] & 0022);
    return 1;
}

sub read_file {
    my ($path) = @_;
    sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or die "Cannot read $path: $!\n";
    my @st = stat($fh);
    die "Unexpected file: $path\n" unless S_ISREG($st[2]) && $st[7] <= 4 * 1024 * 1024;
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text // '';
}

sub without_boot_block {
    my ($text) = @_;
    my $begin = '# BEGIN MIMO BOOT GUARD';
    my $end = '# END MIMO BOOT GUARD';
    my $begins = () = $text =~ /\Q$begin\E/g;
    my $ends = () = $text =~ /\Q$end\E/g;
    if ($begins || $ends) {
        die "Unexpected Mimo PF markers; use the README manual procedure\n" unless $begins == 1 && $ends == 1;
        my $removed = $text =~ s/^\Q$begin\E\r?\nload anchor "com\.apple\/000\.mimo" from "\/etc\/pf\.anchors\/com\.mimo\.boot"\r?\n\Q$end\E(?:\r?\n|\z)//m;
        die "Unexpected Mimo boot block; use the README manual procedure\n" unless $removed;
    }
    die "Unmarked Mimo PF reference; inspect pf.conf manually\n" if $text =~ /com\.apple\/000\.mimo|com\.mimo\.boot/;
    return $text;
}

sub anchor_present {
    my $roots = required(5, undef, '/sbin/pfctl', '-s', 'Anchors');
    return 0 unless $roots =~ /^\s*com\.apple\s*$/m;
    my $children = required(5, undef, '/sbin/pfctl', '-a', 'com.apple', '-s', 'Anchors');
    return $children =~ /^\s*(?:com\.apple\/)?000\.mimo\s*$/m ? 1 : 0;
}

sub validate_pf_candidate {
    my ($text) = @_;
    my ($fh, $path) = tempfile('mimo-pf-check-XXXXXXXX', DIR => '/private/tmp', UNLINK => 1);
    print {$fh} $text or die "Cannot write PF check file\n";
    close $fh or die "Cannot close PF check file\n";
    required(10, undef, '/sbin/pfctl', '-n', '-f', $path);
    unlink $path or die "Cannot remove PF check file\n";
}

sub remove_boot_block {
    my ($original, $candidate) = @_;
    secure_path($pf_conf, 0, 0);
    die "pf.conf changed since preview; rerun inspection\n" unless read_file($pf_conf) eq $original;
    return if $original eq $candidate;
    validate_pf_candidate($candidate);
    my @st = stat($pf_conf);
    my ($fh, $path) = tempfile('.mimo-cleanup-XXXXXXXX', DIR => dirname($pf_conf), UNLINK => 1);
    print {$fh} $candidate or die "Cannot write PF configuration\n";
    close $fh or die "Cannot close PF configuration\n";
    chmod($st[2] & 0777, $path) == 1 or die "Cannot preserve PF configuration mode\n";
    chown($st[4], $st[5], $path) == 1 or die "Cannot preserve PF configuration owner\n";
    die "pf.conf changed during preparation\n" unless read_file($pf_conf) eq $original;
    rename($path, $pf_conf) or die "Cannot replace PF configuration: $!\n";
}

sub reference_token {
    my ($json, $boot, $live) = @_;
    my $record = decode_json($json);
    die "Malformed PF reference record\n" unless ref($record) eq 'HASH'
        && !ref($record->{boot}) && !ref($record->{token})
        && ($record->{boot} // '') =~ /\A[a-fA-F0-9-]{36}\z/
        && ($record->{token} // '') =~ /\A\d{1,32}\z/;
    return undef unless $record->{boot} eq $boot;
    my $token = $record->{token};
    return $live =~ /^\d+\s+\S+\s+\Q$token\E\s/m ? $token : undef;
}

sub release_references {
    my $boot = required(5, undef, '/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid');
    chomp $boot;
    for my $relative ('Runtime/pf-reference.json', 'Guard/pf-reference.json') {
        my $path = "$support/$relative";
        next unless -e $path;
        my $ok = eval {
            secure_path($path, 0, 0);
            my $live = required(5, undef, '/sbin/pfctl', '-s', 'References');
            die "Unknown PF reference listing\n" unless $live =~ /TOKENS:|^No pf starter references held\s*$/;
            my $token = reference_token(read_file($path), $boot, $live);
            required(5, undef, '/sbin/pfctl', '-X', $token) if defined $token;
            1;
        };
        die "Cannot release Mimo PF reference ($relative): $@" unless $ok;
        unlink($path) or die "Cannot remove released PF reference record: $!\n";
    }
}

sub restore_ipv6 {
    my $journal = "$support/Runtime/ipv6-original.plist";
    if (!-e $journal) {
        die "IPv6 apply journal remains without original settings; retain files and use manual recovery\n"
            if -e "$support/Runtime/ipv6-apply-pending";
        print "No saved IPv6 settings; current network settings retained.\n";
        print "MIMO_CLEANUP ipv6_no_backup\n";
        return;
    }
    secure_path($journal, 0, 0);
    secure_path($helper, 0, 0);
    required(20, undef, '/usr/bin/codesign', '--verify', '--strict', $helper);
    required(20, undef, $helper, '--restore-ipv6-preferences');
    die "IPv6 restoration did not finish; original files retained\n"
        if -e $journal || -e "$support/Runtime/ipv6-apply-pending";
    print "MIMO_CLEANUP ipv6_restored\n";
}


# macOS PF does not recursively flush child rules with -a parent -F rules.
# Enumerate first, clear only the exact owned tree, and verify surviving nodes.
sub owned_anchors {
    return () unless anchor_present();
    my @pending = ($anchor);
    my @found;
    my %seen;
    while (@pending) {
        my $path = shift @pending;
        die "Mimo anchor tree exceeds inspection limit\n" if @found >= 128;
        die "Invalid Mimo anchor path\n" unless $path eq $anchor || $path =~ /^\Q$anchor\E\/(?:[A-Za-z0-9_.-]+\/?)+$/;
        die "Repeated Mimo anchor\n" if $seen{$path}++;
        push @found, $path;
        my $children = required(5, undef, '/sbin/pfctl', '-a', $path, '-s', 'Anchors');
        for my $child (split /\n/, $children) {
            $child =~ s/^\s+|\s+$//g;
            next unless length $child;
            die "Invalid Mimo anchor component\n" if grep { $_ eq "." || $_ eq ".." } split m{/}, $child;
            if ($child =~ /^[A-Za-z0-9_.-]+$/) { $child = "$path/$child"; }
            die "Unexpected child outside Mimo's firewall tree\n"
                unless $child =~ /^\Q$path\E\/[A-Za-z0-9_.-]+$/;
            push @pending, $child;
        }
    }
    return @found;
}

sub clear_owned_firewall {
    my $original = read_file($pf_conf);
    remove_boot_block($original, without_boot_block($original));
    my @paths = owned_anchors();
    # Parent first releases traffic immediately; its children remain allocated
    # while they contain rules. Never flush global states or another anchor.
    for my $path (@paths) {
        required(5, undef, '/sbin/pfctl', '-a', $path, '-F', 'rules');
        required(5, undef, '/sbin/pfctl', '-a', $path, '-F', 'nat');
        required(5, undef, '/sbin/pfctl', '-a', $path, '-F', 'Tables');
    }
    for my $path (owned_anchors()) {
        for my $kind ('-sr', '-sn') {
            die "Mimo firewall rules remain in $path\n"
                if required(5, undef, '/sbin/pfctl', '-a', $path, $kind) =~ /\S/;
        }
    }
    print "MIMO_CLEANUP firewall_removed\n";
}

sub require_stopped_jobs {
    for my $label (qw(com.mimo.infrastructure com.mimo.pf-boot com.mimo.supervisor com.mimo.core com.mimo.mihomo)) {
        my ($status, $out, $err) = run_command(5, undef, '/bin/launchctl', 'print', "system/$label");
        die "Stop Mimo's services before network release: $label\n"
            unless $status == 113 && "$out$err" =~ /Could not find service/;
    }
}

sub verify_tailnet {
    my ($status, $route) = run_command(5, undef, '/sbin/route', '-n', 'get', '100.100.100.100');
    my ($interface) = $route =~ /^\s*interface:\s*(utun\d+)\s*$/m;
    if ($status || !defined $interface) {
        print "MIMO_CLEANUP tailnet_not_connected\n";
        return;
    }
    my $config = required(5, undef, '/sbin/ifconfig', $interface);
    my ($address) = $config =~ /^\s*inet\s+(100\.(?:\d{1,3}\.){2}\d{1,3})\s/m;
    if (!defined $address || (split /\./, $address)[1] < 64 || (split /\./, $address)[1] > 127) {
        print "MIMO_CLEANUP tailnet_not_connected\n";
        return;
    }
    # Reverse lookup of this Mac's native Tailscale address checks MagicDNS
    # without guessing a peer name or depending on a peer's SSH service.
    for my $attempt (1..3) {
        my ($result, $answer) = run_command(5, undef, '/usr/bin/dig', '@100.100.100.100', '-x', $address,
            '+tcp', '+time=2', '+tries=1', '+noall', '+comments', '+answer');
        if (!$result && $answer =~ /status: NOERROR/ && $answer =~ /\sIN\s+PTR\s+\S+\.ts\.net\./i) {
            print "MIMO_CLEANUP tailnet_verified\n";
            return;
        }
        sleep .3 if $attempt < 3;
    }
    print "MIMO_CLEANUP tailnet_failed\n";
    die "Mimo controls were removed, but native Tailnet DNS did not answer. Check Tailscale before claiming Tailnet restored. Recovery files retained.\n";
}

sub remove_owned_resolver {
    required(5, "remove $dns_key\nquit\n", '/usr/sbin/scutil');
    die "Mimo resolver is still present\n" unless
        required(5, "show $dns_key\nquit\n", '/usr/sbin/scutil') =~ /^\s*No such key\s*$/;
    print "MIMO_CLEANUP resolver_removed\n";
}

sub release_network {
    require_stopped_jobs();
    print "MIMO_CLEANUP services_stopped\n";
    clear_owned_firewall();
    remove_owned_resolver();
    release_references();
    restore_ipv6();
    required(5, undef, '/usr/bin/dscacheutil', '-flushcache');
    required(5, undef, '/usr/bin/killall', '-HUP', 'mDNSResponder');
    print "MIMO_CLEANUP dns_refreshed\n";
    # A stopped engine must not leave Mimo's tunnel route behind.
    my ($status, $tun) = run_command(5, undef, '/sbin/ifconfig', 'utun239');
    die "Mimo tunnel still exists after services stopped\n" if !$status && $tun =~ /inet 198\.18\./;
    verify_tailnet();
    require_stopped_jobs();
    for my $path (owned_anchors()) {
        die "Mimo rules returned during release\n" if required(5, undef, '/sbin/pfctl', '-a', $path, '-sr') =~ /\S/;
    }
    print "MIMO_CLEANUP network_released\n";
}

unless (caller) {
    die "Usage: sudo /usr/bin/perl release-network.pl\n" if @ARGV;
    die "Administrator authentication on macOS is required\n" unless $> == 0 && $^O eq 'darwin';
    umask 0077;
    $ENV{PATH} = '/usr/bin:/bin:/usr/sbin:/sbin'; $ENV{LC_ALL} = 'C';
    delete @ENV{qw(PERL5LIB PERL5OPT PERLLIB ENV BASH_ENV)};
    $| = 1;
    $SIG{TERM} = $SIG{INT} = sub { stop_child(); die "Network release interrupted; retry cleanup\n"; };
    for my $directory ('/Library', '/Library/Application Support', '/private/etc') { secure_path($directory, 1, 0); }
    secure_path($support, 1, 1);
    secure_path($pf_conf, 0, 0);
    for my $directory ("$support/Runtime", "$support/Guard") { secure_path($directory, 1, 1); }
    eval { release_network(); 1 } or do { stop_child(); die $@ || "Network release failed\n"; };
}
1;
