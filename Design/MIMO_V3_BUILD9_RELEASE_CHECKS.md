# Mimo 3.0 build 9 — published Homebrew and native UI checks

Date: 2026-11-25. Target: `mimo-vm` only. Release: [3.0 build 9](https://github.com/jxz345/mimo/releases/tag/v3.0-build.9).

The public cask reports version `3.0`, downloads the immutable build 9 ZIP, and
uses the app's pinned bundled engine. Source commit: `ec8478f`; tap commit:
`b5565cc`. Credentials, private state snapshots and raw GUI captures remain local.

## Completed

- 215 shared tests, service and daemon suites passed before packaging.
- ZIP/package sealed signature and matching 3.0/build 9 identities verified.
- Packaged core and engine hashes match the candidate qualified in the corrected
  32-case fault matrix and real Rule/Global Tailnet reconnect checks.
- Clean removal of the previously installed candidate: daemons absent, owned PF
  rules empty, protected DNS removed, native network verification passed.
- **Published Homebrew fresh install passed**, with Homebrew's successful-install
  message and installed receipt `3.0`. App build 9 and engine SHA256 verified;
  all services running; managed Direct active; owned PF/DNS/TUN released; native
  network verification passed. See
  [fresh-install evidence](../Tests/ReleaseEvidence/v3-build9/fresh-install-checks.json).

The first attempt used a dedicated administrator that did not own Homebrew's
work directories. Temporary per-account directory ACLs were recorded for later
removal. A subsequent foreground SSH install lost its connection when the
installer closed existing network states; that incomplete attempt was cleaned
up. The successful run used real non-root Homebrew in a detached guest job, with
its exit status and log retained independently of SSH.

## Published lifecycle results

All seven recorded lifecycle phases passed on the public build:

| Phase | Result and evidence |
| --- | --- |
| Fresh Homebrew install | [PASS](../Tests/ReleaseEvidence/v3-build9/fresh-install-checks.json): 3.0/build 9, sealed app, pinned engine, all five jobs loaded, healthy managed Direct. |
| Homebrew uninstall | [PASS](../Tests/ReleaseEvidence/v3-build9/brew-uninstall-checks.json): app, jobs, controller and runtime engine absent; owned PF/DNS/TUN released; native networking verified. |
| Install after uninstall | [PASS](../Tests/ReleaseEvidence/v3-build9/reinstall-after-uninstall-checks.json): every service restored. |
| Stop via bundled `daemon.sh deactivate` | [PASS](../Tests/ReleaseEvidence/v3-build9/cli-stop-checks.json): full cleanup, app retained. This is the script used by the dashboard button, not a completed button-click test. |
| Start via bundled `daemon.sh activate` | [PASS](../Tests/ReleaseEvidence/v3-build9/cli-start-checks.json): all jobs and engine restored, active Direct, no residual filtering/DNS override. |
| Delete `/Applications/Mimo.app` after successful cleanup | [PASS](../Tests/ReleaseEvidence/v3-build9/manual-app-deletion-checks.json): app absent; services and network controls remained absent; native networking verified. The app was deleted by CLI; an existing build 9 backup was retained. |
| `brew reinstall` after Stop and app deletion | [PASS](../Tests/ReleaseEvidence/v3-build9/reinstall-after-deletion-checks.json): app and all services restored despite the previous inactive state and missing app. |

Actual Homebrew jobs finished with exit 0, including install, uninstall and
reinstall. The final [Homebrew receipt](../Tests/ReleaseEvidence/v3-build9/brew-final.json)
reports `3.0` and the immutable build 9 ZIP. The VM remains installed and healthy
in managed Direct. These are repeated phase checks, not seven independent
traffic-qualification campaigns.

Uninstall also removed a seeded legacy child anchor and its persistent table,
while preserving an unrelated fixture anchor. The cleanup log contained
`firewall_removed`, `resolver_removed`, `tailnet_verified` and
`uninstall_completed`; see [the checks](../Tests/ReleaseEvidence/v3-build9/brew-uninstall-log-checks.json).
The unrelated test fixture was then removed explicitly. All 21 temporary
Homebrew ACL additions were removed; [restoration evidence](../Tests/ReleaseEvidence/v3-build9/test-environment-restored.json).
Original machine monitoring settings and token presence were preserved;
[final state check](../Tests/ReleaseEvidence/v3-build9/final-restoration.json).

These checks do not qualify real sleep/wake (the VM did not enter sleep), physical
network/power transitions, or actual PF kernel-operation failure. Existing scope
and limitations in the v3 test documents remain in effect.

## Native UI observations (published build 9)

Completed on the dedicated `mimotest` desktop through Screen Sharing:

- Dashboard Refresh now displayed checking and updated the exit-IP observation age.
- IPv4 copy and uninstall-command copy controls responded; profile viewer opened
  the annotated idle Direct profile and closed normally.
- Profile Reload, engine Restart and core Restart returned to healthy Direct;
  independent core state reported all three service rows running.
- Core Stop showed the specific stopped-core message. Reconnect did not falsely
  claim it had restarted core; Start restored the connection and running state.
- General: login item on/off (macOS confirmed registration, then Login Items was
  empty after disabling), System/Light/Dark appearance, transparency on/off,
  country-change highlighting on/off, flag/country-code display, and the Login
  Items shortcut. Original appearance/display/toggle values restored.
- Monitoring: routine interval changed from one hour to Never, and the ipapi.co
  checkbox disabled that provider. Original settings were restored through core's
  authenticated configuration endpoint and compared with the saved baseline.
  Subsequent attempted token input did not save a token; token controls remain
  unqualified.
- Maintenance: active and transition policy disclosures opened. PF, supervisor,
  DNS and deactivate copy controls responded with checkmark feedback.

Desktop automation subsequently lost access to **all host application windows**
(`cgWindowNotFound`/`noWindowsAvailable`), not just Mimo. Native checks remain
incomplete until the viewer becomes accessible again. Retries using application
name, bundle ID, application path and a fresh automation session all failed;
Finder and System Settings were unavailable as well. Command-line lifecycle
checks completed independently. No claim is made that every button has passed.

Remaining native checks: full Stop/Activate buttons and administrator sheet;
monitoring-only GUI refresh after Stop; mode/family controls; Proxy CRUD/import;
Bypass editing/apply/delete; Allowed IP add/remove; remaining provider/token
controls and monitoring-rules shortcut; remaining maintenance disclosures/copy
buttons; Event Log Pause/Resume/copy/reveal; Quit GUI; and conditional error/retry
controls where a corresponding state can be reached. Disabled or unreachable
controls must be reported as such, never counted as successful clicks. The
published build's executable bytes were not changed during these checks.
