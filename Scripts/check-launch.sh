#!/bin/bash
exec /bin/bash "$(cd "$(dirname "$0")/.." && pwd)/Sources/MimoDiagnostics/diagnose-launch.sh" "$@"
