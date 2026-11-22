# Historical uninstall recovery

For current Mimo, use [clean uninstall](../README.md#clean-uninstall-and-reinstall). This archive retains recovery instructions for incomplete older installations.

### Manual recovery after an incomplete version 1 uninstall

Use this on the **Mac where Mimo was installed**, from a local administrator Terminal, if normal uninstall fails or internet access remains broken after removing the app. Keep the same Terminal window for these steps. This procedure removes Mimo’s network enforcement; it does not require a working GUI or core connection.

Deleting or killing `mimo-core` alone is insufficient. Mimo also installs an engine, two independent guard jobs, a persistent PF boot rule and a DNS override. A guard can reapply blocking after the core exits. Version 1 uninstall can stop on an earlier cleanup error; a partially removed installation can also lack files needed for automatic network restoration. The order below stops those writers before releasing the network.

#### Standalone recovery script

Save [cleanup-mimo-v1.pl](../Scripts/cleanup-mimo-v1.pl) to Downloads on the affected Mac. It uses the macOS-supplied Perl and does not need a new Mimo build. Quit every Mimo GUI first, and use a local Terminal. Inspect before applying:

```sh
sudo /usr/bin/perl ~/Downloads/cleanup-mimo-v1.pl --check
sudo /usr/bin/perl ~/Downloads/cleanup-mimo-v1.pl --apply
```

Omitting the argument is equivalent to `--check`: it inspects jobs, processes, Mimo’s PF anchor/resolver and the proposed PF configuration; it changes no services or network settings. `--apply` prints the Mac name and scope, asks you to type `REMOVE MIMO`, and then rechecks before making changes. There is no unattended confirmation bypass.

The script disables/unloads Mimo’s jobs, waits for its workers to exit, reasserts the disable overrides, removes only the exact Mimo boot block and live PF parent rules, removes Mimo’s DNS key, releases identifiable current-boot PF references and restores journaled IPv6 flags. It archives startup files, helpers and generated runtime material under a root-private `/var/root/mimo-recovery.*` directory. It does not call the service manager’s maintenance operation, reload the global firewall, flush unrelated states or kill other engines.

Unexpected PF configuration, uncertain job state or a worker that will not exit stops automation. A missing/broken helper with saved IPv6 settings leaves the helper/journals in place for the manual IPv6 step below; already completed PF/DNS recovery is not rolled back. A missing IPv6 journal is reported as unknown previous settings, not proof of restoration. PF references whose ownership cannot be verified are left for review. Keep the printed backup path and any error. The backup may contain generated credentials and must remain private.

This is **service/network recovery**, not the complete package uninstaller. It retains the app/Homebrew receipt, per-account login entries, private group/authorization right, machine settings, Keychain credentials and logs. After successful recovery, finish the app/login/package/group/right cleanup described in step 5, then verify after reboot as in step 6. Do not run the archive block again after the script has already archived the components.

Validation: `perl -c Scripts/cleanup-mimo-v1.pl` and `perl Tests/MimoDaemonTests/manual_cleanup_test.pl` check syntax and fixture/mocked-command behavior, including unrelated-policy preservation, shutdown order, failed restoration, backup collisions and command deadlines. These checks do not uninstall the app or exercise a real firewall; the script still requires validation on an affected Mac or in the designated runtime VM.

#### 1. Quit the GUI and stop every Mimo system job

Quit Mimo in every logged-in account, and do not reopen it or run an installer during recovery. Remove Mimo from **System Settings → General → Login Items & Extensions → Open at Login** in each account where it was enabled. A leftover login entry can be cleaned up later; do not delay network recovery because another account is unavailable.

Create a private recovery directory, save the network recovery records, then disable all five jobs before unloading any of them, with the independent repair jobs first. A repair already in flight can re-enable a job, so also complete the process and registration checks below. The block accepts an already absent job, but stops on other launchctl errors.

```bash
mimo_recovery="$(sudo /usr/bin/mktemp -d /var/root/mimo-recovery.XXXXXX)"
printf 'Recovery files: %s\n' "$mimo_recovery"
sudo /bin/bash -s -- "$mimo_recovery" <<'MIMO_STOP'
set -eu
recovery=$1
case "$recovery" in /var/root/mimo-recovery.*) ;; *) exit 1 ;; esac
[ -d "$recovery" ]
[ ! -L "$recovery" ]
/bin/cp -p /etc/pf.conf "$recovery/pf.conf"
support='/Library/Application Support/Mimo'
for relative in Runtime/ipv6-original.plist Runtime/ipv6-apply-pending Runtime/pf-reference.json Guard/pf-reference.json; do
    if [ -f "$support/$relative" ]; then
        /bin/mkdir -p "$recovery/$(/usr/bin/dirname "$relative")"
        /bin/cp -p "$support/$relative" "$recovery/$relative"
    fi
done
labels=(com.mimo.infrastructure com.mimo.pf-boot com.mimo.core com.mimo.mihomo com.mimo.supervisor)
for label in "${labels[@]}"; do
    /bin/launchctl disable "system/$label"
done
for label in "${labels[@]}"; do
    status=0
    output=$(/bin/launchctl print "system/$label" 2>&1) || status=$?
    if [ "$status" = 0 ]; then
        /bin/launchctl bootout "system/$label"
    elif [ "$status" = 113 ] && [[ "$output" == *'Could not find service'* ]]; then
        printf 'Already absent: %s\n' "$label"
    else
        printf '%s\n' "$output" >&2
        exit 1
    fi
done
MIMO_STOP
```

Allow up to 45 seconds for stopped workers to exit, then check their full paths:

```sh
/bin/ps -axww -o pid=,uid=,command= | /usr/bin/awk '
    /\/Library\/PrivilegedHelperTools\/(mimo-core|com\.mimo\.core)|\/Library\/Application Support\/Mimo\/(Runtime\/mihomo|Guard\/pf-guard\.pl)/ && !/awk/
'
```

**Continue only when no Mimo worker remains.** If one remains, verify its executable path and PID, send `sudo kill -TERM PID`, and check again. Use `sudo kill -KILL PID` only for that same verified process if it will not exit. Do not use `killall mihomo`: another VPN may own a different engine. Do not proceed past a failed stop or a process that keeps returning.

With the workers gone, reassert the disable overrides and verify all registrations are absent:

```bash
sudo /bin/bash <<'MIMO_VERIFY_STOP'
set -eu
for label in com.mimo.infrastructure com.mimo.pf-boot com.mimo.core com.mimo.mihomo com.mimo.supervisor; do
    /bin/launchctl disable "system/$label"
    status=0
    output=$(/bin/launchctl print "system/$label" 2>&1) || status=$?
    if [ "$status" = 113 ] && [[ "$output" == *'Could not find service'* ]]; then
        printf 'Stopped and disabled: %s\n' "$label"
    else
        printf 'Registration still present or inspection failed: %s\n%s\n' "$label" "$output" >&2
        exit 1
    fi
done
MIMO_VERIFY_STOP
```

If this check fails, repeat the stop and process checks before continuing. For an installation migrated from ExitIPMonitor, also inspect and stop the compatibility jobs `com.example.exitipmonitor.tailscale-verge` and `com.example.exitipmonitor.tailscale-verge-http` if present, using the same disable/unload procedure.

#### 2. Remove Mimo’s persistent and live firewall policy

If the installed guard script is present, its removal operation deletes only Mimo’s marked block in `/etc/pf.conf` and releases its own PF enable reference:

```sh
sudo /usr/bin/perl '/Library/Application Support/Mimo/Guard/pf-guard.pl' --remove
```

If the script is missing or fails, run `sudo /usr/bin/nano /etc/pf.conf` and remove **only** this block if present:

```text
# BEGIN MIMO BOOT GUARD
load anchor "com.apple/000.mimo" from "/etc/pf.anchors/com.mimo.boot"
# END MIMO BOOT GUARD
```

Keep Apple’s `anchor "com.apple/*"` and every other application’s entries. If the markers or contents differ, inspect them before editing; do not delete a range of unrelated rules. Check the edited file without loading it, then empty only Mimo’s live parent anchor:

```sh
sudo /sbin/pfctl -n -f /etc/pf.conf
sudo /sbin/pfctl -a com.apple/000.mimo -F rules
sudo /sbin/pfctl -a com.apple/000.mimo -sr
```

The last command should show no rules. An already absent anchor can report `Invalid argument`; verify that Mimo has no loaded parent rules and its boot block is gone before treating that as harmless. Emptying the parent disconnects its permission, power-guard, native-transport and other child anchors; inert child entries may remain until reboot. Do not use global `pfctl -d`, `pfctl -F all`, a global state flush, or reload all of `/etc/pf.conf` to recover Mimo. Those operations can change another VPN’s protection.

#### 3. Remove the orphaned resolver and restore IPv6

Remove only Mimo’s dynamic-store DNS key, which may otherwise direct lookups to a stopped listener:

```sh
printf 'remove State:/Network/Service/com.mimo.dns/DNS\nquit\n' | sudo /usr/sbin/scutil
printf 'show State:/Network/Service/com.mimo.dns/DNS\nquit\n' | /usr/sbin/scutil
sudo /usr/bin/dscacheutil -flushcache
/usr/sbin/scutil --dns
```

`No such key` is the expected result of the second command. The native network/VPN resolvers should remain. Current Mimo does not overwrite each network service’s saved DNS-server or proxy settings: do not clear all DNS servers, delete Tailscale’s resolver, or reset every proxy. If you separately configured a service to use Mimo’s loopback address, restore that service’s previous setting.

Before deleting the helper or its recovery records, restore the saved per-service IPv6 enabled flags:

```sh
sudo /Library/PrivilegedHelperTools/mimo-core --restore-ipv6-preferences
```

This one-shot operation does not start the core or reinstall the firewall. It reads `Runtime/ipv6-original.plist` and removes that journal after restoration. A missing journal makes it a no-op, so a successful exit alone does not prove IPv6 was restored when recovery data is missing. **Keep the original journal and helper if this step fails.**

If the helper is missing or cannot run, restore the affected services’ previous IPv6 choices in **System Settings → Network → service → Details → TCP/IP** ([Apple’s TCP/IP settings reference](https://support.apple.com/guide/mac-help/change-tcpip-settings-on-mac-mh14129/mac)). For a service that previously used Automatic, `sudo /usr/sbin/networksetup -setv6automatic "Wi-Fi"` restores that choice; replace `Wi-Fi` with the actual service name. Do not apply Automatic to every service or overwrite a deliberate manual/disabled setting. Mimo’s journal records enabled flags by service UUID, not a replacement address/router configuration.

#### 4. Release only Mimo’s remaining PF enable references

PF being enabled is not itself evidence of leftover Mimo blocking: another application or macOS may still need it. Inspect the current boot ID, live references and Mimo’s saved records:

```sh
/usr/sbin/sysctl -n kern.bootsessionuuid
sudo /sbin/pfctl -s References
sudo /bin/cat '/Library/Application Support/Mimo/Runtime/pf-reference.json'
sudo /bin/cat '/Library/Application Support/Mimo/Guard/pf-reference.json'
```

A missing record is normal after successful cleanup. For each remaining JSON record, release its numeric `token` with `sudo /sbin/pfctl -X TOKEN` **only if** its `boot` equals the current boot ID and the same token appears in the live reference list. The guard removal may already have released its token. Do not use an old backup’s token after reboot, guess a token, or release another owner’s reference. If ownership cannot be established, leave the reference alone; an empty Mimo anchor no longer blocks traffic, and the reference does not survive reboot.

#### 5. Remove the installed components after network recovery

First verify ordinary DNS and internet access locally, for example with `dscacheutil -q host -a name example.com` and a browser. Check that the Mimo DNS key is absent, the Mimo parent anchor is empty, and no Mimo worker has returned. Do not use the old GUI’s last “Healthy” report as confirmation.

Use the following fallback **after completing the steps above**. Do not retry the service manager or installer midway through manual recovery: entering maintenance can reapply blocking. The fallback moves Mimo’s startup files, helpers and generated runtime material into the private recovery directory, instead of discarding recovery evidence. Machine settings in `Mimo/Service`, Keychain credentials and logs stay in place; saved service intent moves with `Runtime` into the backup.

Remove the `com.mimo.configure` authorization right with the helper if it is still available:

```sh
sudo /Library/PrivilegedHelperTools/mimo-core --remove-right
```

If the helper is unavailable, the equivalent targeted command is `sudo /usr/bin/security authorizationdb remove com.mimo.configure`. An already absent right requires no further action.

```bash
sudo /bin/bash -s -- "$mimo_recovery" <<'MIMO_ARCHIVE'
set -eu
recovery=$1
case "$recovery" in /var/root/mimo-recovery.*) ;; *) exit 1 ;; esac
[ -d "$recovery" ]
[ ! -L "$recovery" ]
archive() {
    local source=$1 target="$recovery/removed$1"
    [ -e "$source" ] || [ -L "$source" ] || return 0
    if [ -e "$target" ] || [ -L "$target" ]; then
        printf 'Backup already exists; inspect before continuing: %s\n' "$target" >&2
        return 1
    fi
    /bin/mkdir -p "$(/usr/bin/dirname "$target")"
    /bin/mv "$source" "$target"
}
for label in com.mimo.infrastructure com.mimo.pf-boot com.mimo.core com.mimo.mihomo com.mimo.supervisor; do
    archive "/Library/LaunchDaemons/$label.plist"
done
support='/Library/Application Support/Mimo'
for name in LaunchDaemons Guard Runtime Mihomo TailscaleVerge; do
    archive "$support/$name"
done
for name in installed-app app.cdhash command-support.sh cleanup-installation.sh tailscale-verge.sh; do
    archive "$support/$name"
done
for path in /Library/PrivilegedHelperTools/mimo-core /Library/PrivilegedHelperTools/com.mimo.core /Library/PrivilegedHelperTools/mimo-manage /Library/PrivilegedHelperTools/MimoUninstaller.app /etc/pf.anchors/com.mimo.boot /etc/sudoers.d/mimo-service /etc/sudoers.d/mimo-tailscale-verge; do
    archive "$path"
done
printf 'Installed Mimo components moved to %s/removed\n' "$recovery"
MIMO_ARCHIVE
```

The backup can contain generated proxy credentials; keep it root-private. It is not a diagnostics bundle to publish. Do not move these files back wholesale: that would also restore startup and blocking components.

The unused `_mimo` group is not a running service and cannot block networking. Prefer the normal uninstaller’s membership checks to remove it. For manual removal, inspect `dscl . -read /Groups/_mimo`, its `PrimaryGroupID`, `dscl . -list /Users PrimaryGroupID`, `dscl . -list /Groups PrimaryGroupID`, and `ps -axo pid=,gid=,comm=`. Only if it has no members or nested groups, no user/process uses that GID and no other group shares it, remove it with `sudo /usr/sbin/dseditgroup -o delete _mimo`. Do not assume its GID is always `10000`; leaving an uncertain group is harmless to connectivity.

For installations migrated from ExitIPMonitor, archive the two stopped compatibility jobs’ matching `/Library/LaunchDaemons/*.plist` files, `/Library/PrivilegedHelperTools/com.example.exitipmonitor.manage` and `/etc/sudoers.d/exitipmonitor-service` if present and confirmed to belong to this installation. Do not remove similarly named third-party services.

Finally, for Homebrew, run `brew uninstall --cask jxz345/tap/mimo` as your normal user to remove the cask/app receipt; for a copied app, remove `/Applications/Mimo.app`. If Homebrew’s cached hook still refuses, keep its error for package cleanup; do not reinstall services just to recover internet access. Remove any remaining per-account Mimo login entry. Do not uninstall another application’s Homebrew engine dependency as part of this manual procedure.

#### 6. Verify after reboot and before any reinstall

After removing the boot block and startup components, reboot and confirm that the five Mimo system jobs remain absent, the Mimo DNS key does not return and internet access works. Closing the engine should release its TUN routes; a reboot clears orphaned interfaces without guessing a `utun` number or flushing other VPNs’ routes. If a Mimo rule or worker returns, locate the remaining startup owner before deleting anything else.

These emergency steps intentionally leave launchd disable overrides. **Only when deliberately reinstalling Mimo**, after the old components have been removed, re-enable its five labels before running the installer:

```bash
for label in com.mimo.infrastructure com.mimo.pf-boot com.mimo.core com.mimo.mihomo com.mimo.supervisor; do
    sudo /bin/launchctl enable "system/$label"
done
```

This is a documented recovery procedure, not a fix to the version 1 uninstaller. Its commands are based on the installed-resource ownership in [daemon.sh](../Sources/MimoDaemon/daemon.sh), [pf-guard.pl](../Sources/MimoDaemon/pf-guard.pl), [DNS configuration](../Sources/MimoService/MimoDNSConfiguration.swift) and [IPv6 restoration](../Sources/MimoService/MimoIPv4Configuration.swift). Actual network restoration must be verified on the affected Mac.
