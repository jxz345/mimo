# Mimo v1.0 naming migration

The first Mimo release changed the visible application name while retaining the earlier project’s service IDs, storage namespaces, build targets and archive names. This update completes the active naming transition without changing the app version.

## Current names

All current app, widget, project, package and source-module names use Mimo. Active service identities are `com.mimo.core`, `com.mimo.supervisor` and `com.mimo.mihomo`; the existing independent jobs retain `com.mimo.pf-boot` and `com.mimo.infrastructure`. The public removal command is `/Library/PrivilegedHelperTools/mimo-manage uninstall`. Data and logs use Mimo directories, with `Runtime` separate from the private bootstrap-profile directory `Mihomo`.

The dashboard includes the Homebrew uninstall command, a copy action, and a note that deleting the app alone leaves background services and firewall rules installed. The default dashboard height increases to accommodate the note. The README uses the fully qualified Homebrew install with no separate repository-registration step.

## Upgrade ordering

1. Verify the new sealed app and pinned engine. If an old installation is still running, use its fixed root manager to stop it and restore networking before creating new jobs. Refuse unresolved old jobs rather than starting a second supervisor.
2. Copy machine configuration into the new namespace, translate old preference keys and retain the saved mode/service intent. Copy System Keychain values to the new service identity and verify their values; never print credentials.
3. Install the new core, jobs and pinned app identity. Retain a root-owned sealed cleanup copy. Run its legacy login-removal helper separately as each account, then migrate that account’s presentation preferences and files.
4. Start and verify the new services. Only after verification succeeds, remove migrated old machine records and credential entries. Preserve unexpected user-added files and colliding files instead of overwriting them.
5. Subsequent installs use only the new names. Uninstall removes current jobs, runtime material, login choices, helpers and any compatibility bridge; saved configuration, credentials and logs remain.

## Intentional old-name references

- `LegacyNaming` and `LegacyMachineMigration` identify old preference domains, storage and Keychain records for migration.
- The embedded `MimoLegacyLoginCleanup.app` deliberately carries the former bundle identifier. ServiceManagement requires that identity to unregister the former app’s login item. This tool only unregisters; it never opens a GUI or registers a login item.
- Cleanup recognizes old app/process/job names and old fixed removal commands. A direct upgrade may keep a root-owned, uninstall-only bridge at the previous manager path because Homebrew caches uninstall instructions. Normal fresh installs do not create that bridge. A private migration marker preserves this requirement across a failed install and retry. Normal Homebrew reinstall runs the old cleanup before installing the new cask.
- The legacy cask fixture, older acceptance evidence and historical plan entries retain their original names so the recorded tests are not rewritten as if they tested the new identities.
- “Exit IP” in connection/error messages describes the public IP address; it is not the old product name.

## Verification scope

Build the normal arm64 Release and run the shared migration tests in mimo-vm. Exercise an actual earlier packaged Mimo installation, saved real configuration/password, old login registration, new service/XPC identities, a protected-mode check, Direct recovery, dashboard rendering and cleanup through Homebrew’s cached hook. Then exercise the public cask from an untapped environment using the README commands, check dependency ownership and uninstall. The VM finishes with Mimo uninstalled and its original explicit mihomo package restored. No broad packet/fault suite is implied by these focused naming checks.

The support root is root-owned and non-writable by other accounts (0755) so cleanup can detect retained installation state. Its Service, Runtime, Guard and Mihomo children remain private (0700), as does the controller directory during socket creation. The sealed login-removal app lives under PrivilegedHelperTools so it can run after dropping root privileges.
