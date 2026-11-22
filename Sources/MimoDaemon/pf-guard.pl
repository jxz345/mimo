#!/usr/bin/perl
# Independent boot protection and infrastructure repair. Uses only macOS tools
# and Perl's bundled modules; never executes mimo-core or mihomo directly.
use strict;
use warnings;
use Fcntl qw(:DEFAULT :flock :mode);
use POSIX qw(WNOHANG);
use JSON::PP;
use File::Temp qw(tempfile);
use Time::HiRes qw(time sleep);

my $support = '/Library/Application Support/Mimo';
my $runtime = "$support/Runtime";
my $guard = '/Library/Application Support/Mimo/Guard';
my $anchor = 'com.apple/000.mimo';
my $rules = '/etc/pf.anchors/com.mimo.boot';
my $configuration = '/etc/pf.conf';
my $supervisor = 'com.mimo.supervisor';
my $health = 'com.mimo.infrastructure';
my $boot = 'com.mimo.pf-boot';
my $begin = '# BEGIN MIMO BOOT GUARD';
my $end = '# END MIMO BOOT GUARD';
my $active_child;
my ($current_boot, $pf_healthy);
our $pf_mutation_held = 0;
our $pf_revoking = 0;

sub managed_configuration {
    my ($text, $install) = @_;
    my $starts = () = $text =~ /^\Q$begin\E$/mg;
    my $ends = () = $text =~ /^\Q$end\E$/mg;
    die "Malformed Mimo PF configuration markers\n" if $starts != $ends || $starts > 1;
    if ($starts) {
        $text =~ s/^\Q$begin\E\nload anchor "com\.apple\/000\.mimo" from "\/etc\/pf\.anchors\/com\.mimo\.boot"\n\Q$end\E\n?//m
            or die "Unexpected content in Mimo PF configuration block\n";
    }
    return $text unless $install;
    die "PF configuration lacks the application anchor\n" unless $text =~ /^\s*anchor\s+"com\.apple\/\*"/m;
    die "Conflicting persistent Mimo anchor\n" if $text =~ /^\s*load\s+anchor\s+"\Q$anchor\E"/m;
    $text .= "\n" unless $text =~ /\n\z/;
    return $text . "$begin\nload anchor \"$anchor\" from \"$rules\"\n$end\n";
}

sub secure {
    my ($path, $directory) = @_;
    my @s = lstat($path);
    die "Missing or unsafe infrastructure path: $path\n"
        unless @s && $s[4] == 0 && !($s[2] & 0022) &&
        ($directory ? S_ISDIR($s[2]) : S_ISREG($s[2]));
}

sub read_file {
    my ($path) = @_;
    secure($path, 0);
    open my $f, '<', $path or die "Cannot read $path\n";
    local $/;
    return <$f>;
}

sub atomic_write {
    my ($path, $data, $mode) = @_;
    # macOS owns /etc as a symlink to /private/etc. Use its fixed canonical
    # location rather than relaxing the no-symlink check on writable parents.
    $path =~ s{\A/etc/}{/private/etc/};
    secure($path, 0) if -e $path || -l $path;
    my ($directory) = $path =~ m{^(.*)/[^/]+$};
    secure($directory, 1);
    my ($f, $temporary) = tempfile('.mimo-XXXXXXXX', DIR => $directory, UNLINK => 0);
    eval {
        print {$f} $data or die "Cannot write infrastructure file\n";
        chmod($mode // 0600, $temporary) or die "Cannot protect infrastructure file\n";
        close($f) or die "Cannot finish infrastructure file\n";
        rename($temporary, $path) or die "Cannot replace infrastructure file\n";
    };
    my $error = $@;
    unlink $temporary if -e $temporary;
    die $error if $error;
}

# Separate output files avoid pipe backpressure; kill/reap the whole command
# group on timeout before releasing the firewall lock.
sub command {
    my ($limit, @arguments) = @_;
    # A routine scan keeps a coherent snapshot only while no revocation is
    # waiting. Yield at command boundaries, release mutation, and retry later.
    # A deferred scan must never publish a healthy result or clear repair state.
    die "MIMO_PF_DEFERRED\n" if $pf_mutation_held && !$pf_revoking && revocation_pending();
    my ($out, $out_path) = tempfile('.command-out-XXXXXXXX', DIR => $guard, UNLINK => 1);
    my ($err, $err_path) = tempfile('.command-err-XXXXXXXX', DIR => $guard, UNLINK => 1);
    my $pid = fork();
    die "Cannot launch system command\n" unless defined $pid;
    if (!$pid) {
        $SIG{TERM} = $SIG{INT} = 'DEFAULT';
        POSIX::setpgid(0, 0);
        open STDIN, '<', '/dev/null' or POSIX::_exit(125);
        open STDOUT, '>&', $out or POSIX::_exit(125);
        open STDERR, '>&', $err or POSIX::_exit(125);
        exec {$arguments[0]} @arguments or POSIX::_exit(127);
    }
    $active_child = $pid;
    my $deadline = time() + $limit;
    my $status;
    while (1) {
        my $result = waitpid($pid, WNOHANG);
        if ($result == $pid) { $status = $?; last; }
        die "Cannot wait for system command\n" if $result == -1;
        if (time() >= $deadline) {
            kill 'TERM', -$pid;
            sleep 0.1;
            kill 'KILL', -$pid;
            waitpid($pid, 0);
            $status = 124 << 8;
            last;
        }
        sleep 0.02;
    }
    $active_child = undef;
    seek($out, 0, 0); seek($err, 0, 0);
    local $/;
    my $output = <$out> // '';
    my $error = <$err> // '';
    return ($status & 127 ? 128 + ($status & 127) : $status >> 8, $output, $error);
}

sub required {
    my (@arguments) = @_;
    my ($status, $out) = command(4, @arguments);
    die "Infrastructure command failed: $arguments[0] ($status)\n" if $status;
    return $out;
}

sub boot_id {
    my $id = required('/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid');
    $id =~ s/\s+\z//;
    die "Invalid boot identifier\n" unless $id =~ /^[A-Fa-f0-9-]{36}$/;
    return $id;
}

sub main_rules_supported {
    my ($text) = @_;
    return $text =~ /^anchor "com\.apple\/\*"/m && $text !~ /^pass (?:out )?quick\b/m;
}

sub reference_live {
    my ($token, $text) = @_;
    return defined($token) && $token =~ /^\d{1,32}$/ && $text =~ /^\d+\s+\S+\s+\Q$token\E\s/m;
}

sub ensure_reference {
    my ($id) = @_;
    my $path = "$guard/pf-reference.json";
    my $reference = -e $path ? decode_json(read_file($path)) : {};
    my $info = required('/sbin/pfctl', '-s', 'info');
    my $references = required('/sbin/pfctl', '-s', 'References');
    die "Cannot inspect PF enable references\n" unless $references =~ /TOKENS:/ || $references =~ /^No pf starter references held\s*$/;
    my $live = ($reference->{boot} // '') eq $id && reference_live($reference->{token}, $references);
    return 0 if $live && $info =~ /Status: Enabled/;
    my ($status, $out, $err) = command(4, '/sbin/pfctl', '-E');
    my ($token) = "$out\n$err" =~ /Token\s*:\s*(\d{1,32})\b/;
    die "Cannot acquire independent PF enable reference\n" if $status || !defined $token;
    atomic_write($path, encode_json({boot => $id, token => $token}));
    if ($live) {
        required('/sbin/pfctl', '-X', $reference->{token});
    }
    return 1;
}

# Only snapshot capture/commit and actual repairs hold mutation. Slow PF reads
# run outside it; the common mutation token rejects overlapping Mimo writers.
sub revocation_pending {
    sysopen(my $priority, "$runtime/pf-revocation.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0600)
        or die "Cannot inspect PF revocation admission\n";
    return !flock($priority, LOCK_EX | LOCK_NB);
}

sub with_pf_mutation {
    my ($operation, $revoking, $writing) = @_;
    $writing = 1 unless defined $writing;
    return $operation->() if $pf_mutation_held;
    sysopen(my $mutation, "$runtime/pf-mutation.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0600)
        or die "Cannot open PF mutation lock\n";
    sysopen(my $priority, "$runtime/pf-revocation.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0600)
        or die "Cannot open PF revocation admission\n";
    if ($revoking) {
        my $deadline = time() + 60;
        until (flock($priority, LOCK_EX | LOCK_NB)) {
            die "PF revocation admission is busy\n" if time() >= $deadline;
            sleep 0.01;
        }
        $deadline = time() + 30;
        until (flock($mutation, LOCK_EX | LOCK_NB)) {
            die "PF mutation is busy\n" if time() >= $deadline;
            sleep 0.01;
        }
    } else {
        my $deadline = time() + 5;
        while (1) {
            if (flock($priority, LOCK_EX | LOCK_NB)) {
                my $acquired = flock($mutation, LOCK_EX | LOCK_NB);
                flock($priority, LOCK_UN) or die "Cannot release PF admission\n";
                last if $acquired;
            }
            die "MIMO_PF_DEFERRED\n" if time() >= $deadline;
            sleep 0.01;
        }
    }
    local $pf_mutation_held = 1;
    local $pf_revoking = $revoking // 0;
    stamp_mutation() if $writing;
    return $operation->();
}

sub stamp_mutation {
    open my $random, '<', '/dev/urandom' or die "Cannot create PF mutation token\n";
    my $bytes;
    read($random, $bytes, 16) == 16 or die "Cannot read PF mutation token\n";
    atomic_write("$runtime/pf-mutation.epoch", unpack('H*', $bytes));
}

sub pf_snapshot_identity {
    return [map { -e $_ ? read_file($_) : undef }
        ("$runtime/pf-mutation.epoch", "$runtime/gate.state", "$runtime/guard.expected",
         "$runtime/probe-policy.expected", "$runtime/open-policy.expected", "$guard/pf-reference.json")];
}

sub inspect_pf_snapshot {
    my ($snapshot, $id) = @_;
    my ($epoch, $state, $expected, $probe, $final, $reference) = @$snapshot;
    $state //= '';
    my $main = required('/sbin/pfctl', '-sr');
    my $live = required('/sbin/pfctl', '-a', $anchor, '-sr');
    my $info = required('/sbin/pfctl', '-s', 'info');
    my $children_valid = 1;
    my $withdrawn = 0;
    if ($state eq 'active') {
        # Active routing belongs exclusively to the profile. The sole parent
        # reference is passive unless an independent transition closes it.
        $children_valid = 0 unless $live =~ /^anchor "power-guard" out quick all\s*$/;
        my $barrier = required('/sbin/pfctl', '-a', "$anchor/power-guard", '-sr');
        if ($barrier =~ /\S/) { $withdrawn = 1; $state = 'blocked'; }
    }
    $children_valid = 0 if $state eq 'direct' && $live =~ /\S/;
    if ($live =~ /^anchor "permission"/m) {
        for my $child (['probe-policy', $probe], ['open-policy', $final]) {
            my $actual = required('/sbin/pfctl', '-a', $anchor . '/' . $child->[0], '-sr');
            $children_valid = 0 unless defined($child->[1]) && $actual eq $child->[1];
        }
        if ($state eq 'active') {
            my $grant = required('/sbin/pfctl', '-a', "$anchor/permission", '-sr');
            if ($grant =~ /^\s*$/) {
                $withdrawn = 1;
                $state = 'blocked';
            } else {
                $children_valid = 0 unless $grant =~ /^anchor "(?:[^"\n]*\/)?open-policy" out quick all\s*$/;
            }
        }
    }
    my $references = required('/sbin/pfctl', '-s', 'References');
    die "Cannot inspect PF enable references\n" unless $references =~ /TOKENS:/ || $references =~ /^No pf starter references held\s*$/;
    my $saved = defined($reference) ? decode_json($reference) : {};
    return {
        needs_block => $info !~ /Status: Enabled/ || !main_rules_supported($main) ||
            $state !~ /^(?:blocked|active|direct)$/ || !$children_valid || !defined($expected) || $live ne $expected,
        withdrawn => $withdrawn,
        reference_live => ($saved->{boot} // '') eq $id && reference_live($saved->{token}, $references)
    };
}

sub close_gate {
    my ($id) = @_;
    return with_pf_mutation(sub { close_gate_locked($id); }, 1);
}

sub close_gate_locked {
    my ($id) = @_;
    $pf_healthy = 0;
    atomic_write("$runtime/gate.state", 'pending');
    secure($rules, 0);
    required('/sbin/pfctl', '-n', '-a', $anchor, '-f', $rules);
    my $main = required('/sbin/pfctl', '-sr');
    if (!main_rules_supported($main)) {
        # Restore the saved administrator configuration, including our boot
        # anchor. Never generate a replacement root ruleset from scratch.
        required('/sbin/pfctl', '-n', '-f', $configuration);
        required('/sbin/pfctl', '-f', $configuration);
        $main = required('/sbin/pfctl', '-sr');
        die "The saved PF ruleset bypasses Mimo's anchor\n" unless main_rules_supported($main);
    }
    required('/sbin/pfctl', '-a', $anchor, '-f', $rules);
    ensure_reference($id);
    required('/sbin/pfctl', '-k', '0.0.0.0/0');
    required('/sbin/pfctl', '-k', '::/0');
    my $actual = required('/sbin/pfctl', '-a', $anchor, '-sr');
    die "Independent blocking anchor is empty\n" unless $actual =~ /^block drop out quick all label "mimo:transition:deny"$/m;
    atomic_write("$runtime/guard.expected", $actual);
    atomic_write("$runtime/gate.state", 'blocked');
    $pf_healthy = 1;
}

sub restore_file {
    my ($source, $destination, $mode) = @_;
    my $expected = read_file($source);
    return 0 if -e $destination && read_file($destination) eq $expected;
    atomic_write($destination, $expected, $mode);
    return 1;
}

sub configure {
    my $original = read_file($configuration);
    my $updated = managed_configuration($original, 1);
    return 0 if $updated eq $original;
    my ($f, $candidate) = tempfile('.pf-check-XXXXXXXX', DIR => $guard, UNLINK => 1);
    print {$f} $updated; close $f;
    required('/sbin/pfctl', '-n', '-f', $candidate);
    atomic_write($configuration, $updated, 0644);
    return 1;
}

sub inspect_job {
    my ($label) = @_;
    my ($status, $out, $error) = command(4, '/bin/launchctl', 'print', "system/$label");
    return undef if $status == 113 && "$out$error" =~ /Could not find service/;
    die "Cannot inspect launchd job $label\n" if $status;
    return $out;
}

sub job_matches {
    my ($text, $path, $program, $argument, $keepalive) = @_;
    return 0 unless $text =~ /^\s*path = \Q$path\E$/m && $text =~ /^\s*program = \Q$program\E$/m;
    my ($arguments) = $text =~ /^\s*arguments = \{\n(.*?)^\s*\}/ms;
    return 0 unless defined $arguments;
    my @actual = grep { length } map { s/^\s+|\s+$//gr } split /\n/, $arguments;
    my @expected = ($program);
    push @expected, "$guard/pf-guard.pl" if $program eq '/usr/bin/perl';
    push @expected, $argument if defined $argument;
    return 0 unless join("\0", @actual) eq join("\0", @expected);
    return 0 unless $text =~ /^\s*properties = .*\brunatload\b/m;
    return 0 if $keepalive && $text !~ /^\s*properties = .*\bkeepalive\b/m;
    return 1;
}

sub begin_job_repair {
    my ($id) = @_;
    with_pf_mutation(sub {
        atomic_write("$runtime/infrastructure-repair", $id);
        close_gate_locked($id);
    }, 1);
}

sub repair_jobs {
    my ($id, $released) = @_;
    my $preferences = decode_json(read_file("$runtime/services.json"));
    for my $key ('core', 'engine') {
        die "Invalid saved service intent\n" unless exists($preferences->{$key}) && JSON::PP::is_bool($preferences->{$key});
    }
    my @jobs = (
        [$boot, "/Library/LaunchDaemons/$boot.plist", '/usr/bin/perl', '--boot', 0, 1],
        [$health, "/Library/LaunchDaemons/$health.plist", '/usr/bin/perl', '--check', 0, 1],
        [$supervisor, "/Library/LaunchDaemons/$supervisor.plist", '/Library/PrivilegedHelperTools/mimo-core', '--supervisor', 1, 1],
        ['com.mimo.mihomo', "$support/LaunchDaemons/com.mimo.mihomo.plist", '/Library/PrivilegedHelperTools/mimo-core', '--engine', 1, $preferences->{engine}],
        ['com.mimo.core', "$support/LaunchDaemons/com.mimo.core.plist", '/Library/PrivilegedHelperTools/mimo-core', undef, 1, $preferences->{core}]
    );
    my $disabled = required('/bin/launchctl', 'print-disabled', 'system');
    my $changed = 0;
    for my $job (@jobs) {
        my ($label, $path, $program, $argument, $keepalive, $wanted) = @$job;
        if ($wanted && !(eval { secure($program, 0); -x $program })) {
            begin_job_repair($id) unless $released;
            die "Missing or unsafe executable for launchd job $label; repair installation\n";
        }
        my $file_changed = restore_file("$guard/$label.plist", $path, 0644);
        my $state = inspect_job($label);
        my $wrong = defined($state) && (!job_matches($state, $path, $program, $argument, $keepalive) || $file_changed);
        my $is_disabled = $disabled =~ /"\Q$label\E"\s*=>\s*(?:true|disabled)\b/;
        my $not_running = $keepalive && defined($state) && $state !~ /^\s*state = running$/m;
        next if !$file_changed && ($wanted ? defined($state) && !$wrong && !$is_disabled && !$not_running : !defined($state));
        # A launchd repair never restores active permissions. Supervision must
        # recover and perform a new verification; Direct can recover normally.
        begin_job_repair($id) unless $changed || $released;
        if (defined($state) && (!$wanted || $wrong)) { required('/bin/launchctl', 'bootout', "system/$label"); $state = undef; }
        if ($wanted) {
            required('/bin/launchctl', 'enable', "system/$label");
            required('/bin/launchctl', 'bootstrap', 'system', $path) unless defined $state;
            if (defined($state) && $not_running) {
                my ($status) = command(4, '/bin/launchctl', 'kickstart', "system/$label");
                my $after = inspect_job($label);
                die "Cannot restart launchd job $label\n" if !defined($after) || $after !~ /^\s*state = running$/m;
            }
        }
        ++$changed;
        print STDERR "mimo_launchd_repaired label=$label enabled=" . ($wanted ? 'true' : 'false') . "\n";
    }
    return $changed;
}

sub network_release_requested {
    return 0 unless -e "$runtime/services.json";
    return release_intent(decode_json(read_file("$runtime/services.json")));
}

sub release_intent {
    my ($intent) = @_;
    return 0 unless exists $intent->{releaseNetwork};
    die "Invalid network release intent\n" unless JSON::PP::is_bool($intent->{releaseNetwork});
    die "Invalid released engine intent\n" if $intent->{releaseNetwork} &&
        (!JSON::PP::is_bool($intent->{engine}) || $intent->{engine});
    return $intent->{releaseNetwork} ? 1 : 0;
}

sub run {
    my ($operation) = @_;
    die "Usage: pf-guard.pl --boot | --check | --configure | --remove\n" unless defined($operation) && $operation =~ /^--(?:boot|check|configure|remove)$/;
    die "Administrator authentication is required\n" unless $> == 0;
    umask 0077;
    $ENV{PATH} = '/usr/bin:/bin:/usr/sbin:/sbin';
    $ENV{LC_ALL} = 'C';
    delete @ENV{qw(PERL5LIB PERL5OPT PERLLIB ENV BASH_ENV)};
    $SIG{TERM} = $SIG{INT} = sub {
        if (defined $active_child) { kill 'KILL', -$active_child; waitpid($active_child, 0); $active_child = undef; }
        die "Infrastructure check interrupted\n";
    };
    for my $directory ($support, $runtime, '/Library/Application Support/Mimo', $guard, '/Library/LaunchDaemons') { secure($directory, 1); }
    # Match Swift's flock and never unlink this inode. Release automatically on
    # process death. No PF state is inspected halfway through a Mimo transition.
    sysopen(my $lock, "$runtime/firewall.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0600) or die "Cannot open firewall lock\n";
    my $deadline = time() + 12;
    until (flock($lock, LOCK_EX | LOCK_NB)) { die "Firewall is busy\n" if time() >= $deadline; sleep 0.05; }
    if ($operation eq '--configure') {
        if (network_release_requested()) { atomic_write($configuration, managed_configuration(read_file($configuration), 0), 0644); }
        else { configure(); }
        return;
    }
    my $id = boot_id();
    $current_boot = $id;
    if ($operation eq '--remove') {
        atomic_write($configuration, managed_configuration(read_file($configuration), 0), 0644);
        my $path = "$guard/pf-reference.json";
        if (-e $path) {
            my $reference = decode_json(read_file($path));
            my $references = required('/sbin/pfctl', '-s', 'References');
            die "Cannot inspect PF enable references\n" unless $references =~ /TOKENS:/ || $references =~ /^No pf starter references held\s*$/;
            required('/sbin/pfctl', '-X', $reference->{token}) if ($reference->{boot} // '') eq $id && reference_live($reference->{token}, $references);
            unlink($path) or die "Cannot remove independent PF reference\n";
        }
        return;
    }
    # An explicit Stop relinquishes network enforcement across boots and repairs.
    # Keep control services repairable without acquiring PF or a traffic barrier.
    if (network_release_requested()) {
        atomic_write($configuration, managed_configuration(read_file($configuration), 0), 0644);
        return if $operation eq '--boot' || -e "$runtime/maintenance";
        my $changed = repair_jobs($id, 1);
        my $policy = required('/sbin/pfctl', '-a', $anchor, '-sr');
        atomic_write("$guard/health.json", encode_json({boot => $id, checkedAt => time(),
            status => 'healthy', pf => $policy =~ /\S/ ? 'unavailable' : 'released', launchd => 'healthy'}));
        print "repaired\n" if $changed;
        return;
    }
    my $fresh = -e "$guard/boot.id" && read_file("$guard/boot.id") eq $id;
    if (!$fresh) {
        restore_file("$guard/blocking.pf", $rules, 0644);
        configure();
        close_gate($id);
        atomic_write("$guard/boot.id", $id);
        print STDERR "mimo_independent_boot_guard_closed boot=$id\n";
    }
    return if $operation eq '--boot' || -e "$runtime/maintenance";
    my $changed = restore_file("$guard/blocking.pf", $rules, 0644) + configure();
    my $observed_at = time();
    my $snapshot = with_pf_mutation(sub { pf_snapshot_identity(); }, 0, 0);
    print STDERR "mimo_pf_scan_started mutation_lock=not_held\n";
    my $observation = inspect_pf_snapshot($snapshot, $id);
    print STDERR "mimo_pf_scan_finished mutation_lock=not_held\n";
    with_pf_mutation(sub {
        # Token + expected-file checks catch an ABA state change or a writer
        # that died mid-transaction. Never repair/publish a mixed snapshot.
        die "MIMO_PF_DEFERRED\n" unless encode_json($snapshot) eq encode_json(pf_snapshot_identity());
        if ($observation->{needs_block}) {
            stamp_mutation();
            close_gate_locked($id);
            ++$changed;
            print STDERR "mimo_pf_repaired action=blocked\n";
        } else {
            if ($observation->{withdrawn}) {
                stamp_mutation();
                atomic_write("$runtime/gate.state", 'blocked');
            }
            if (!$observation->{reference_live}) {
                stamp_mutation();
                $changed += ensure_reference($id);
            }
        }
        $pf_healthy = 1;
    }, 0, 0);
    $changed += repair_jobs($id);
    # All job changes have finished under the lifecycle lock. Clear only after
    # a healthy scan; a killed/failed checker leaves opening inhibited until
    # the next successful scan. No routine scan creates this marker.
    if (-e "$runtime/infrastructure-repair") {
        with_pf_mutation(sub {
            unlink("$runtime/infrastructure-repair") or die "Cannot clear repair marker\n"
                if -e "$runtime/infrastructure-repair";
        });
    }
    atomic_write("$guard/health.json", encode_json({boot => $id, checkedAt => $observed_at, repaired => $changed, status => 'healthy', pf => 'enabled', launchd => 'healthy'}));
    print "repaired\n" if $changed;
}

unless (caller) {
    eval { die "One operation is required\n" unless @ARGV == 1; run($ARGV[0]); };
    if ($@) {
        my $error = $@;
        if ($error =~ /^MIMO_PF_DEFERRED\b/) {
            print STDERR "mimo_infrastructure_deferred reason=pf_snapshot_changed_or_revocation\n";
            exit 75;
        }
        if (($ARGV[0] // '') eq '--check' && defined $current_boot) {
            eval { atomic_write("$guard/health.json", encode_json({boot => $current_boot, checkedAt => time(), status => 'failed', pf => $pf_healthy ? 'enabled' : 'unavailable', launchd => 'unavailable'})); };
        }
        print STDERR "mimo_infrastructure_failed $error";
        exit 1;
    }
}
1;
