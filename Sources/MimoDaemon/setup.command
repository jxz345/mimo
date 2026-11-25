#!/bin/bash
# Interactive copied-app/package setup, executed as the installing account.
set -euo pipefail
setup_dir="$(cd "$(dirname "$0")" && pwd)"
if [ "$(/usr/bin/id -u)" = 0 ]; then
    echo 'Run setup.command as your normal account; it requests administrator authentication when needed.' >&2
    exit 1
fi
[ -f "$setup_dir/mihomo-v3.bin" ] || { echo 'The bundled engine is missing. Reinstall the complete app.' >&2; exit 1; }
/usr/bin/sudo /bin/bash "$setup_dir/daemon.sh" install
