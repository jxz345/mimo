#!/bin/bash
# Interactive copied-app/package setup, executed as the installing account.
set -euo pipefail
setup_dir="$(cd "$(dirname "$0")" && pwd)"
if [ "$(/usr/bin/id -u)" = 0 ]; then
    echo 'Run setup.command as your normal account; it requests administrator authentication when needed.' >&2
    exit 1
fi
case "$(/usr/bin/uname -m)" in
    arm64) brew=/opt/homebrew/bin/brew ;;
    *) echo 'Mimo requires an Apple silicon Mac. Run setup natively, outside Rosetta.' >&2; exit 1 ;;
esac
if [ ! -x "$brew" ]; then
    installer=$(/usr/bin/mktemp -t mimo-homebrew)
    trap '/bin/rm -f "$installer"' EXIT
    /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 \
        https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer"
    /bin/bash "$installer"
fi
formula=$(/usr/bin/plutil -extract formula raw -o - "$setup_dir/MihomoDependency.plist")
"$brew" install "$formula"
operation=install
if [ -f '/Library/Application Support/Mimo/deactivated' ]; then operation=activate; fi
/usr/bin/sudo /bin/bash "$setup_dir/daemon.sh" "$operation"
