#!/usr/bin/perl
# Emergency recovery for an incomplete Mimo 1 uninstall. Stock macOS Perl only.
# Default: inspect. --apply: preview, local confirmation, scoped removal.
# Never disable PF globally, reload its root rules, or stop another VPN's engine.
use strict;
use warnings;
use Fcntl qw(:DEFAULT :mode);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir tempfile);
use IO::Select;
use IO::Handle;
use JSON::PP qw(decode_json);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);

our $support = '/Library/Application Support/Mimo';
our $helper = '/Library/PrivilegedHelperTools/mimo-core';
our $pf_conf = '/private/etc/pf.conf';
our $anchor = 'com.apple/000.mimo';
our $dns_key = 'State:/Network/Service/com.mimo.dns/DNS';
our @labels = qw(com.mimo.infrastructure com.mimo.pf-boot com.mimo.supervisor com.mimo.core com.mimo.mihomo);
our @legacy = qw(com.example.exitipmonitor.tailscale-verge com.example.exitipmonitor.tailscale-verge-http);
our ($active_child, $recovery);

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

sub job_state {
    my ($label) = @_;
    my ($status, $out, $err) = run_command(5, undef, '/bin/launchctl', 'print', "system/$label");
    return $out if !$status;
    return undef if $status == 113 && "$out$err" =~ /Could not find service/;
    die "Cannot inspect system/$label ($status): $err$out\n";
}

sub processes {
    my $table = required(5, undef, '/bin/ps', '-axww', '-o', 'pid=,command=');
    my (@workers, @guis);
    for my $line (split /\n/, $table) {
        next unless $line =~ /^\s*(\d+)\s+(.+)$/;
        my ($pid, $command) = ($1, $2);
        if ($command =~ m{^/Library/PrivilegedHelperTools/(?:mimo-core|com\.mimo\.core)(?:\s|$)}
            || $command =~ /^\Q$support\E\/Runtime\/mihomo(?:\s|$)/
            || $command =~ m{^/usr/bin/perl(?:5\.[\d.]+)?\s+\Q$support\E/Guard/pf-guard\.pl(?:\s|$)}
            || $command =~ m{^/bin/bash\s+\Q$support\E/tailscale-verge\.sh\s+(?:monitor|http)(?:\s|$)}) {
            push @workers, $pid;
        }
        push @guis, $pid if $command =~ m{^/.*/(?:Mimo|ExitIPMonitor)\.app/Contents/MacOS/(?:mimo-gui|ExitIPMonitor)(?:\s|$)};
    }
    return (\@workers, \@guis);
}

sub wait_for_workers {
    my $deadline = time() + 45;
    while (1) {
        my ($workers, $guis) = processes();
        die "A Mimo GUI is running (PID @{$guis}); quit it before continuing\n" if @$guis;
        return unless @$workers;
        die "Mimo workers did not exit (PID @{$workers}); no firewall/DNS cleanup attempted\n" if time() >= $deadline;
        sleep .2;
    }
}

sub stop_jobs {
    my ($jobs) = @_;
    required(5, undef, '/bin/launchctl', 'disable', "system/$_") for @$jobs;
    for my $label (@$jobs) {
        required(15, undef, '/bin/launchctl', 'bootout', "system/$label") if defined job_state($label);
    }
    wait_for_workers();
    # No repair writer remains to undo these final disable overrides.
    for my $label (@$jobs) {
        required(5, undef, '/bin/launchctl', 'disable', "system/$label");
        die "Job returned during shutdown: $label\n" if defined job_state($label);
    }
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

sub clear_network_policy {
    my ($original, $candidate) = @_;
    remove_boot_block($original, $candidate);
    if (anchor_present()) {
        required(5, undef, '/sbin/pfctl', '-a', $anchor, '-F', 'rules');
        my $rules = required(5, undef, '/sbin/pfctl', '-a', $anchor, '-sr');
        die "Mimo parent anchor still contains rules\n" if $rules =~ /\S/;
    }
    required(5, "remove $dns_key\nquit\n", '/usr/sbin/scutil');
    my $dns = required(5, "show $dns_key\nquit\n", '/usr/sbin/scutil');
    die "Mimo resolver is still present or cannot be inspected\n" unless $dns =~ /^\s*No such key\s*$/;
    required(5, undef, '/usr/bin/dscacheutil', '-flushcache');
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
        warn "PF reference left for manual review ($relative): $@" unless $ok;
    }
}

sub restore_ipv6 {
    my $journal = "$support/Runtime/ipv6-original.plist";
    if (!-e $journal) {
        die "IPv6 apply journal remains without original settings; retain files and use manual recovery\n"
            if -e "$support/Runtime/ipv6-apply-pending";
        print "No saved IPv6 journal remains; previous IPv6 settings cannot be inferred. Check Network settings.\n";
        return;
    }
    secure_path($journal, 0, 0);
    secure_path($helper, 0, 0);
    required(20, undef, '/usr/bin/codesign', '--verify', '--strict', $helper);
    required(20, undef, $helper, '--restore-ipv6-preferences');
    die "IPv6 restoration did not finish; original files retained\n"
        if -e $journal || -e "$support/Runtime/ipv6-apply-pending";
}

sub component_paths {
    my ($jobs) = @_;
    return (
        (map { "/Library/LaunchDaemons/$_.plist" } @$jobs),
        (map { "$support/$_" } qw(LaunchDaemons LaunchHelpers Guard Runtime Mihomo TailscaleVerge)),
        (map { "$support/$_" } qw(installed-app app.cdhash command-support.sh cleanup-installation.sh tailscale-verge.sh)),
        '/Library/PrivilegedHelperTools/mimo-core', '/Library/PrivilegedHelperTools/com.mimo.core',
        '/Library/PrivilegedHelperTools/mimo-manage', '/Library/PrivilegedHelperTools/MimoUninstaller.app',
        '/Library/PrivilegedHelperTools/com.example.exitipmonitor.manage',
        '/private/etc/pf.anchors/com.mimo.boot', '/private/etc/sudoers.d/mimo-service',
        '/private/etc/sudoers.d/mimo-tailscale-verge', '/private/etc/sudoers.d/exitipmonitor-service'
    );
}

sub archive_components {
    my ($paths) = @_;
    for my $path (@$paths) {
        next unless -e $path || -l $path;
        secure_path($path, -d $path ? 1 : 0, 0);
        my $target = "$recovery/removed$path";
        die "Backup destination already exists: $target\n" if -e $target || -l $target;
        make_path(dirname($target), {mode => 0700});
        required(20, undef, '/bin/mv', $path, $target);
    }
}

sub backup_records {
    $recovery = tempdir('mimo-recovery.XXXXXXXX', DIR => '/var/root', CLEANUP => 0);
    print "Recovery files: $recovery\n";
    copy($pf_conf, "$recovery/pf.conf") or die "Cannot back up pf.conf: $!\n";
    for my $relative ('Runtime/ipv6-original.plist', 'Runtime/ipv6-apply-pending', 'Runtime/pf-reference.json', 'Guard/pf-reference.json') {
        my $path = "$support/$relative";
        next unless -e $path;
        secure_path($path, 0, 0);
        make_path(dirname("$recovery/records/$relative"), {mode => 0700});
        copy($path, "$recovery/records/$relative") or die "Cannot back up $relative: $!\n";
    }
}

sub apply_recovery {
    my ($context) = @_;
    backup_records();
    print "Stopping Mimo jobs and waiting for their workers...\n";
    stop_jobs($context->{jobs});
    print "Removing Mimo's boot block, live PF rules and resolver...\n";
    clear_network_policy($context->{original}, $context->{candidate});
    release_references();
    print "Restoring saved IPv6 flags...\n";
    restore_ipv6();
    wait_for_workers();
    for my $label (@{$context->{jobs}}) {
        die "Job returned before archiving: $label\n" if defined job_state($label);
    }
    die "Mimo PF rules returned before archiving\n" if anchor_present()
        && required(5, undef, '/sbin/pfctl', '-a', $anchor, '-sr') =~ /\S/;
    die "Mimo DNS override returned before archiving\n" unless
        required(5, "show $dns_key\nquit\n", '/usr/sbin/scutil') =~ /^\s*No such key\s*$/;
    archive_components($context->{paths});
}

sub inspect {
    for my $path ('/Library', '/Library/Application Support', '/Library/PrivilegedHelperTools',
                  '/Library/LaunchDaemons', '/private/etc', '/private/var/root') {
        secure_path($path, 1, 0);
    }
    secure_path($support, 1, 1);
    secure_path($pf_conf, 0, 0);
    my $original = read_file($pf_conf);
    my $candidate = without_boot_block($original);
    my @jobs = @labels;
    for my $label (@legacy) {
        push @jobs, $label if -e "/Library/LaunchDaemons/$label.plist" || defined job_state($label);
    }
    my @paths = component_paths(\@jobs);
    my $found = $original ne $candidate;
    for my $path (@paths) {
        next unless -e $path || -l $path;
        secure_path(dirname($path), 1, 0);
        secure_path($path, -d $path ? 1 : 0, 0);
        $found = 1;
    }
    print 'Mac: ', required(5, undef, '/bin/hostname');
    print "Mimo system jobs:\n";
    for my $label (@jobs) {
        my $state = job_state($label);
        $found = 1 if defined $state;
        printf "  %s: %s\n", $label, defined($state) ? 'loaded' : 'absent';
    }
    my ($workers, $guis) = processes();
    print 'Mimo worker PIDs: ', (@$workers ? join(', ', @$workers) : 'none'), "\n";
    print 'Mimo GUI PIDs: ', (@$guis ? join(', ', @$guis) : 'none'), "\n";
    my $present = anchor_present();
    my $dns = required(5, "show $dns_key\nquit\n", '/usr/sbin/scutil');
    my $dns_absent = $dns =~ /^\s*No such key\s*$/;
    die "Cannot interpret DNS inspection\n" unless $dns_absent || $dns =~ /<dictionary>/;
    $found ||= $present || !$dns_absent || @$workers;
    printf "Mimo PF anchor: %s; DNS override: %s\n", $present ? 'present' : 'absent', $dns_absent ? 'absent' : 'present';
    validate_pf_candidate($candidate);
    return {original => $original, candidate => $candidate, jobs => \@jobs, paths => \@paths,
            found => $found, guis => $guis};
}

sub main {
    die "Usage: sudo /usr/bin/perl cleanup-mimo-v1.pl [--check | --apply]\n" if @ARGV > 1
        || (@ARGV && $ARGV[0] !~ /^--(?:check|apply|help)$/);
    if (@ARGV && $ARGV[0] eq '--help') {
        print "Usage: sudo /usr/bin/perl cleanup-mimo-v1.pl [--check | --apply]\n",
            "Default --check inspects only. --apply requires local typed confirmation.\n",
            "Quit Mimo in every account first. No app build, install, global PF reset or VPN takeover.\n";
        return;
    }
    die "Run on the affected Mac with sudo\n" unless $> == 0 && $^O eq 'darwin';
    umask 0077;
    $ENV{PATH} = '/usr/bin:/bin:/usr/sbin:/sbin';
    $ENV{LC_ALL} = 'C';
    delete @ENV{qw(PERL5LIB PERL5OPT PERLLIB ENV BASH_ENV)};
    $| = 1;
    local $SIG{INT} = local $SIG{TERM} = sub { stop_child(); die "Interrupted; completed recovery steps are not rolled back\n"; };
    my $context = inspect();
    if (!$context->{found}) { print "No Mimo service/network components found; nothing to remove.\n"; return; }
    print "\nApply will stop/disable these jobs, remove only Mimo's PF/DNS policy, restore saved IPv6 flags,\n",
        "and archive Mimo helpers/runtime/startup files under /var/root/mimo-recovery.*.\n",
        "It retains the app, Homebrew receipt, per-account login entries, private group/authorization right,\n",
        "machine settings, Keychain credentials and logs. Finish those separately using README.md.\n";
    if (!@ARGV || $ARGV[0] eq '--check') { print "CHECK ONLY: no services or network settings changed.\n"; return; }
    die "Quit all Mimo GUIs first (PID @{$context->{guis}}); no changes made\n" if @{$context->{guis}};
    open my $tty, '+<', '/dev/tty' or die "Apply requires an interactive Terminal\n";
    $tty->autoflush(1);
    print {$tty} "Type REMOVE MIMO to continue on this Mac: ";
    my $answer = <$tty> // '';
    close $tty;
    die "Cancelled; no changes made\n" unless $answer eq "REMOVE MIMO\n";
    # Recheck after the user has read the preview; no stale configuration snapshot.
    $context = inspect();
    die "A Mimo GUI started; quit it and retry\n" if @{$context->{guis}};
    apply_recovery($context);
    print "\nMimo jobs, firewall policy and resolver removed; installed components archived.\n",
        "Backup: $recovery (root-private; may contain generated credentials).\n",
        "Test DNS/internet access, finish app/login/package cleanup, then verify after reboot.\n",
        "Keep the backup until recovery is confirmed. Re-enable Mimo job labels only for a deliberate reinstall.\n";
}

unless (caller) {
    my $ok = eval { main(); 1 };
    if (!$ok) {
        stop_child();
        warn $@ || "Cleanup failed\n";
        warn "Recovery files retained at $recovery; no automatic rollback or service restart.\n" if defined $recovery;
        exit 1;
    }
}
1;
