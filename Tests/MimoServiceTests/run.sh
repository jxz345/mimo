#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
output="${1:-$REPO/.build/service-tests}"
mkdir -p "$output"
export MIMO_LOG_DIRECTORY="$output/logs"
xcrun swiftc -swift-version 6 -parse-as-library -D MIMO_SERVICE_TEST \
    "$REPO"/Sources/MimoShared/*.swift "$REPO"/Sources/MimoCore/*.swift \
    "$REPO"/Sources/MimoService/*.swift "$REPO"/Tests/MimoServiceTests/*.swift \
    -o "$output/service-tests"
"$output/service-tests" "$output"
# Exercise approval continuation ownership using the production supervisor with
# isolated external effects. Keep every run's source/diff and evidence separate.
python3 "$REPO/Tests/MimoServiceTests/ApprovalOwnership/run.py" \
    "$REPO/.build/approval-ownership-$(/usr/bin/uuidgen)"
# Keep control RPCs responsive during joined teardown and preserve newer PF owners.
python3 "$REPO/Tests/MimoServiceTests/ControlResponsiveness/run.py" \
    "$REPO/.build/control-responsiveness-$(/usr/bin/uuidgen)"
python3 "$REPO/Tests/MimoServiceTests/DirectPublication/run.py" \
    "$REPO/.build/direct-publication-$(/usr/bin/uuidgen)"
# Record the exact cancellation owner before transport abort; only successful
# persistence may claim the corresponding routing request was committed.
python3 "$REPO/Tests/MimoServiceTests/CancellationDiagnostics/run.py" \
    "$REPO/.build/cancellation-diagnostics-$(/usr/bin/uuidgen)"

# Slow protected preparation must not starve control RPCs or supersede newer intent.
python3 "$REPO/Tests/MimoServiceTests/ProtectedPreparation/run.py" \
    "$REPO/.build/protected-preparation-$(/usr/bin/uuidgen)"
python3 "$REPO/Tests/MimoServiceTests/ProtectedIOOwnership/run.py" \
    "$REPO/.build/protected-io-ownership-$(/usr/bin/uuidgen)"
python3 "$REPO/Tests/MimoServiceTests/ProtectedObserver/run.py" \
    "$REPO/.build/protected-observer-$(/usr/bin/uuidgen)"
# Coalesced infrastructure reconciliation, truthful component ages and PF scope.
python3 "$REPO/Tests/MimoServiceTests/InfrastructureHealth/run.py" \
    "$REPO/.build/infrastructure-health-$(/usr/bin/uuidgen)"
python3 "$REPO/Tests/MimoServiceTests/InfrastructureHealth/run.py" \
    "$REPO/.build/infrastructure-receipts-$(/usr/bin/uuidgen)" --new-receipts
python3 "$REPO/Tests/MimoServiceTests/RapidIntent/run.py" \
    "$REPO/.build/rapid-intent-$(/usr/bin/uuidgen)"
# Independent XPC delivery must preserve each GUI's issued mode order.
python3 "$REPO/Tests/MimoServiceTests/ModeIntentOrdering/run.py" \
    "$REPO/.build/mode-intent-ordering-$(/usr/bin/uuidgen)"
# One bounded lookup demand and terminal manual ownership through control holds.
python3 "$REPO/Tests/MimoServiceTests/ManualDemand/run.py" \
    "$REPO/.build/manual-demand-$(/usr/bin/uuidgen)"
