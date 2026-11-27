# Log rotation and retention — 26 November 2026

## Problem reproduced before changing the logger

The old logger created one file at launch and appended indefinitely. Cleanup ran
only when diagnostics preferences were first configured or changed, and did not
include launchd output. A standalone fixture wrote 450 diagnostic events with
16-KiB fields: the active file reached **7,454,032 bytes**, failing the proposed
5-MiB maximum. This fixture used a private temporary directory, not user logs.
The original output is retained locally in `.build/log-retention/before-result.txt`.

## Implemented policy

| Storage | Policy |
| --- | --- |
| `runtime-*.jsonl` | Rotate before a write exceeds 5 MiB, and on the first write of a new UTC day; unique time/PID/UUID names. Trim older oversized files to recent complete lines. |
| Machine/account directory | 64 MiB and 128 managed log files, oldest segments evicted first. Enforced on runtime rotation and scheduled maintenance. |
| Age | Modification-time expiry, 7 days by default; existing 1/7/30-day preference respected. Size/count eviction can remove younger logs. |
| Schedule | Startup, changed diagnostic preferences, and every 60 seconds with 5-second leeway on a utility queue; no main-run-loop dependency. |
| `core.log`, `supervisor.log`, `engine.log`, `infrastructure.log` | If oversized, archive at most the newest 5 MiB of whole lines and truncate the original inode; expired inactive contents are cleared. |
| `installation.jsonl` | Existing 256-KiB rolling journal remains; expired contents are truncated under the journal writer's lock, with age rechecked after taking the lock. |
| `launch-*.json` | Only expire stale markers. Current readiness markers are not size-budget eviction targets. |
| In-memory disk backlog | At most 1,024 pending records / 2 MiB; overflow is counted, rather than blocking network/UI event producers or growing the queue indefinitely. |

The machine directory is `/Library/Logs/Mimo`. Each account independently manages
`~/Library/Application Support/Mimo/Logs`; this is not one aggregate multi-user
64-MiB quota. The core/supervisor executable owns system cleanup without GUI help,
reading shared retention settings without RPC. Released GUI monitoring applies
its remembered diagnostic preferences. No extra launchd job is introduced.

Runtime writing and pruning share a directory lock across processes. A writer
reopens its segment each time and starts a new one if another writer evicted it.
The concurrent-start test exposed an intermittent `ENOENT` opening a newly
created shared lock; exclusive creation followed by reopening the winner handles
that startup race with bounded retries. The lock file is never pruned.

Directory ownership/permissions, regular file type, link count, and no-symlink
opens are checked. Only recognized Mimo filenames are eligible; unrelated files,
exports, macOS Unified Logging, symlinks and hard links remain untouched. Live
heartbeat markers and the small coordination lock are excluded from the budget.

## Ordering and limits

The logger assigns timestamp/sequence and updates bounded in-memory diagnostics
before enqueueing disk work. Rotation/cleanup do not call a provider, XPC,
firewall, DNS, profile reload or service restart. The same behavior applies in
Direct and active/blocked Rule/Global. Normal process exit/engine exec drains
queued records; abrupt crashes can lose queued records.

launchd/engine stdout writers do not take the cooperative lock. In-place
truncation preserves their open descriptor, but bytes written during the copy /
truncate window can be lost. They can exceed 5 MiB or the directory budget
between sweeps; these are maintenance bounds, not a kernel quota. An oversized
legacy file may lose its old prefix. Retention prefers bounded storage to
complete historical capture during a flood. Cleanup failure leaves in-memory
diagnostics available and retries at the next sweep, without changing routing.

`mimo_log_maintenance` records rotation, deletion, truncation, removed-byte,
queue-drop and write-failure counts; `mimo_log_maintenance_failed` reports storage
unavailability without paths or private contents. Idle successful sweeps emit
nothing. These messages are formatted in Event Log and included in diagnostics.
Stop/uninstall retains logs and stops the processes/timers; age cleanup resumes
on the next Mimo launch, rather than leaving a cleanup daemon installed.

## Validation

The dashboard core-log viewer uses the existing bounded diagnostic buffers and
does not create another disk log. Both existing `mimo-core` roles instantiate
`MimoLogStore(serviceOutputs: true)` and own their existing maintenance timers;
merging the former Perl jobs does not remove scheduled retention. New regression
coverage explicitly rotates `core.log`, `supervisor.log`, `engine.log` and legacy
`infrastructure.log`, checks append descriptors keep their inode, and checks core
and supervisor archives share the runtime byte/file budgets. All 12 filesystem
tests and the five logger integration cases passed on 26 November for this
candidate. No new daemon or GUI-driven cleanup was added.

- [Shared filesystem tests](../Tests/MimoSharedTests/MimoLogStoreTests.swift): size/day rotation, record integrity, age/count/size eviction, existing oversized files, open service descriptors, stale journal/output, account scope, unsafe links/directories and oversized record rejection.
- [Event Log tests](../Tests/MimoSharedTests/EventLogLineTests.swift): cleanup/drop counters and actionable storage failure.
- [Logger integration runner](../Tests/MimoLogTests/run.sh): four independent writer processes with simultaneous maintenance; storage failure/repair; original 450-record regression; bounded producer backlog during blocked storage; real 60-second scheduled expiry with no restart/preferences change after the fixture is created.

Completed results on 26 November:

| Check | Result |
| --- | --- |
| `xcrun swift test` | 238 tests passed, including 11 filesystem-policy tests and the new Event Log formatting test. |
| `bash Tests/MimoLogTests/run.sh` | All five integration cases passed: 1,600 intact concurrent records, storage repair, all 450 regression records retained across bounded segments, counted backlog overflow, and expiry by the production timer. |
| Concurrent-start stress | 50 rounds of four independent writer processes completed without an initialization or write failure. The integration case above separately verifies record contents. |
| `bash Tests/MimoServiceTests/run.sh` | Passed, including 60 exception/recovery simulations, four pending-lookup cancellation cases and real XPC transport checks. |
| Generated Release app / embedded daemon | Unsigned arm64 Release build passed with the final logging sources. |
| Existing `mimo-vm` launchd descriptors | Read-only `lsof` showed append mode (`AP`) on core/supervisor/engine stdout/stderr. The filesystem test separately verifies that an already-open append descriptor continues writing to the same inode after rotation. |

The integration runner uses isolated temporary log directories and a unique test
preferences domain. It does not fill, truncate or expire the host/VM's real logs.
Raw local run logs are under `.build/log-retention/`; the reproducible tests above
and this sanitized result record are authoritative repository artifacts.

For a manual check after installation, leave Mimo running in either Direct or
Rule/Global and inspect the managed directory across a maintenance interval.
Old managed files should disappear, oversized service output should be archived
and cleared in place, and Event Log should show cleanup counts only when work
occurred. The inspection itself and the cleanup must cause no IP lookup, routing
transition or service restart. Do not manufacture large files in a live log
directory; use the isolated integration runner for size/age injection.

These logging tests initially qualified an unpublished build-11 source candidate.
The subsequent [build 11 release checks](MIMO_V3_BUILD11_RELEASE_CHECKS.md) record
the final package installation and settled Direct smoke in mimo-vm. They do not
claim a new protected traffic/recovery matrix for the logging change.
