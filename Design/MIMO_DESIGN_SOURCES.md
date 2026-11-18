# Mimo macOS design references

Reviewed 2026-11-18 for the dashboard revision. The primary references are Apple's own macOS guidance and controls, with Activity Monitor as a concrete utility-app example.

## Sources and decisions

| Source | What informs this revision |
| --- | --- |
| [Apple Human Interface Guidelines: Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) | A comfortable information density, familiar controls, keyboard access, and fewer nested steps. |
| [Apple Human Interface Guidelines: Layout](https://developer.apple.com/design/human-interface-guidelines/layout) | Align labels and controls, group related information, and make importance clear through position and spacing. |
| [Apple Human Interface Guidelines: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) | Keep frequent actions in a predictable location, use concise view titles, and keep toolbar decoration restrained. |
| [Apple Design Resources: macOS](https://developer.apple.com/design/resources/#macos-apps) | The official UI kit is the reference for native implementation rather than inventing a separate control language. |
| [Activity Monitor for macOS Tahoe](https://support.apple.com/guide/activity-monitor/welcome/10.14/mac/26) | The official example demonstrates aligned information rows, clear column relationships, and quiet neutral surfaces. |
| [Apple Human Interface Guidelines: Materials](https://developer.apple.com/design/human-interface-guidelines/materials) | Glass distinguishes navigation and controls while content remains legible. |

The page is a browser approximation for review, not a rendering of actual AppKit/SwiftUI components. The existing native application is unchanged.

## Layout applied to Mimo

- A compact title bar identifies Overview or Settings. **Refresh now** has a permanent labeled toolbar position, also available through Command-R.
- A single segmented selector controls Direct / Rule / Global. Its selected value is separate from the actual internet-access decision.
- The left group presents the IP, verification age, allowlist count, selected profile, schedule, and an explicit **Open Mimo at login** switch.
- The right group is **Background services**. Internet access belongs to this group. Four rows align service identity and status. mimo-core, mihomo and Tailnet provider use Start / Stop / Restart; Profile hosting uses Open profile / Reload.
- The service list uses separators and common control sizes. Broad tinted panels and decorative badges are reduced. Semantic color is reserved for access status and selection.
- The icon and theme use graphite/neutral gray without colored accents.
- The IP that triggered an allowlist block is explicitly labeled and stays visible during retries. Missing results without a recorded block say IP unavailable.
- Every network settings change requests an immediate IP check, independently of the routine interval.
- Settings retains grouped forms. General omits the dashboard’s service controls. A dedicated Background services section shows read-only port details (mihomo 7890, Tailnet provider 18766, no TCP port for XPC/private-file delivery). General is the default and starts with **Login item & appearance**. The login-item preference is shared between the dashboard, General settings, and the menu preview.
- The desktop menu-bar preview stays above the window, including when the simulated GUI closes. The menu exposes status, modes, Refresh now, Dashboard, Settings, and the login preference.

## Menu-bar preview specification

| Scenario | Menu-bar appearance |
| --- | --- |
| Verified Rule / Global | Singapore country flag; tooltip/menu says the exit is approved |
| Direct | Direct arrow; tooltip/menu says Direct connection |
| Startup / validation / IP check | Clock; tooltip/menu says checking with internet blocked |
| Unapproved IP / proxy error / lookup error / empty allowlist / missing profile / stopped mihomo / stopped profile hosting | Stop symbol beside the last known country flag; menu gives the blocking reason |
| Core unavailable / setup incomplete | Neutral information symbol; status is unavailable, never a claim of confirmed protection |
| Tailnet provider stopped with public internet still verified | Country flag plus a warning; tailnet routes reject while public policy remains unchanged |

The flag in a blocked state is historical context, not approval. The original installed app's live menu-bar behavior is not modified by the preview.

## Layout target and verification limit

The desktop target remains a browser viewport of at least 1280 × 700 CSS pixels at normal zoom. The mock window has a maximum height of 650px and uses the remaining viewport height on smaller laptops. Narrow layouts and enlarged text scroll to preserve controls.

All 71 DOM-simulation checks pass, including all 13 preview scenarios, menu interactions, Settings draft/focus preservation, live status after window closure, and the synchronized approved plan. Browser visual verification is still unavailable: the browser access host is unavailable, and Safari tooling previously rejected access despite the user's approval. No claim of measured browser fit is made until that check can run.
