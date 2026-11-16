# Sandbox build limits

`scripts/sandbox_build.sh test` places SwiftPM scratch data, caches, and build
products below `/private/tmp/morsejogger-sandbox-build` by default. `host` uses
the same locations: it builds the core as a dylib, compiles
`iOS/MorseJoggerTests/SessionDriverContractTests.swift` and
`Tests/NativeModelServiceTests.swift` against it as standalone executables, and
runs `scripts/test_cli_interactive.py` against a native `morsejogger-wasi`.

The `ios` and `catalyst` commands create a disposable copy of the Xcode project
under the same build root. The helper removes the local Swift package
dependency, adds the shared core Swift files to the app's source phase, and
removes the package imports from the copied app sources. Xcode then compiles
the app and core sources against the selected Apple SDK and produces an app
bundle. It also omits the Icon Composer document, which the restricted
environment cannot process, and, when the checkout has no gitignored
`iOS/Local.xcconfig`, writes one with an empty `SCP_CONTACT` so the copy
builds. After the build the script fails if the app's Info.plist has no
`CFBundleShortVersionString`, because `SCPDataService` sends no request without
a version in its User-Agent. The product project and its files are untouched.

The copy compiles the core and app into one Swift module. This checks Apple SDK
types and macro expansion across the full source set, but it does not verify
the original Swift package module boundary, package manifest resolution, or
the Icon Composer resource. For release acceptance, run
`bash scripts/mac_acceptance.sh` outside this restriction.

The installed Swift frontend supports `-disable-sandbox` for subprocesses;
the script passes it through Xcode as
`OTHER_SWIFT_FLAGS='-Xfrontend -disable-sandbox'`. This allows SwiftUI macro
plugins to run while the outer workspace sandbox still constrains file access.
Xcode's original package resolution writes the Clang module cache to
`~/.cache/clang/ModuleCache` and SwiftPM manifest diagnostics to
`~/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading`; the outer
sandbox denies those paths. `-disableAutomaticPackageResolution`,
`-skipPackageUpdates`, `-packageCachePath`, `HOME`, `CFFIXED_USER_HOME`, and XDG
cache redirects did not relocate both writes. The temporary project avoids
those manifest writes by removing the package reference for this compile check.

Verified with Xcode 27.0:

```sh
CW_SANDBOX_BUILD_ROOT=/private/tmp/morsejogger-sandbox-verify3 scripts/sandbox_build.sh ios
CW_SANDBOX_BUILD_ROOT=/private/tmp/morsejogger-sandbox-verify3 scripts/sandbox_build.sh catalyst
```

Both commands exited 0 and printed `** BUILD SUCCEEDED **`. Products were
created at:

- `/private/tmp/morsejogger-sandbox-verify3/xcode/ios-simulator-derived/Build/Products/Debug-iphonesimulator/MorseJogger.app/MorseJogger`
- `/private/tmp/morsejogger-sandbox-verify3/xcode/catalyst-derived/Build/Products/Debug-maccatalyst/MorseJogger.app/Contents/MacOS/MorseJogger`

Xcode logs warnings about unavailable CoreSimulator services and denied
developer log paths in this sandbox; they did not prevent these SDK compile
checks from succeeding.
