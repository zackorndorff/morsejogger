# Morse Jogger (SwiftUI + portable Swift contest core)

Morse Jogger is a native iOS port of Morse Runner Community Edition (MRCE). The interface is SwiftUI, the audio graph is AVAudioEngine, and the simulation, scoring, station and operator state, history import and logs live in a platform-independent Swift package. There is no web view, JavaScript or browser audio in the app.

## Game purpose and training behavior

Morse Jogger is for practicing CW contest operating. The player listens to simulated stations, copies callsigns and exchanges into the entry fields, sends their own messages with the command controls, and logs contacts. Caller replies and competing signals provide practice in copying, timing, and accuracy. Session time, score, contact counts, and direct feedback about the player's own input or actions are useful UI.

In normal practice, let the CW carry information about simulated callers. Do not turn internal event payloads or hidden simulation state—such as caller recognition, replies, retries, arrivals, or QRM conditions—into activity or status announcements. Keep incoming transcripts hidden so the player copies them by ear. This does not prohibit direct input validation or confirmation of the player's own actions.

Preserve configured learning aids: settings can explicitly show correct answers or callsign information, and Sweepstakes history can prefill a check and section according to its configured rate. After a contact is logged, the log and results can show copied versus expected values and the diagnosis. These aids and post-contact feedback are distinct from live announcements of what the player is meant to hear.

## Repo layout

| Path | What it contains |
|---|---|
| `Sources/MorseJoggerCore` | The portable core: contest definitions and rules, the simulator, callers, keyer timing, the MRCE receiver DSP, history parsing, seeded RNG |
| `Sources/MorseJoggerWasmCLI` | `morsejogger-wasi`, a JSON-lines stdin/stdout host over the core (native or WASI) |
| `Tests/MorseJoggerCoreTests` | XCTest suite for the core, including comparisons with fixtures generated from MRCE's Pascal source |
| `iOS/MorseJogger` | The app: SwiftUI views, view model, session driver, AVAudioEngine renderer, recording, file import |
| `iOS/MorseJogger.xcodeproj` | Xcode project; depends on the local `Package.swift` only |
| `tools/mrce-oracle` | Builds the Pascal-derived test fixtures from the pinned MRCE commit |
| `.upstream/MorseRunner` | Read-only checkout of MRCE for reference, if present. Never edit it |
| `scripts` | Build, test and acceptance scripts |

## Build and test

Use `scripts/sandbox_build.sh`; it keeps build products outside the repository (see `docs/SANDBOX_BUILD.md`).

```sh
bash scripts/sandbox_build.sh test
bash scripts/sandbox_build.sh test --filter CallRekeyTests
bash scripts/sandbox_build.sh host
bash scripts/sandbox_build.sh ios
```

`test` runs the package tests. `host` runs the checks that live outside the SwiftPM test target (`SessionDriver` contract tests, settings store and SCP data service checks, and the JSON-lines CLI); run it after touching `SessionDriver.swift`, `SettingsStore.swift`, `SCPDataService.swift` or the CLI. `ios` compiles the app against the installed Apple SDK from a disposable project copy; it does not run the app. Run `test` and `ios` before committing a change that touches the core or the app. None of these tells you what a change sounds like or how the keyboard behaves: say so when a change needs a try on a device.

On a Mac with Xcode, `iOS/MorseJogger.xcodeproj` opens and runs directly (iOS 17 or later) once `iOS/Local.xcconfig` exists: copy `iOS/Local.xcconfig.example` and set `SCP_CONTACT`, the address sent in the SCP download's User-Agent, and `DEVELOPMENT_TEAM`, your Apple team ID (needed only to sign for a device). The file is gitignored and the build fails without it; `sandbox_build.sh` supplies an empty one when it is missing. `SCPDataService` never sends a request without the app version (`MARKETING_VERSION`) in the User-Agent. `scripts/mac_acceptance.sh` builds for the simulator; `scripts/wasm_acceptance.sh` cross-builds the WASI host when a matching Swift WebAssembly SDK is installed.

## Working with MRCE

- Fidelity to MRCE is the goal unless `docs/INTENTIONAL_DIFFERENCES.md` lists the difference. Read the Pascal source for the behaviour in question before changing it, and name the procedure in a comment or test.
- The pinned MRCE commit is in `tools/mrce-oracle/README.md`. Where a unit compiles under FPC, check against compiled Pascal rather than a reading of it.
- Three documents record the state of the comparison. Keep them current when behaviour changes:
  - `docs/INTENTIONAL_DIFFERENCES.md`: deliberate differences.
  - `docs/KNOWN_DIFFERENCES.md`: differences found and not addressed, and what has not been compared.
  - `FABLE_REVIEW.md`: the log of what was compared, found and fixed.
- `docs/CALLSIGN_DATA.md` covers where callers come from. Do not bundle or fetch MRCE's call-history or entity files, or add any other data source, without the owner's decision; the licensing is unresolved.

## Implementation notes

- 13 MRCE contests plus the experimental POTA extension.
- Settings persist in `UserDefaults`. `ContestSettings` uses synthesized `Codable`, so a new field must be optional or have a default that decodes from older saved settings.
- `seed=0` lets the app choose a random seed; a nonzero seed reproduces a session for that version of the core.
- `ContestSimulator.tick(_:)` takes elapsed session seconds from the host. The host acknowledges transmit and receive audio so that simulator state does not run ahead of what is heard.
- The simulator tells the host what to do through `RadioEvent`s. Own transmissions are separate keyer pieces; a `.rekey` event amends one that is still being sent, and `.advanceEntry` moves the cursor.
- Audio is rendered at 11,025 Hz in a port of MRCE's receiver (mixer, filter, AGC, QSB, QRN, QRM). The render callback is real-time: no allocation or locks there.
- File imports never upload anything. `.dta` is validated as MRCE `MASTER.DTA`; text can be an `!!Order!!` call history, an ARRL 10m TSV or a plain call list.
- `BUGS.md` and `docs/human-docs.md` are the owner's own notes. Leave them alone unless asked.
- `README.md` is written by humans only. Do not edit it; suggest changes to the owner instead.
