#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
require $ARGV[0];

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
done_testing();
