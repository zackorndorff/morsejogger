#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# ----------------------------------------------------------------------------

# Run SwiftPM tests or generic Apple platform builds with writable outputs under
# /private/tmp. HOME is deliberately left untouched.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${CW_SANDBOX_BUILD_ROOT:-/private/tmp/morsejogger-sandbox-build}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/sandbox_build.sh test [swift test arguments ...]
  scripts/sandbox_build.sh host
  scripts/sandbox_build.sh ios [xcodebuild arguments ...]
  scripts/sandbox_build.sh catalyst [xcodebuild arguments ...]

host runs the checks outside the SwiftPM test target: the SessionDriver
contract tests, the settings store and SCP data service checks, and the
JSON-lines CLI.

SwiftPM test scratch data and build products are stored under
CW_SANDBOX_BUILD_ROOT (default: /private/tmp/morsejogger-sandbox-build). Xcode may
write additional SwiftPM and developer-tool caches outside that directory;
see docs/SANDBOX_BUILD.md for the current sandbox limitation.
USAGE
}

fail() { printf 'sandbox_build: %s\n' "$*" >&2; exit 2; }

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
MODE="$1"
shift

case "$MODE" in
  test|host|ios|catalyst) ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; fail "unknown command: $MODE" ;;
esac

mkdir -p "$BUILD_ROOT"
BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd -P)"

printf 'Sandbox build root: %s\n' "$BUILD_ROOT"

# Point SwiftPM, swiftc and their module caches at the build root.
setup_swift_env() {
  mkdir -p "$BUILD_ROOT/tmp"
  export TMPDIR="$BUILD_ROOT/tmp/"
  printf 'Temporary directory: %s\n' "$TMPDIR"
  mkdir -p "$BUILD_ROOT/swiftpm-cache" "$BUILD_ROOT/swiftpm-config" \
    "$BUILD_ROOT/swiftpm-security" "$BUILD_ROOT/swift-modules" \
    "$BUILD_ROOT/clang-modules" "$BUILD_ROOT/bin"

  # SwiftPM invokes this compiler wrapper. Keep both Swift and Clang module
  # caches outside the user's Library/Caches and the repository's .build.
  WRAPPER="$BUILD_ROOT/bin/swiftc"
  cat > "$WRAPPER" <<'WRAPPER_EOF'
#!/usr/bin/env bash
set -euo pipefail
WRAPPER_DIR="$(cd "$(dirname "$0")" && pwd -P)"
exec xcrun swiftc \
  -module-cache-path "$WRAPPER_DIR/../swift-modules" \
  -Xcc "-fmodules-cache-path=$WRAPPER_DIR/../clang-modules" \
  "$@"
WRAPPER_EOF
  chmod 755 "$WRAPPER"
  export SWIFT_EXEC="$WRAPPER"
  SWIFTPM_ARGS=(--scratch-path "$BUILD_ROOT/swiftpm-scratch"
    --cache-path "$BUILD_ROOT/swiftpm-cache"
    --config-path "$BUILD_ROOT/swiftpm-config"
    --security-path "$BUILD_ROOT/swiftpm-security"
    --manifest-cache local --disable-dependency-cache --disable-sandbox)
  cd "$REPO_ROOT"
}

if [[ "$MODE" == test ]]; then
  setup_swift_env
  exec swift test -j 4 "${SWIFTPM_ARGS[@]}" "$@"
fi

if [[ "$MODE" == host ]]; then
  setup_swift_env
  HOST_DIR="$BUILD_ROOT/host"
  rm -rf "$HOST_DIR"
  mkdir -p "$HOST_DIR"

  # The app sources these checks need cannot link the SwiftPM test target,
  # so build the core as a dylib and compile each check as an executable.
  echo 'host 1/4: build MorseJoggerCore'
  "$WRAPPER" -emit-library -emit-module -module-name MorseJoggerCore \
    -emit-module-path "$HOST_DIR/MorseJoggerCore.swiftmodule" \
    -o "$HOST_DIR/libMorseJoggerCore.dylib" \
    Sources/MorseJoggerCore/*.swift

  host_check() {
    local name="$1"; shift
    "$WRAPPER" -parse-as-library -I "$HOST_DIR" -L "$HOST_DIR" -lMorseJoggerCore \
      -Xlinker -rpath -Xlinker "$HOST_DIR" "$@" -o "$HOST_DIR/$name"
    "$HOST_DIR/$name"
  }

  echo 'host 2/4: SessionDriver contract tests'
  host_check session-driver-tests \
    iOS/MorseJogger/SessionDriver.swift iOS/MorseJoggerTests/SessionDriverContractTests.swift

  echo 'host 3/4: settings store and SCP data service checks'
  host_check native-model-tests \
    iOS/MorseJogger/SettingsStore.swift iOS/MorseJogger/SCPDataService.swift \
    Tests/NativeModelServiceTests.swift

  echo 'host 4/4: morsejogger-wasi JSON-lines CLI (native build)'
  swift build "${SWIFTPM_ARGS[@]}" --product morsejogger-wasi
  python3 scripts/test_cli_interactive.py "$BUILD_ROOT/swiftpm-scratch/debug/morsejogger-wasi"
  echo 'Host checks passed.'
  exit 0
fi

command -v xcodebuild >/dev/null || fail 'ios and catalyst builds require macOS with Xcode.'
printf '%s\n' 'Building a disposable SDK-check project; this does not validate SwiftPM package integration.' >&2
printf '%s\n' 'See docs/SANDBOX_BUILD.md for the sandbox limits.' >&2
printf 'Xcode temporary directory (system default): %s\n' "${TMPDIR:-<unset>}"

case "$MODE" in
  ios)
    PLATFORM='generic/platform=iOS Simulator'
    DESTINATION='ios-simulator'
    XCODE_SDK_ARGS=(-sdk iphonesimulator)
    ;;
  catalyst)
    PLATFORM='generic/platform=macOS,variant=Mac Catalyst'
    DESTINATION='catalyst'
    XCODE_SDK_ARGS=()
    ;;
esac

mkdir -p "$BUILD_ROOT/xcode"
TEMP_PROJECT_ROOT="$(mktemp -d "$BUILD_ROOT/xcode/project.XXXXXX")"
python3 "$REPO_ROOT/scripts/prepare_sandbox_xcode_project.py" \
  "$REPO_ROOT" "$TEMP_PROJECT_ROOT"
XCODE_PROJECT="$TEMP_PROJECT_ROOT/iOS/MorseJogger.xcodeproj"

cd "$REPO_ROOT"
DERIVED="$BUILD_ROOT/xcode/$DESTINATION-derived"
xcodebuild -project "$XCODE_PROJECT" -scheme MorseJogger \
  -configuration Debug "${XCODE_SDK_ARGS[@]}" -destination "$PLATFORM" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon \
  'OTHER_SWIFT_FLAGS=-Xfrontend -disable-sandbox' build "$@"

# SCPDataService sends no request without a version in its User-Agent, so a
# build without one would silently lose SCP downloads.
case "$MODE" in
  ios) INFO_PLIST="$DERIVED/Build/Products/Debug-iphonesimulator/MorseJogger.app/Info.plist" ;;
  catalyst) INFO_PLIST="$DERIVED/Build/Products/Debug-maccatalyst/MorseJogger.app/Contents/Info.plist" ;;
esac
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST" 2>/dev/null || true)"
[[ -n "${VERSION// /}" ]] || fail "built app has no CFBundleShortVersionString (MARKETING_VERSION): $INFO_PLIST"
printf 'App version: %s\n' "$VERSION"
