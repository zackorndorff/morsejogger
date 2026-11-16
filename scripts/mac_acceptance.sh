#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
# ----------------------------------------------------------------------------

# Run ON macOS with Xcode 16+. No device provisioning/signing required.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodebuild >/dev/null || { echo 'Requires macOS + Xcode' >&2; exit 2; }
echo 'STEP 1: Swift core unit/reference tests'
swift test -j 4
echo 'STEP 2: Native iOS simulator SDK typecheck and compile'
xcodebuild -project iOS/MorseJogger.xcodeproj -scheme MorseJogger -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
if [[ "${MORSEJOGGER_LAUNCH_SIMULATOR:-0}" == 1 ]]; then
  echo 'STEP 3: boot simulator and launch native app'
  BOOTED="$(xcrun simctl list devices booted | sed -n 's/.*(\([A-F0-9-]\{36\}\)).*/\1/p' | head -n 1)"
  if [[ -z "$BOOTED" ]]; then echo 'Boot an iPhone simulator first.' >&2; exit 2; fi
  APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Debug-iphonesimulator/MorseJogger.app' -print -quit)"
  [[ -n "$APP" ]] || { echo 'MorseJogger.app not found' >&2; exit 3; }
  xcrun simctl install "$BOOTED" "$APP"
  xcrun simctl launch "$BOOTED" com.z10f.morsejogger
fi
echo 'Compile gate passed. Real-device/audio/accessibility/manual UX tests are separate.'
