# Test-only immutable OS facts and a controllable scan duration. Actual run(),
# PF snapshot comparison, publication and top-level75/error dispatch are retained.
{
    no warnings 'redefine';
    my $clock = 0 + $ENV{HEALTH_TEST_START};
    my $duration = 0 + $ENV{HEALTH_TEST_DURATION};
    my $outcome = $ENV{HEALTH_TEST_OUTCOME};
    my $snapshot_reads = 0;
    *time = sub { $clock };
    *sleep = sub { $clock += $_[0] };
    *secure = sub {};
    *boot_id = sub { 'fixture' };
    *network_release_requested = sub { 0 };
    *configure = sub { 0 };
    *restore_file = sub { 0 };
    *repair_jobs = sub { 0 };
    *with_pf_mutation = sub { $_[0]->() };
    *pf_snapshot_identity = sub {
        ++$snapshot_reads;
        return [$outcome eq 'defer' && $snapshot_reads > 1 ? 'changed' : 'stable'];
    };
    *inspect_pf_snapshot = sub {
        $clock += $duration;
        die "Synthetic OS inspection failure\n" if $outcome eq 'failure';
        return {needs_block=>0,withdrawn=>0,reference_live=>1};
    };
    *required = sub { die "External command forbidden in isolated test\n" };
    *command = sub { die "External command forbidden in isolated test\n" };
    END {
        open my $f,'>',"$ENV{HEALTH_TEST_ROOT}/clock.json" or die $!;
        print $f encode_json({finished=>$clock}); close $f;
    }
}
