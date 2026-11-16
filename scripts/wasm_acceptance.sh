#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# ----------------------------------------------------------------------------

# Compile the Swift core for WebAssembly and verify the WASI JSON-lines protocol.
# Run after installing a Swift WebAssembly SDK exactly matching your host Swift compiler.
set -euo pipefail
cd "$(dirname "$0")/.."
PRODUCT='morsejogger-wasi'
grep -Fq ".executable(name: \"$PRODUCT\"" Package.swift || { echo "CLI product mismatch: $PRODUCT is not declared in Package.swift" >&2; exit 2; }
command -v swift >/dev/null || { echo 'Swift compiler required' >&2; exit 2; }
command -v python3 >/dev/null || { echo 'Python 3 required for protocol comparisons' >&2; exit 2; }

SDK="${SWIFT_WASM_SDK_ID:-}"
if [[ -z "$SDK" ]]; then
  SDK="$(swift sdk list | awk '/_wasm$/ { print $1; exit }')"
fi
if [[ -z "$SDK" ]]; then
  echo 'No Swift WebAssembly SDK found. Install the version-matched official Swift SDK.' >&2
  echo 'Installed SDKs:' >&2
  swift sdk list >&2
  exit 2
fi

if command -v wasmtime >/dev/null 2>&1; then
  RUNTIME=wasmtime
elif command -v wasmkit >/dev/null 2>&1; then
  RUNTIME=wasmkit
else
  echo 'WASI runtime missing; install wasmtime or wasmkit to run the acceptance test.' >&2
  exit 2
fi

echo "Cross-compiling $PRODUCT with SDK: $SDK"
swift build -c release --swift-sdk "$SDK" --product "$PRODUCT"
# Ignore native binaries or stale debug artifacts: require a real WASI release .wasm.
WASM="$(find .build -type f -path "*/wasm32-unknown-wasi*/release/$PRODUCT.wasm" -print -quit)"
if [[ -z "$WASM" || ! -s "$WASM" ]]; then
  echo 'Build returned success without a release wasm32-unknown-wasi*/*.wasm executable' >&2
  exit 3
fi
printf 'WASM binary produced: %s (%s bytes)\n' "$WASM" "$(wc -c < "$WASM")"

# Run the same seeded inputs in native and WASI hosts. This checks actual WASI
# process startup and stdin/stdout, JSON coding, events, session control, and
# the deterministic core across the two architectures.
swift build -c release --product "$PRODUCT"
HOST_EXECUTABLE=".build/release/$PRODUCT"
[[ -x "$HOST_EXECUTABLE" ]] || { echo "Missing native host: $HOST_EXECUTABLE" >&2; exit 3; }
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
cat > "$TEMP/requests.jsonl" <<'EOF'
{"action":"configure","settings":{"seed":123,"mode":"single"}}
{"action":"start"}
{"action":"tick","time":9}
{"action":"command","command":"cq"}
{"action":"stop"}
EOF
"$HOST_EXECUTABLE" < "$TEMP/requests.jsonl" > "$TEMP/native.jsonl"
case "$RUNTIME" in
  wasmtime) wasmtime run "$WASM" < "$TEMP/requests.jsonl" > "$TEMP/wasm.jsonl" ;;
  wasmkit) wasmkit run "$WASM" < "$TEMP/requests.jsonl" > "$TEMP/wasm.jsonl" ;;
esac
python3 scripts/check_wasi_jsonl.py "$TEMP/wasm.jsonl" "$TEMP/native.jsonl"
case "$RUNTIME" in
  wasmtime) python3 scripts/test_cli_interactive.py wasmtime run "$WASM" ;;
  wasmkit) python3 scripts/test_cli_interactive.py wasmkit run "$WASM" ;;
esac
