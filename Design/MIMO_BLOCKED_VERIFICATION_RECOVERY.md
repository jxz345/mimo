# Blocked verification recovery — build 10 regression and build 11 candidate

This record preserves the earlier unpublished build-11 candidate with paired
Dual-stack approval. The later IPv4-only approval revision uses the same
unpublished build number but different binary hashes; its current contract and
qualification are recorded in [the v3 plan](MIMO_3_0_PLAN.md). Do not apply the
older paired-request counts to the current candidate.

## Evidence before implementation changes

The reported sequence contained repeated check→block cycles and a stale-command
rejection, but no provider failure detail or explicit exit rejection. It does not
establish why the first HTTP request failed.

On unchanged 3.0 build 10, installed in `mimo-vm`:

1. A closed Delta fixture returned an exit outside the empty allowlist.
2. Three explicit checks while rejected reached the fixture and succeeded.
3. Editing the allowlist alone restored Rule access. No Direct transition or
   credential change was needed. Rejection alone did **not** reproduce a failed
   private probe in this environment.
4. After rejecting the exit again, a temporary fixture SOCKS outage caused a
   transport failure and a ten-minute cooldown.
5. The fixture was restored. An independent SOCKS+TLS request received the correct
   exit. The same session then approved the exit and requested Refresh.
6. Recovery failed: zero new provider requests, blocked routing and the message
   “No lookup ran. Providers are paused or out of budget…”. The observation
   including command overhead lasted 27.863 seconds. The same core process,
   Rule mode and fixture token remained throughout the fault and repair.
7. Incoming SSH/RFB still worked. Final cleanup restored original settings,
   proxy catalog and routing, and removed the disposable fixture credential.

The test exited nonzero at the recovery assertion. A second regression combining
the real `MonitoringEngine` with `MimoCoordinator` also failed: **one lookup sent
three close commands**, rather than one. These are two proven defects; a delayed
close interfering with a later private probe is a race to prevent, not a proven
explanation of the user's initial failure.

[Sanitized red evidence](../Tests/MihomoRuntimeTests/Evidence/v3/blocked-retry/build10-red.json)
includes the installed core hash. Raw state/fixture logs remain in owner-only
`.build/blocked-retry-build10-r4` and the disposable VM. Earlier harness runs
failed positive-control setup or encountered preexisting pauses; they are not
counted as reproductions. No production source had changed when the successful
red run was recorded.

## Why previous tests missed it

The 60 coordinator cases bypassed scheduler admission and persistent cooldowns.
The 22 installed exception cases repaired through Direct and replaced a fixture
token, which cleared its cooldown. Their passing results do not establish
same-session recovery. The new acceptance test does not change credentials,
clear stores/cooldowns, move the clock, restart services or select Direct between
fault and recovery. Setting a disposable fixture token before the baseline and
removing it after the final assertion are cleanup boundaries, not recovery steps.

## Candidate behavior

- Automatic local/transient failure backoff remains ten minutes. Explicit
  Refresh, provider Test or a verification-affecting settings repair may release
  one eligible local backoff. Continuing failures settle again; polling and
  automatic rotation cannot release paused providers.
- Server Retry-After, rate-limit/authentication refusals, unknown legacy pauses
  and daily budgets remain enforced. Recorded build-10 transport failures can be
  retried explicitly; they cannot contain a server Retry-After. Persistence of a
  new deadline and its retry classification is atomic in core-owned storage.
- Coordinator-owned failure closure is not repeated for scheduler `.failed`
  and `.coolingDown` presentation. Other necessary closes capture the current
  epoch before queuing; a newer check/configuration/Direct transition fences them.
- A close caused by a failed IP check retains that reason instead of always
  claiming the network/configuration changed. Application access still requires
  fresh approved observations; recovery does not bypass approval or open Direct.

## Diagnostic chain

Readable and JSON logs retain millisecond UTC timestamps, process role/PID and a
process-local record sequence. Each admitted check has a lookup ID; prepare and
approval link it to the supervisor verification ID and ordered command sequence,
configuration revision and network generation. Logs distinguish:

- requested, joined, admitted and deferred checks;
- actual HTTP budget charging or refusal before HTTP;
- IPv4/IPv6 private-probe/native requests, completion and elapsed time;
- core command send, supervisor receipt, reply, failure or supersession;
- provider failure category, local automatic backoff versus provider restriction,
  explicit local retry and skipped redundant closure;
- policy rejection versus successful verification.

Copy All includes source availability, so a missing core/supervisor response is
visible in a pasted report. Routine ignored AirPort telemetry remains in full
diagnostics but no longer fills the readable failure timeline. No proxy password,
provider token, probe secret or profile contents are added; existing diagnostic
IP redaction remains in force.

## Validation status

Before the fix: installed Rule/IPv4 recovery assertion failed and the combined
scheduler/coordinator close-count assertion failed. After the fix, 222 shared
tests and the service/app suites passed, including same-session local retry,
one-close regression, obsolete-notification fencing and preserved provider
restrictions. The log-checking script accepts old whole-second and new
millisecond timestamps and still rejects a deliberately late lookup.

Unpublished **3.0 build 11** was installed in `mimo-vm` and passed the same
installed recovery assertion in all four combinations:

| Mode | Family | Fresh provider HTTP requests after repair | Recovery including command overhead | HTTP 429 / Retry-After |
| --- | --- | ---: | ---: | --- |
| Rule | Strict IPv4 | 1 | 10.829 s | Enforced; no new HTTP and unchanged deadlines |
| Global | Strict IPv4 | 1 | 10.868 s | Enforced; no new HTTP and unchanged deadlines |
| Rule | Dual-stack | 2 | 10.854 s | Enforced; no new HTTP and unchanged deadlines |
| Global | Dual-stack | 2 | 10.807 s | Enforced; no new HTTP and unchanged deadlines |

Each case also passed three fresh checks while rejected, allowlist-only repair,
independent SOCKS/TLS proof of fixture recovery, and incoming SSH/RFB after
recovery. The mode, core instance and fixture token were unchanged between fault
and repair. No deadline/store edits, clock movement, service restart or Direct
escape were used. A subsequent real HTTP 429 with `Retry-After: 900` remained
blocked after Refresh, even with the fixture repaired.

The first candidate run exposed a harness comparison error: Swift's enum-keyed
cooldown dictionary was serialized as an array in a different order, with equal
deadlines. The comparison was corrected to compare mappings; all four cases were
then repeated. This was not an app fix or a relaxed deadline assertion.

Actual records from both daemons linked each of the four transport failures to
its lookup admission, private HTTP, preparation and one close command. All had
millisecond timestamps, process identity and record sequence. The disposable
fixture credential was absent from the captured diagnostics. A sanitized sample
chain, binary identity and results are saved in
[build11-green.json](../Tests/MihomoRuntimeTests/Evidence/v3/blocked-retry/build11-green.json).

Original settings, proxy catalog, credential presence and routing were restored;
all fixture processes stopped. The final original Rule/blocked state also
accepted fresh SSH/RFB connections. The previously trusted lab CA was retained
as requested. Build 11 remains unpublished. The trigger for the user's original
first private HTTP failure remains unproven; these results qualify the reproduced
recovery lockout and redundant-close fixes, not that initial trigger.
