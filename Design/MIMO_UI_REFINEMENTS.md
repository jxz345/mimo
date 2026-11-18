# Mimo UI refinements

Updated 2026-11-18. The UI design is approved and consolidated into the canonical [mihomo / Mimo workflow and UI plan](../MIMO_PLAN.md). This document records prototype details and the native handoff. These changes are implemented in the interactive web prototype and the development native sources. They are not part of a qualified release; the canonical plan distinguishes completed checks from remaining acceptance.

## Dashboard

The desktop layout targets a 1280 × 700 or larger browser viewport at normal text size. It removes the introductory hero, design notes, long forms, and provider budget list. The entire overview is sized to the viewport. Smaller windows, mobile screens, and increased text sizes retain scrolling rather than clipping controls.

- Direct / Rule / Global remain immediately available in the top control.
- Exit IP, the selected profile, monitoring interval, and **Open Mimo at login** form the left column. The login switch shares its value with General settings and the menu preview.
- **Refresh now** has a permanent toolbar position and a Command-R shortcut.
- A live menu-bar preview shows the icon for every scenario and opens a functional status/menu mockup. It remains available after the simulated GUI closes.
- **Background services** owns **Internet access** and its verification/recovery controls. There is no duplicate standalone Internet access section.
- mimo-core, mihomo and **Tailnet provider** show status and aligned **Start / Stop / Restart** controls. **Profile hosting** uses **Open profile / Reload** in the same row, shows in-memory delivery, and names the credential-free startup file in `/Library/Application Support/Mimo/Mihomo/`. These controls appear only on the dashboard; General has no duplicate services section.
- A compact route summary preserves the LAN / Tailscale exception. Event Log and Quit GUI stay in the footer.

## Settings

A complete page replaces the previous small monitoring dialog. General is the default, with **Login item & appearance** first. A sidebar separates five sections:

| Section | Controls |
| --- | --- |
| Proxy | Name, type, server, port, optional username/password, Save and apply, Remove |
| Allowed IPs | IPv4/IPv6 list, explicit add/remove, invalid/duplicate address errors |
| Monitoring | Check interval, Check now, failure behavior, provider budgets |
| Background services | Read-only service ports and transport details; a shortcut to dashboard controls |
| General | Open at login, light/dark appearance, and reduced transparency |

Configuration changes are simulated in memory and reset on reload. The existing saved-secret availability is represented without disclosing a secret. No live network, Keychain, Homebrew, or service commands run from the page.

### Service ports

Settings → Background services shows configured ports without duplicating lifecycle controls:

| Service | Port | Basis |
| --- | --- | --- |
| mimo-core | No TCP port | Typed XPC / Mach service |
| mihomo | 7890; protected DNS 1053 | Loopback HTTP/SOCKS and DNS listeners; controller access is a Unix socket |
| Profile hosting | No separate TCP port | In-memory private Unix-socket delivery; credential-free startup YAML only |
| Tailnet provider | 18766 | Existing HTTP listener bound to `127.0.0.1` |

The reference values come from `Sources/ExitIPShared/ClashVergeProfile.swift`, `Sources/ExitIPShared/TailscaleVergeProvider.swift`, `Sources/ExitIPShared/DaemonRPC.swift`, and the original private-delivery workflow. These are configuration details, not proof that a socket is listening. They remain visible when a service is stopped. The native app reports configured ports and confirmation state separately; its authenticated verification listener is private at 127.0.0.1:18767. The dashboard's **Ports** shortcut opens these details.

## IP readout and network changes

The connection card no longer uses a “Historical” label or repeats a saved sample address after a failed check. A successful isolated probe can display its checked exit IP and check time even while internet access is blocked because the address is not approved or the allowlist is empty. For an allowlist mismatch, the card labels the observed address **IP that triggered blocking**, and the access heading names that address. The triggering address remains visible and copyable during retries until a successful check clears the block or Direct is selected. If no current result or recorded blocking IP was obtained, the card says **IP unavailable**, omits the network details and copy action, and displays **Checking IP…** during verification. Access status remains a separate explicit Allowed/Blocked/Unavailable decision.

Monitoring includes a mandatory **When network settings change → Immediately** rule. Every real change to Wi-Fi, DNS, routes, interfaces, proxy, or VPN settings requests a fresh IP check immediately, regardless of the periodic interval. Wake also requests a check. In protected modes, the gate closes before the check; a stale or superseded result cannot reopen it. Repeated changes replace the in-flight sample check immediately. Direct keeps ordinary access while refreshing its IP. If services cannot execute the check, the status remains unavailable; no result is invented.

The **Network change** button in the webpage preview toolbar simulates this event without changing the real network. The native implementation must detect actual configuration changes and fence completion by a network generation/revision so an older check cannot open traffic on a newer configuration. This behavior is included in the canonical plan.

## Review fixes

Background checks and appearance updates preserve unsaved Settings fields, validation errors, keyboard focus, text selection, and section scroll position. Successful saves clear submitted drafts and typed passwords; explicit Reset/scenario changes restore sample state. Drafts are held only in memory. Menu focus survives state updates, and the closed-window summary follows ongoing verification and menu mode changes. Long IP/profile text can wrap rather than overflow its row.

## Access and service behavior

An empty allowed exit IP list is an explicit deny condition for both Rule and Global. Selecting either mode with an empty list, removing the last address, retrying, or restarting a service cannot open protected traffic. Direct continues to bypass proxy/IP approval.

For the native implementation, service controls must use the authorized privileged manager, independently of the mimo-core process being controlled:

| Action | Required behavior |
| --- | --- |
| Start | Start the selected installed service; for protected modes validate the profile and a fresh allowlisted exit before opening traffic. |
| Stop mihomo | Hold the independent firewall guard closed for Rule/Global. Keep the saved mode; never select Direct implicitly. |
| Stop mimo-core | The independent supervisor closes the protected gate. The GUI reports unavailable/unknown until it can confirm state again. |
| Restart | Close protected traffic before stopping the service, restart it, then repeat verification. A pending restart disables conflicting lifecycle actions. |
| Stop during Direct | Preserve Direct policy. Losing mimo-core still prevents the GUI from confirming current state or accepting mode changes. |

Start/Stop/Restart require administrator authorization in the native app. A stop must actually suppress that job's immediate automatic respawn until Start/recovery is requested; killing a KeepAlive process is insufficient. Do not stop the independent firewall/safety supervisor. Restart and reactivation must not remove the firewall guard. The native controls and installer/recovery tests are implemented; full protected-mode lifecycle acceptance remains pending.

## Profile hosting and tailnet provider

These are distinct service rows in the prototype. Profile hosting represents private full-profile delivery to mihomo; it does not publish credentials at an unauthenticated HTTP endpoint. Reloading it blocks Rule/Global until delivery and fresh verification recover. Open profile displays a read-only generated snapshot after administrator authorization.

The tailnet provider publishes the local-routing policy. Stopping it makes protected tailnet routing reject while an already-verified public connection stays active. It does not stop the actual Tailscale application. Direct bypasses profile-based routing. The native implementation must preserve the existing provider's fail-closed semantics; these buttons only simulate them.

## Design reference and menu-bar study

[Design sources](MIMO_DESIGN_SOURCES.md) records the Apple references and the menu-bar mapping for every scenario. The revision uses a neutral utility-app layout, common control sizes, aligned service rows, and a permanent toolbar action. Menu-bar changes are driven by the same simulated state as the dashboard.

## Liquid Glass handoff

The webpage uses a neutral graphite/gray palette with greyscale controls and a matching graphite app icon. It approximates the material with CSS, translucent navigation, rounded controls, subtle highlights, and background blur. Important status text and forms use stable contrast. The preview includes a solid fallback, reduced-transparency preference, and increased-contrast handling. It does not claim to render actual macOS components.

Use native system components when implementing the SwiftUI app:

| Preview element | Native implementation direction |
| --- | --- |
| Title bar and navigation | Standard window title bar and toolbar; let macOS supply the material. |
| Settings sidebar | `NavigationSplitView` with native sidebar selection. |
| Mode selector | Native segmented `Picker`; keep mode semantics separate from access state. |
| Glass action buttons | Native `Button` with `.buttonStyle(.glass)` where appropriate on macOS 26. |
| Custom control group | `GlassEffectContainer` and a sparing `.glassEffect(.regular.interactive())` treatment. |
| Configuration | Native grouped forms, text fields, pickers, toggles, and dialogs. |
| Earlier macOS releases | Availability checks and native fallback controls; the current app still supports macOS 14+. |

Apple recommends system navigation and controls for adoption; custom glass effects are available for SwiftUI views. See [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) and [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views).

## App icon

[AppIcon/](AppIcon/) contains the editable SVG, a transparent 1024px PNG, a static macOS `.icns`, monochrome symbol, and separate full-square background/glyph SVG layers for a future Icon Composer project. The mark is a frosted lowercase “m” with two arches on graphite. It is integrated into the preview header, title bar, Settings, favicon, and the downloadable App icon page.

These are design assets, not a compiled dynamic `.icon` document. The shipping app's existing country/status Dock behavior has not been replaced.

## Verification

Seventy-one DOM-simulation checks cover the service-port metadata and navigation, checked-IP/unavailable readout, immediate and repeated network changes, General without redundant services, routing, empty-list denial, profile edits, all four services, the permanent Refresh now control, synchronized login preference, all 13 scenarios in the live menu-bar preview, Settings draft/focus preservation, live closed-window status, icon navigation, and the synchronized canonical plan. All static resources are served by Delta on `0.0.0.0:8347`.

Browser visual verification remains pending: the browser host is unavailable and Safari tool access returned “Computer Use was not approved to use Safari” even after user approval. The no-scroll target has been specified in the CSS but has not been measured in a real browser.
