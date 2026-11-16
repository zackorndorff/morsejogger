# Compiled Pascal conversation oracle

This developer tool builds a compact, committed set of reference conversations
from extracted MRCE Pascal code. Swift tests consume the generated JSON without
requiring FPC. It does not add Pascal to the app or package.

## Provenance and extraction

The source is pinned to MorseRunner commit
`304e51aece5a17f4cba548527816a385a8f6f814`. The generator
reads files with `git show <pin>:<path>` from a supplied checkout, so local
working-tree edits do not enter the oracle. It extracts the original
`TDxOperator` constructor, patience and state methods, message handler, reply
selector, `TStationMessage` declarations, and `RndRayleigh` implementation.
The method bodies are retained verbatim except for replacing the INI-qualified
LIDs read with a support global and the UI-owned `Tst.Me.HisCall` read with a
fixed placeholder (`K1AB`). That call value cannot affect these transitions:
the extracted `CallConfidenceCheck` is a boundary stub driven by the explicit
match input. The runner also stubs `IsActiveInQso` from the active-caller input,
exposes private fields for fixture setup, and disables the QRS callback. The
generated units retain the upstream MPL 2.0 license header.

The fixed Cartesian input matrix contains 40,320 reply-policy combinations,
480 silent-patience combinations, and 1,584 message-transition combinations
(42,384 total). These counts are input combinations, not unique scenarios,
branches, or session-coverage counts; many combinations exercise the same
branch. The matrix varies state, mode, contest, patience, reply style, counter,
message, match class, active-caller boundary, and deterministic random draw
inputs. Single/HST transitions are used where necessary to make exchange
acceptance deterministic.
`GetReply` comparisons check reply enum, reply-side counter/flag changes, and
random draw counts. Patience and transitions compare the state fields that
their Swift adapters expose.

These are extracted-policy comparisons, not full application or executable
equivalence. Caller matching and regex behavior, multi-caller arbitration,
QRS callbacks, station/arrival timing, contest exchange rendering, and random
distribution behavior are excluded. The runner supplies match result and active
caller status as input boundaries and disables QRS. Transition tests do not
compare a newly randomized `NeedQso` patience value. For B4 transitions that
fail a caller, Swift omits Pascal's final patience decrement after marking the
caller Failed; caller removal makes this difference inert. FPC 3.2.2 compiles
the extracted source; it is not the pinned Windows Delphi build, so Delphi
binary/runtime equivalence is not claimed.

## Requirements and use

Requirements: Git, Python 3, Free Pascal Compiler (FPC) 3.2.2 with its `fpjson`
unit, and a local checkout containing the pinned commit. The generator does
not use the network, download dependencies or source, or bundle upstream data.
By default it reads `.upstream/MorseRunner`; use `--upstream` to point to another
existing checkout.

On macOS, generate vectors and run the opt-in XCTest filter:

```sh
python3 tools/mrce-oracle/generate.py --output /private/tmp/mrce-oracle.json
MRCE_ORACLE_FIXTURES=/private/tmp/mrce-oracle.json bash scripts/sandbox_build.sh test --filter CompiledPascalCallerTests
```

On Linux, generate and run with `/tmp` paths:

```sh
python3 tools/mrce-oracle/generate.py --output /tmp/mrce-oracle.json
MRCE_ORACLE_FIXTURES=/tmp/mrce-oracle.json swift test --filter CompiledPascalCallerTests
```

The large policy matrix fixture is generated outside the repository and is not
committed. Running the ordinary suite without `MRCE_ORACLE_FIXTURES` explicitly
skips those matrix-only tests. These vectors have separate provenance from the
existing browser-derived source fixtures.

## Compiled Pascal conversation fixtures

The compact `Tests/MorseJoggerCoreTests/MRCEConversationFixtures.json` fixture
records three four-step single-caller conversations: CQ, two explicit wildcard
correction entries, and a final correct, wildcard, or valid inexact callsign.
The test runner extracts the active `Main.ProcessEnter` block, contest
`OnExchangeEditComplete` and `SetHisCall`, contest message templates, and the
production `TDxOperator` methods from the pinned source. It keeps one operator
instance across every step. Callsign matching and entered-call validity are
explicit boundary inputs; no matching policy is reimplemented by this harness.
The conversation settings record `pascalDraw: 0.5` explicitly. This is the
deterministic draw supplied to the extracted Pascal operator; the native Swift
seed is metadata for the compared run and does not seed Pascal's RNG.

Example transcript from `final-correct`:

| Step | User input | Local TX | Caller RX |
|---|---|---|---|
| CQ | CQ | `CQ VE3NEA TEST` | `K1ABC` |
| partial 1 | `K1AB?` | `K1AB?` | `K1ABC K1ABC` |
| partial 2 | `K1A?` | `K1A?` | `K1ABC K1ABC` |
| final | `K1ABC` | `K1ABC 5NN 001` | `R 599 001` |

These are compact policy conversations. The fixture supplies callsign-match and
valid-call results at the harness boundary; its renderer substitutes the
extracted contest templates' `<my>`, `<his>`, and `<#>` tokens. It does not
exercise audio, caller arrivals, the production random-number generator, or a
full Delphi executable/runtime comparison. The adapter raises on unsupported
exchange validation, NAQP locality, QSO persistence, and unextracted message
templates rather than returning invented results.

Regenerate and verify stable output with:

```sh
python3 tools/mrce-oracle/generate.py --conversations --output Tests/MorseJoggerCoreTests/MRCEConversationFixtures.json
```

Run the focused Swift test against the committed JSON without FPC:

```sh
bash scripts/sandbox_build.sh test --filter MRCEConversationTests
```

The fixture is read by the normal Swift test target and embeds SHA-256 hashes
for all extracted upstream units, plus compiler, target, pin, and regeneration
command. FPC is needed only to regenerate it. The separate large policy matrix
above remains opt-in and is not committed.

## Recorded validation

The current ordinary Swift suite passed 265 tests with 7 skips (3 opt-in
oracle-matrix tests and 4 existing skips). The committed conversation test
runs all three four-step traces without an environment variable or FPC.
The parallel oracle matrix also passed all 42,384 comparisons, with 3 matrix
tests and no failures. A disposable iOS SDK project build succeeded; it does not
represent a manual device run or a full build of the original project.

The separately recorded policy-matrix full-suite run used FPC 3.2.2 on Darwin AArch64 and passed 264
XCTest cases, with 4 existing skips and zero failures; all 42,384 oracle input
combinations were exercised. A negative-control fixture with the first reply
counter increased by one failed the focused test with an actionable vector
diagnostic. This validates that the comparison gate detects a mismatch; it does
not expand the parity scope described above. The committed conversation fixture
is covered by the newer ordinary-suite result above.

Conversation-test negative controls also detected regressions: restoring the
old exchange completion behavior changed the final correct RX to `NR? · R 599
001` and caused the valid-inexact flow to emit an extra RX reply. Restoring the
native fix returned the focused test to passing.

## Keyer timing vectors

`generate_keyer.py` compiles the pinned `VCL/MorseKey.pas`, `VCL/FarnsKeyer.pas`
and `VCL/MorseTbl.pas` unmodified, with a one-type stand-in for `SndTypes` and
the driver in `keyer_runner.pas`. It writes each keyed element's start and
length, and the message length, in samples at 11,025 Hz. Unlike the caller
vectors, the result is committed and the Swift test always runs:

```sh
python3 tools/mrce-oracle/generate_keyer.py --output Tests/MorseJoggerCoreTests/MRCEKeyerFixtures.json
bash scripts/sandbox_build.sh test --filter MRCEKeyerOracleTests
```

Element lengths in the fixture have the keyer's 149-sample ramp-off tail
removed, so they are the nominal keyed length. FPC is not the pinned Delphi
build; the vectors depend only on integer arithmetic and `Round`, but Delphi
binary equivalence is not claimed.

## WPX prefix vectors

`generate_prefix.py` pastes the pinned `CallsignUtils.ExtractPrefix` body,
unmodified, into `prefix_runner.pas`, compiles it and writes the WPX prefix
for a fixed list of calls. The result is committed and always checked:

```sh
python3 tools/mrce-oracle/generate_prefix.py --output Tests/MorseJoggerCoreTests/MRCEPrefixFixtures.json
bash scripts/sandbox_build.sh test --filter MRCEPrefixOracleTests
```

## Receiver level vectors

`generate_receiver.py` compiles the pinned `VCL/MovAvg.pas`, `VCL/Mixers.pas`
and `VCL/VolumCtl.pas`. Their code is untouched; the Windows GUI units they
list but do not use are dropped from `uses`, and `SndTypes` is a stand-in with
the same declarations. The driver in `receiver_runner.pas` configures the two
filters, the modulator and the AGC as `TContest.Create` does and calls them in
`TContest.GetAudio`'s order, over seeded noise plus six keyed tones (three
callers, two overlapping callers, and a full-level sidetone). It writes the RMS
of each 1024-sample window for six bandwidth and pitch pairs:

```sh
python3 tools/mrce-oracle/generate_receiver.py --output Tests/MorseJoggerCoreTests/MRCEReceiverFixtures.json
bash scripts/sandbox_build.sh test --filter MRCEReceiverOracleTests
```

The Swift test feeds the same input through `MRCEAudioRenderer.receiverTail`,
which is the function the live render path uses, and requires every window to
agree within 3%. The comparison is of loudness, not samples: the two carriers
are a quarter cycle apart and Pascal computes in single precision.

## Sweepstakes exchange-parser cases

`extract_ss_parser_vectors.py` reads MRCE's own unit test,
`Test/SSExchParserTest.pas`, at the pinned commit and writes the 272 cases
attached to its `RunTest` method: the text typed, and the serial, precedence,
check, section, embedded call and error MRCE expects. Nothing is compiled.

```sh
python3 tools/mrce-oracle/extract_ss_parser_vectors.py --output Tests/MorseJoggerCoreTests/MRCESweepstakesParserFixtures.json
bash scripts/sandbox_build.sh test --filter MRCESweepstakesParserTests
```

The Swift test applies the Pascal test's own rule: an exact match when the
exchange validates, and otherwise the expected text must be contained in
`<summary>-<error>`.
