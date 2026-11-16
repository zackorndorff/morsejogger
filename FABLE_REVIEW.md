# Fable review — playability and MRCE fidelity (2026-11-12)

## Scope and method

I read the Swift core (`Simulator.swift`, `Rules.swift`, `MRCEAudioDSP.swift`, `MorseDSP.swift`, `RadioPlayback.swift`), the iOS shell (`SessionDriver`, `FieldViewModel`, `FieldAudio`, `GameView`), and compared them with the pinned MRCE source in `.upstream/MorseRunner` (`DxOper.pas`, `DxStn.pas`, `Station.pas`, `MyStn.pas`, `StnColl.pas`, `Contest.pas`, `Main.pas`).

Findings marked **Reproduced** were confirmed by driving the built `morsejogger-wasi` host with seeded sessions at the app's 80 ms tick, or by rendering audio through `MRCEAudioRenderer` in a scratch package. Findings marked **From reading** were not run. Nothing was run on a simulator or device, and no repository file other than this one was changed.

Baseline: `swift test -j 4` passes (272 tests, 7 skipped, 0 failures). None of the findings below is caught by the suite.

The per-caller state machine (`OperatorFSM`, `OperatorReplyPolicy`, patience, QRS) matched `DxOper.pas` everywhere I checked. The problems are almost all in the layer around it: when callers transmit, what they transmit, how Enter is interpreted, and the audio mix.

## Summary

| # | Finding | Status |
|---|---|---|
| 1 | Pileup callers take turns instead of overlapping, and some never call again | Reproduced |
| 2 | Waiting callers do not call after TU | Reproduced |
| 3 | Callers send `599 001`, never `5NN` or cut numbers | Reproduced |
| 4 | Enter with only the RST filled logs a busted QSO instead of sending `?` | Reproduced |
| 5 | A correct QSO is scored NIL if TU lands just before the caller's repeat | Reproduced |
| 6 | F5 then F2 makes the caller send `NR?` and then the exchange | Reproduced |
| 7 | What is transmitted depends on hidden caller state | Reproduced |
| 8 | LID callers send a wrong serial and never correct it | From reading |
| 9 | Sidetone moves with RIT and disappears at narrow bandwidth | Reproduced |
| 10 | Caller pitch spread is too narrow for RIT and bandwidth to matter | From reading |
| 11 | The simulation timer stops while the game screen is being scrolled | From reading |
| 12 | Smaller differences | Mixed |

## 1. Pileup callers take turns instead of overlapping

**Where:** `Simulator.swift:523` (tick loop), `:806-815` (`acknowledgeReceive`), `:816-841` (`reply`); `FieldAudio.swift:536`.

In MRCE every caller has its own timers (`DxStn.pas`, `ProcessEvent`). After a CQ each caller waits its own random 0.1–0.6 s and sends. Each then repeats on its own 3–5 s timeout, so callers keep landing on top of each other.

Here there is one global `rxBusyUntil`. A caller whose timer expires while any other caller is audible is skipped, and `acknowledgeReceive` then pushes every other caller's timer past the end of that audio. The result is one overlapping burst after CQ, then strictly one caller at a time.

Seed 4242, WPX pileup, activity 6, one CQ and no further operator action:

```
 7.04 RX N7HPT | YU6E | K4CEL | K0W      (all start together)
12.64 RX YU6E
15.20 RX N7HPT
18.64 RX K4CEL
22.24 RX YU6E
25.28 RX N7HPT
...                                      (K0W never calls again)
```

Two further consequences:

- **Starvation.** The tick loop walks `pileup` in index order and the first expired timer wins, so later callers rarely get a turn. In HST (seed 5) two of the four callers alternated for 25 s while the other two sent once or not at all.
- **No patience loss.** A skipped caller does not decrement patience, and after 15 s late its timer is simply rescheduled (`:524`). Starved callers therefore do not give up either.

The first burst is also unlike MRCE: all voices share one start time with a fixed 35 ms stagger per voice, rather than independent 0.1–0.6 s delays.

This removes the core skill the pileup mode exists to train. After the first burst there is never more than one signal to copy.

**Fix direction:** give each station its own send delay and reply timer, and let receive events overlap. Only the operator's own transmission should hold callers off (MRCE sets `TimeOut := NEVER` on `evMeStarted`).

## 2. Waiting callers do not call after TU

**Where:** `Simulator.swift:1292-1312` (`afterTu`), `:1503-1508` (`afterLog`); compare `:1143` (`afterCq`).

In MRCE every station reacts to every message the operator finishes. A caller parked in `osNeedPrevEnd` moves to `osNeedQso` on TU and sends its call after its 0.1–0.6 s send delay (`DxStn.pas`, `evMeFinished`). So the rhythm is TU, then the rest of the pile calls immediately along with any new arrivals.

Here `afterTu` runs the state transition but nobody replies. `afterLog` announces only new arrivals. `afterCq` does pass the waiting callers as `repeating:`, so the behaviour is right after CQ and wrong after TU.

Seed 99, activity 4. PY4E called with WB6ACK at 6.24 s. After WB6ACK was logged at 27.12 s only a new arrival was heard, and PY4E stayed silent until the next CQ at 90 s. Later in the same run two leftover callers each came back about 4 s after a TU, one at a time. When a TU produces no new arrival there are several seconds of dead air where MRCE would have callers.

A related gap: a bare F3 TU never triggers arrivals, because `afterLog` runs only when `completedQSO` is true (`:1311`). MRCE adds callers after any TU once the log is non-empty (`Contest.pas`, `OnMeFinishedSending`). The F3 plus long-press "Save QSO" path therefore gets no new callers until the next CQ.

**Fix direction:** after TU, have every `needQso` caller reply as `afterCq` does, and run the arrival draw for any TU when the log is non-empty.

## 3. Callers send `599 001`, never `5NN` or cut numbers

**Where:** `Simulator.swift:1678` (`transmittedExchange = exchange`), `:1707-1735` (`stationExchange`).

MRCE's `Station.NrAsText` always converts `599` to `5NN`, and applies cut numbers to serials, zones and power: leading `000`/`00` become `TTT`/`TT`, remaining zeros usually become `T` or `O`, `9` usually becomes `N`, and CQ zones and power use `A`/`T`/`N` for 70% of stations. About 5% of callers send `ENN`.

Here the on-air text is the canonical exchange. Every trace shows `R 599 001`. The receive side already accepts cut numbers (`Rules.swift`, `cutNumeric`), so only transmission is missing.

Effect: copying cut numbers is not practised at all, and each exchange is much longer. `599 001` is 117 dit units against 61 for `5NN TT1`, about 2.7 s extra per exchange at 25 WPM. The Fast 5NN option also speeds up a spelled-out `599`.

**Fix direction:** render `transmittedExchange` through a port of `NrAsText`, using the station's own RNG stream, and keep `exchange` canonical for scoring.

## 4. Enter with only the RST filled logs a busted QSO

**Where:** `Simulator.swift:685-712`; `Rules.swift:423`; `FieldViewModel.swift:555-559`; `GameView.swift:499-501`.

MRCE's `ProcessEnter` treats the RST box and the exchange box separately. If the exchange has been sent and the second box is empty, Enter sends `?` to ask for a repeat (`Main.pas`, `if N and (not R or not Q)`).

Here the two boxes are joined before the simulator sees them, so `599` alone counts as "exchange received". The default branch of `isExchangeStructurallyValid` then compares one received token with one expected token and passes. The app fills in `599` automatically when Enter or Space leaves the call field, so this state is reached on every QSO in an RST contest.

Seed 4242, single mode:

```
 4.00 >>> Enter  call=WG2MS exch=""       TX  WG2MS 5NN 001
12.56 RX  R 599 001
18.08 >>> Enter  call=WG2MS exch="599"    TX  TU
LOG   received "599", expected "599 001"
```

The operator who missed the number and presses Enter to hear it again gets a TU and a wrong log entry.

**Fix direction:** pass the two fields separately (or an "exchange field empty" flag) and apply MRCE's `R`/`Q` rules. Do not drop a lone report token in the structural check.

## 5. A correct QSO is scored NIL if TU lands just before the caller's repeat

**Where:** `Simulator.swift:754` (pending receives dropped on TX), `:835-838` (transmit ranges recorded when the reply is scheduled), `:1103-1104` (input rejected while the caller is "transmitting").

When a caller's timer fires, its reply is scheduled 0.1–0.6 s ahead and its transmit range is recorded immediately. If the operator keys up inside that gap, `sendTx` deletes the unheard reply but leaves the range. When the operator's message ends inside that phantom range the caller ignores it, as if it had been sending.

Seed 4242, single mode. The caller's exchange repeat was due at 23.28 s. Correct call and exchange each time:

| Enter pressed | Result |
|---|---|
| 21.84 s | TU acknowledged, logged correct |
| 22.88 s | TU acknowledged, logged correct |
| 23.04 s | "did not accept TU", logged NIL, repeat never heard |
| 23.20 s | "did not accept TU", logged NIL, repeat never heard |

In MRCE a station that is preparing to send switches to copying when the operator starts (`evMeStarted`), so this cannot happen. The window is short, but it recurs every few seconds per caller, and a short TU fits inside the phantom range of a five-second exchange. The operator gets a NIL with nothing audible to explain it.

The NIL is also permanent. `afterTu` adjudicates the row as soon as its own TU completes (`:1300`, `pendingID == rowID`), even though the caller is still in the QSO. In MRCE a later TU that the station accepts fills in the last log entry.

**Fix direction:** remove the caller's transmit range when its scheduled receive is cancelled, and leave the row pending while the caller is still active.

## 6. F5 then F2 makes the caller send `NR?` and then the exchange

**Where:** `Simulator.swift:735-752` (queued TX), `:1253-1267` (`afterHisCall`), `:1313-1321` (`afterExchange`).

MRCE accumulates the messages of one keyer burst in `Me.Msg` and delivers them once, so `<his>` followed by `<#>` is one event containing both, and the caller answers once.

Here each button schedules its own action. Both fire when the burst ends. The first moves the caller to `needNr` and queues `NR?`. The second moves it to `needEnd` and queues the exchange.

Seed 99:

```
10.00 >>> F5 WB6ACK      TX  WB6ACK
10.00 >>> F2             TX  5NN 001
18.80 RX  WB6ACK: NR?
21.36 RX  WB6ACK: R 599 001 599 001
```

F5 then F2 is the natural button sequence on a phone, and it is MRCE's Insert key. Enter is not affected, because it sends a combined call-and-exchange input.

**Fix direction:** collect the message set for a burst and deliver one combined input per station when the burst ends.

## 7. What is transmitted depends on hidden caller state

**Where:** `Simulator.swift:1153`, `:1164`, `:1323`, `:683`.

MRCE always keys what the operator asks for. Here:

- If the typed call matches no caller, Enter transmits `CALL ?` instead of `CALL 5NN 001` (`:1164`). Reproduced with `ZZ9ZZZ`.
- If the pileup is empty, Enter with a call transmits nothing, and so does F7 `?` (`:1153`, `:1323`). Reproduced. The explanatory notices are not on the safe-text list, so nothing is shown.
- While no caller has been matched, Enter always resends the call (`:683`). The contact can never be logged. In MRCE the second Enter sends TU and saves, and the row is scored NIL.

The first case tells the operator by ear that the copied call is wrong, which is the kind of hidden-state leak `AGENTS.md` asks to avoid. The others make the keyer appear dead.

**Fix direction:** always transmit the requested message, deliver it to whatever stations exist, and let logging proceed without a matched target.

## 8. LID callers send a wrong serial and never correct it

**Where:** `Simulator.swift:1680-1686`. From reading.

With LIDs on, MRCE has 10% of callers send a wrong digit followed by `EEEEE` and the correct number, once (`Station.pas`, `NrWithError`). Repeats are correct.

Here about 2% of callers (22% LID × 10%) get a `transmittedExchange` whose serial is off by one. That value is used for every transmission, including repeats, while scoring compares against the true serial. The operator who copies perfectly is marked wrong, and asking for a repeat does not help.

Other LID behaviours in `DxStn.pas` and `Station.pas` are absent: non-599 reports (3% of callers), and the 22% `lid` flag here has no MRCE counterpart.

## 9. Sidetone moves with RIT and disappears at narrow bandwidth

**Where:** `FieldAudio.swift:126`, `:495`; `MRCEAudioDSP.swift:720`.

MRCE mixes the operator's own keying in at baseband, so the sidetone always sounds at the selected pitch (`Contest.pas`, "my audio"). Here the transmit program is a station at `pitch`, mixed against a receiver centred on `pitch + rit`, then filtered.

Rendered with pitch 450 Hz:

| Bandwidth | RIT | Sidetone frequency | RMS level |
|---|---|---|---|
| 550 | 0 | 450 Hz | 0.185 |
| 550 | +200 | 250 Hz | 0.144 |
| 300 | +200 | 250 Hz | 0.089 |
| 150 | +100 | 351 Hz | 0.125 |
| 150 | +200 | 259 Hz | 0.002 (inaudible) |

**Fix direction:** give transmit programs a zero baseband offset (frequency equal to the receiver centre) so they pass the filter at DC and come out at `outputPitch`.

## 10. Caller pitch spread is too narrow for RIT and bandwidth to matter

**Where:** `Simulator.swift:1611`. From reading.

MRCE draws each caller's offset from a limited Gaussian of ±300 Hz, or ±50 Hz in single-call mode (`DxStn.pas`). Here it is uniform ±90 Hz in every mode. `Station.shift` is drawn at ±180 but never used.

With the default 550 Hz bandwidth every caller sits well inside the passband, and even at 300 Hz none is attenuated much. RIT has nothing to tune to, narrowing the filter does not thin the pile, and callers are harder to separate by ear than in MRCE. Single-call mode has the opposite problem: callers are further off frequency than MRCE's.

QRM stations already use the ±300 Hz Gaussian (`QRMSourceModel.stationDraw`), so the helper exists.

## 11. The simulation timer stops while the game screen is being scrolled

**Where:** `FieldViewModel.swift:474`. From reading; needs a device check.

The session tick is a `Timer.scheduledTimer`, which runs only in the default run-loop mode. The game screen is a `ScrollView`, and UIKit switches the main run loop to tracking mode while a finger is scrolling. During that time `tick()` does not run: no caller audio is dispatched and nothing the operator sent is processed. Audio already queued keeps playing. On release the simulator jumps forward and everything overdue is delivered at once.

On an iPhone with the keyboard up, scrolling to reach the log or the command buttons is routine.

**Fix direction:** add the timer to `RunLoop.main` in `.common` modes, or drive ticks from a `DispatchSourceTimer`.

## 12. Smaller differences

- **QSB and flutter are tied to audio slots, not stations** (`MRCEAudioDSP.swift:411-420`, from reading). The fade rate, including the 30% flutter choice, is drawn the first time a slot is used and never again for the life of the app. Turning Flutter on after a slot has been used with QSB has no effect on that slot, and a slot that drew flutter keeps it. Flutter alone also enables fading, where MRCE requires QSB.
- **Doubling is not penalised the MRCE way** (`Simulator.swift:1103`). In MRCE a station that was sending when the operator started, and finished first, hears garbage unless the message contains CQ, TU or NIL. Here only stations still sending at the end of the operator's message miss it.
- **Commands use a stale clock** (`SessionDriver.swift:113-117`). `send` does not tick the simulator first, so a command is timestamped up to 80 ms early. This widens the window in finding 5.
- **Sweepstakes history hint is drawn from the caller's behaviour stream** (`Simulator.swift:1213-1225`), so the "Show check/section" rate changes that caller's later replies for a given seed.

## Checked and found consistent with MRCE

- Operator state transitions for CQ, NIL, B4, TU, `?`, `NR?`, garbage, call and exchange (`OperatorFSM.transition` against `TDxOperator.MsgReceived`).
- Reply selection, including the `NR?`/`AGN` counter and the R2-based correction styles (`OperatorReplyPolicy` against `GetReply`).
- Patience: `3 + Round(RndRayleigh(3))` on `needQso`, `MorePatience`, Caller Stays, ghosting at zero, QRS thresholds and drop factors.
- Call matching: wildcard, edit-distance and substring confidence, best-match threshold, LID accept/reject odds.
- Arrival count: Poisson(activity/2) minus active callers, with the three-empty-draws forced arrival.
- Reply timeout and send-delay distributions, and station amplitude (`9000 + 18000 × (1 + U-shaped)`).
- Station ID cadence (`TU <my>` every `stationIdRate` contacts), single-call start-up, caller serial growth with elapsed minutes.
- QSK off mutes the receiver during transmit; the noise bed runs continuously.

## Suggested order

1. Findings 4, 5 and 7: they produce wrong log entries or a dead keyer during ordinary Enter-driven operation, and each is a contained change.
2. Findings 1 and 2 together: both come from the single shared receive timeline, and fixing them restores pileup behaviour.
3. Finding 3, then 8, which shares the same rendering function.
4. Findings 9 and 10 (audio and tuning), then 6 and 11.

Findings 1, 2, 4, 5, 6 and 7 can each be pinned by a seeded core test using the traces above.

# Second audit (2026-11-12)

Done after findings 1–11 were fixed. I read the remaining MRCE units (`MorseKey.pas`, `FarnsKeyer.pas`, `QrmStn.pas`, `QrnStn.pas`, `SerNRGen.pas`, `Log.pas`, `CallsignUtils.pas`, and the per-contest `SendMsg`/`GetExchange` overrides) against the Swift core. For keyer timing I compiled the pinned Pascal keyers with FPC 3.2.2 and compared element by element.

Everything in the first table is fixed in the working tree and covered by a test. `swift test` passes (326 tests, 7 skipped) and the iOS SDK build succeeds. Nothing here was run on a device.

## Differences found and fixed

| # | Difference | MRCE source | Test |
|---|---|---|---|
| A1 | Farnsworth spacing differed from MRCE's SST keyer: the gap after the last element used four character-rate units instead of four stretched units (0.85 s short for `E` at 10/25 WPM), and character gaps were rounded differently. | `FarnsKeyer.pas` | `MRCEKeyerOracleTests` |
| A2 | Faster-5NN gaps inside and after the report were a few samples off, because spacing went through the Farnsworth formula. | `MorseKey.pas` | `MRCEKeyerOracleTests` |
| A3 | Extra spaces in a message were collapsed. MRCE keys each one as two more units, which matters for `QRL?   QRL?`, `<his>  QSY QSY` and the CWT exchange `<name>  <number>`. | `MorseKey.Encode`, `Contest.SendMsg`, `Station.NrAsText` | `MRCEKeyerOracleTests`, `ContestMessageTests` |
| A4 | QRM stations called CQ with the operator's call. MRCE uses the QRM station's own call, with contest-specific forms (`CQ CQ CWT`, `CQ CQ SST`, `CQ CQ SS … SS`, `CQ CQ FD … FD`). Only QSY names the operator. | `QrmStn.pas`, contest `SendMsg` | `ContestMessageTests` |
| A5 | CWT callers always sent `R` before the exchange. MRCE omits it nine times in ten. | `CWOPS.pas` | `ContestMessageTests` |
| A6 | SST callers always sent `R <exchange>`. MRCE sends `R` one time in ten and a greeting (`GM`/`GA`/`GE` plus the operator's name, fixed per caller) one time in five. | `CWSST.pas` | `ContestMessageTests` |
| A7 | Repeat requests were always `NR?`. SST callers also ask `NAME?` or `ST?`, and Field Day callers `SECT?`, `CLASS?` or `CL?`, chosen per caller. | `CWSST.pas`, `ArrlFd.pas` | `ContestMessageTests` |
| A8 | The operator's TU in SST was a bare `TU`. MRCE always sends `TU <my>` there. | `CWSST.pas` | `ContestMessageTests` |
| A9 | In SST the operator's own sending ignored the Farnsworth character rate. MRCE keys the operator's characters at that rate when it is above the sending speed. | `MyStn.SetWpm` | `OwnFarnsworthSendingTests` |
| A10 | Every Sweepstakes caller sent precedence `A` unless imported history supplied one. MRCE draws it per caller: 43% A, 19% B, 28% U, 10% Q/M/S. | `ArrlSS.GetExchange` | `CallerExchangeGenerationTests` |
| A11 | Sweepstakes and ARRL 10m DX serials in the default range started at 1–12 and crept up with the clock. MRCE draws `1 + Random(175)` from the first caller. WPX and HST keep the time-based rule. | `Ini.TSerialNRSettings.GetNR` | `CallerExchangeGenerationTests`, `ParityExpansionTests` |
| A12 | Callsign validity was "three characters with a letter and a digit". MRCE requires a match for `(([0-9][A-Z])\|([A-Z]{1,2}))[0-9][A-Z0-9]*[A-Z]`, so `K12` does not yet trigger the exchange on Enter. The Swift comment said the source was unavailable; it is in `Util/CallsignUtils.pas`. | `CallsignUtils.IsValidCall` | `CallsignValidityTests` |

A11 replaced expectations that came from the earlier web engine rather than from Pascal: the three Start samples in `SerialFixtures.json` are now checked against the Pascal formula, and `testOtherContestStartSerialKeepsItsExistingHourlyDispatch` became `testOtherContestStartSerialUsesTheDefaultRangeWhateverTheClock`. A3 replaced `testWhitespaceVariantsRepresentTheSameWords`.

## The keyer oracle

`tools/mrce-oracle/generate_keyer.py` extracts `MorseKey.pas`, `FarnsKeyer.pas` and `MorseTbl.pas` from the pinned commit, compiles them unmodified with a small driver (`keyer_runner.pas`) and writes `Tests/MorseJoggerCoreTests/MRCEKeyerFixtures.json`: 349 messages across both keyers, 12–60 WPM, Farnsworth pairs and Faster-5NN markers. The test requires every element's start and length and the message length to match to the sample at 11,025 Hz, so the suite needs no Pascal compiler.

Before the change, 171 of the 349 vectors differed (57 Farnsworth, 72 Faster-5NN, 42 multi-space). The standard keyer already matched on single-spaced text. `MorseTimeline` now mirrors the two keyers directly and all 349 match.

## Differences found and left alone

These are real but small, or are product choices. None is fixed.

- **QSK depth ignores the monitor level.** MRCE's receiver gain while keying is `1 − monitor gain × envelope`, so with the monitor turned down you hear the band through your own keying. Here the receiver is fully muted at key-down whatever the monitor level (`MRCEAudioDSP.swift`, `wanted = 1 - min(1, txKey*7)`).
- **Editing the call while it is being sent.** MRCE re-keys the remainder of the call when the call field changes mid-transmission (`MyStn.UpdateCallInMessage`). Not implemented.
- **Logging a call that still contains `?`.** MRCE's `SaveQso` strips the `?` and logs the rest. Here Enter refuses to log.
- **Raw score counts dupes** in MRCE (`Log.UpdateStats`); here dupes add no raw points.
- **Scoring is stricter in MRCE for a few fields.** IARU zone, ALLJA and ACAG compare the typed text exactly; here a cut or zero-padded form is also accepted.
- **HST contest outside HST competition mode** suppresses cut numbers here; MRCE suppresses them only in HST run mode.
- **Which keyer** is inferred from the character rate. In SST at or above the Farnsworth character rate, a double-spaced message (only the QRM `QSY` text) gets the standard keyer's shorter extra gap.
- **Defaults differ:** pitch 450 Hz and bandwidth 550 Hz here, 600 Hz and 500 Hz in MRCE.
- **Durations in the simulator** are computed at 44.1 kHz and are not padded to MRCE's 512-sample blocks, so a caller's "finished sending" moment can differ from MRCE's by up to about 46 ms.

## Checked in this pass and found consistent

- Standard keyer element timing on single-spaced text, 12–60 WPM (sample-exact against compiled Pascal).
- QRM arrival rate, patience, retry delay, speed, pitch and amplitude; QRN impulse rate, burst rate, duration and amplitude.
- HST call score (`CallToScore`), dupe rule, NAQP DX state handling, serial increment on save.
- WPX Mid/End serial distribution bins, custom range and exclusive upper bound.
- RIT step and limits, bandwidth-to-filter mapping, monitor gain curve.

## Follow-up decisions (2026-11-13)

From the "found and left alone" list above:

- **Fixed to match MRCE:** logged fields are read the way MRCE reads them (reports and WPX/HST/Sweepstakes serials in digits; CQ zone, power and ARRL 10m serials with MRCE's cut-letter reduction; IARU, ALLJA and ACAG as exact text); SST always uses the Farnsworth keyer; default pitch and bandwidth are 600 Hz and 500 Hz.
- **Kept on purpose**, and documented in the README under "Intentional differences from MRCE": QSK muting, no re-keying of an edited call, no logging of a call containing `?`, raw score excluding dupes, and the HST contest never cutting serials.
- **Recorded only:** the 512-sample padding of a caller's transmission.

# Third audit: points and multipliers (2026-11-13)

I compared every contest's `ExtractMultiplier` in the pinned source with `ContestRules.score`, and compiled `CallsignUtils.ExtractPrefix` with FPC to check the WPX prefix on 119 calls. `swift test` passes (329 tests, 7 skipped).

## Found and fixed

| # | Difference | MRCE source | Test |
|---|---|---|---|
| B1 | The WPX prefix, which is the WPX multiplier, was wrong for 24 of the 119 calls. Any call starting with a digit lost everything after it (`9A1A` gave `9`, `4X6TT` gave `4`), calls with a digit in the second position lost the district (`S51A` gave `S5`, `A61AA` gave `A6`), and most portable forms picked the wrong side (`DL/K1ABC` gave `K1`, MRCE `DL0`; `W1AW/KH6` gave `W1`, MRCE `KH6`). Distinct prefixes collapsed into one, so WPX multiplier counts and scores were too low. | `CallsignUtils.ExtractPrefix` | `MRCEPrefixOracleTests` |
| B2 | In CQ WW, Alaska and Hawaii each counted as their own country multiplier. MRCE counts both as the United States; points still follow their own entity. | `CqWW.ExtractMultiplier` | `CQWWMultiplierTests` |

`ContestRules.wpxPrefix` is now a direct port of `ExtractPrefix` and matches all 119 vectors. The generator is `tools/mrce-oracle/generate_prefix.py`; its output is committed, so the suite needs no Pascal compiler.

## Checked and found consistent

- Points and multiplier keys for ARRL DX, NAQP, CWT, SST, Field Day, Sweepstakes, IARU, ARRL 10m, ALLJA and ACAG.
- CQ WW points by continent and entity, and the zero-point `/MM` rule.
- Final score as points times multipliers, with HST scored from the call's Morse length.

## Noted, not changed

- MRCE computes points and multipliers from what the operator logged; here they come from the true station. The two agree for every verified QSO, which is the only kind that counts toward the verified score.
- A CQ WW caller whose entity cannot be resolved scores one point and a zone multiplier in MRCE and nothing here. Callers without a known entity are not generated for CQ WW, so this cannot occur in a session.

# Fourth audit: receiver audio and the end of the operator's transmission (2026-11-13)

I read `Contest.GetAudio`, `Qsb.pas`, `RndFunc.pas`, `VCL/MovAvg.pas`, `VCL/Mixers.pas`, `VCL/VolumCtl.pas`, `VCL/QuickAvg.pas` and the station mixing code against `MRCEAudioDSP.swift` and `FieldAudio.swift`, and compiled the filter, modulator and AGC with FPC to compare output levels. `swift test` passes (334 tests, 7 skipped) and the iOS SDK build succeeds. Nothing here was run on a device, and C1 and C2 change what is heard, so both need a listen on one.

## Found and fixed

| # | Difference | MRCE source | Test |
|---|---|---|---|
| C1 | Callers answered about 0.15 s late after every transmission by the operator. The core counted a transmission as lasting 0.10 s longer than its keying, and the app's audio acknowledgement then pushed that to 0.15 s after the time it arrived. MRCE ends a transmission at the next 512-sample block (0 to 46 ms) and the caller's send delay (0.1–0.6 s, or 0.05–0.175 s in HST at 40 WPM) starts there. In HST the pad roughly doubled the gap before each reply. Queued messages were also keyed 0.10 s apart; MRCE joins them. | `Station.GetBlock`, `Contest.GetAudio`, `DxOper.GetSendDelay`, `MyStn.AddToPieces` | `OwnTransmissionEndTests`, `CallerTimingTests` |
| C2 | The sidetone was about 30 dB below MRCE's at the same Monitor setting. MRCE mixes it at `gain × 300000` on both halves of the complex signal, which at 0 dB pins the AGC at its ceiling, so the operator's own keying is the loudest thing heard. Here it entered at 12,960, quieter than an average caller (27,000). | `MyStn.pas`, `Contest.GetAudio` | `MRCEReceiverOracleTests` |
| C3 | A logged contact whose caller never heard the TU stayed "Pending TU confirmation" after that caller had given up and left, until the operator's next CQ or TU. MRCE's `CheckErr` marks it NIL. The row now turns NIL when the caller leaves. Found while re-timing a test for C1. | `Log.CheckErr` | `EnterKeyerFidelityTests` |

For C1 the acknowledgement is now anchored to the transmit event's own time, so its arrival a tick late no longer moves anything. One timing test had fixed Enter times chosen around the old pad and was re-timed by 0.09 s.

## The receiver oracle

`tools/mrce-oracle/generate_receiver.py` compiles the three VCL units and runs seeded noise plus six keyed tones through them at six bandwidth and pitch pairs. `MRCEAudioRenderer.receiverTail`, which the live render path now calls, agrees with the compiled Pascal within 3% on every 1024-sample window (360 windows): filter gain and selectivity at 100–600 Hz, AGC compression from the noise floor to a saturating sidetone, and AGC recovery. No difference was found in that chain.

## Checked and found consistent

- Noise bed (`3 × 6000 × (Random − 0.5)` on each half) and QRN impulse rate and amplitude.
- Filter length `Round(0.7 × rate / bandwidth)`, three passes, gain `√(500 / bandwidth)`, and the two-filter swap every ten blocks.
- AGC constants (76 dB in and out, 20,000 ceiling, 155-sample attack and hold) and look-ahead.
- Key envelope: Blackman-Harris step response over `Round(2.7 × 5 ms × rate)` samples.
- QSB: gain law, per-station bandwidth draw (0.1–0.6 Hz, or 3–33 Hz for 30% of stations with Flutter), update every 128 samples with linear interpolation; none on the sidetone, QRM or QRN.
- RIT direction and station pitch: heard pitch is `pitch + station offset − RIT`.
- With QSK off, the operator's transmission replaces the receiver, noise included.
- The renderer runs at 11,025 Hz, so noise density and impulse statistics are MRCE's.

## Noted, not changed

- **QSB restarts with each transmission.** MRCE keeps one fading state per station and freezes it between that station's transmissions, so a station that ended in a fade starts its next transmission still faded. Here each transmission starts from a fresh draw at the station's own fade rate.
- **Pitch is not quantised.** MRCE's modulator rounds the pitch to a whole number of samples per cycle (600 Hz becomes 612.5 Hz, 450 Hz becomes 459.4 Hz). Here the pitch is exact.
- **QSB warm-up** is `3 × points` draws here and `3 × points + 1` in MRCE.
- `ContinuousRFNoise` and `CWReceiverDSP` in the core are not used by the app; only their own tests reach them.

# Fifth audit: who calls, run modes and the command layer (2026-11-13)

I read `DxStn.CreateStation`, `DxOper.Create`/`GetWpm`/`SetState`, `CallLst.pas`, `StnColl.AddCaller`, `TMainForm.Run`, the session-end code in `Contest.GetAudio`, `Main.pas` key handling (`FormKeyDown`, `FormKeyPress`, `SendMsg`, `WipeBoxes`, `ProcessSpace`, speed keys) and `Log.ShowRate` against the Swift core and view model. `swift test` passes (337 tests, 7 skipped) and the iOS SDK build succeeds.

## Found and fixed

| # | Difference | MRCE source | Test |
|---|---|---|---|
| D1 | With LIDs on, 11% of callers signed twice (`K1ABC K1ABC`), and a caller that also drew the ordinary pile-up repeat signed four times. MRCE has no such behaviour: LIDs affect the report (3%), the serial (10%) and call matching. The only double call is `RepeatCnt`, one pile-up caller in ten, with or without LIDs. | `DxStn.CreateStation`, `DxOper.SetState` | `CallerExchangeGenerationTests` |
| D2 | The QSOs/hour figure was the average since the session began. MRCE shows contacts in the last five minutes, per hour, so it follows the current pace. The two agree only for the first five minutes. | `Log.ShowRate` | `RateDisplayTests` |

## Checked and found consistent

- Caller speed: operator's speed in HST, `Wpm − Min … Wpm + Max` uniform or limited Gaussian otherwise, the half-to-full legacy rule, and the Farnsworth character rate in SST. Defaults (0 and 0) put every caller at the operator's speed, as in MRCE.
- Skill 1–3, patience, LID report and serial-error odds, caller amplitude and pitch.
- Call choice: uniform from the list, no caller repeated in HST, a call already on the air not chosen again.
- Competition modes: WPX competition forces all band conditions on; HST forces them off, activity 4, bandwidth 600 Hz and 50 Hz RIT steps; both use the competition duration.
- Session end: a pending TU is given up to 15 s to complete.
- Esc: aborts the transmission, callers hear garbage, and the call-sent and number-sent flags are cleared only for what was being sent.
- TU-and-log sends the call first only if it has not been sent; Wipe clears both flags.
- Notices about hidden caller state exist in the core's event stream, but `RadioActivityText.visible` drops everything except input validation and the operator's own actions, so none reaches the screen.

## Noted, not changed

- **Speed steps.** MRCE's PgUp/PgDn change speed by 2 WPM (to the next multiple of 5 in HST) and its floor is 10 WPM. The app's stepper moves by 1 and goes lower.
- **`AGN?` and `CALL?` commands** exist in the core (`Command.again`, `.callAgain`) and callers treat them as `?`. MRCE has only `?` (F7) and `NR?` (F12). The game screen offers only those two, so the extra commands are reachable only through the command host.
- **Custom F8 text and continuous pile-up (Ctrl-U)** are not implemented.
- **Minimum caller speed offset** is capped at 4 in MRCE when the operator is below 15 WPM; not here.

# Sixth audit: log adjudication and call-history loading (2026-11-13)

I read `Log.CheckErr`, `TQso.CheckExch1`/`CheckExch2`, `Log.UpdateStats`, `DxStn.DataToLastQso`, and each contest's call-history loader and `PickStation` (`ArrlDx`, `NaQp`, `CqWW`, `IaruHf`, `Arrl10m`, `ArrlFd`, `ArrlSS`, `CWOPS`, `CWSST`, `ALLJA`, `ACAG`, and the ARRL DX file reader) against `ContestRules`, the simulator's caller pool and the history importer. `swift test` passes (338 tests, 7 skipped) and the iOS SDK build succeeds.

## Found and fixed

| # | Difference | MRCE source | Test |
|---|---|---|---|
| E1 | One per-caller draw stood in for both `Station.R1` and `DxOper.R2`. In SST and Field Day that tied the wording of a caller's repeat request (`NR?`, `NAME?`, `SECT?`, …) to its call-correction style. The two are now separate draws. `R1` also sets the faster-5NN rate and the cut-number habit for zones and power, as in MRCE. | `Station.Init`, `DxOper.Create` | `ContestMessageTests`, `CallerExchangeTextTests` |

## Checked and found consistent

- A contact is verified only when the caller reached "done", the call matches exactly, every exchange field matches and it is not a dupe; a near-miss call that the caller accepted is logged without credit.
- Which callers are eligible: ARRL DX (W/VE work DX and the reverse), NAQP (stations outside North America hear only North American callers), entity-based contests need a resolvable entity, Sweepstakes needs a section, and Field Day's club, home and portable thinning.
- Rows a history file must have to be used (call plus the contest's exchange fields), and comment and `!!Order!!` handling.

## Noted, not changed

- **The log's error column is worded differently.** MRCE prints the correct values of whatever was miscopied (the right call, the right number), prefixed with `DUP` for a dupe, or `NIL`. The app shows a diagnosis and the expected exchange. The information is the same.
- **In the WPX custom serial range**, MRCE ties leading zeros to `R1 < 0.5`; here that choice has its own draw. The odds are the same.

# Seventh audit: where callers come from (2026-11-13)

The findings and the open decisions are in `docs/CALLSIGN_DATA.md`. In short: none of MRCE's per-contest call-history files are bundled, so on a fresh install callers come from the downloaded Super Check Partial list, which has calls and nothing else.

## Found and fixed ("Make callers without call history vary, stay consistent and fit the contest", 2026-11-13)

| # | Difference | Test |
|---|---|---|
| F1 | Without an imported history every caller sent the same CWT number (`1234`), Field Day class (`2A`), Sweepstakes check (`86`), ARRL DX power (`100`) and Japanese prefecture and city (`10`, `1002`). Those fields are now derived from the call and vary. | `CallerDataRealismTests` |
| F2 | A call heard twice sent a different name and state each time. Invented details are now fixed per call. | `CallerDataRealismTests` |
| F3 | States, provinces, sections and Japanese prefectures ignored the call area (`VE3` in `PE`). They now follow it. | `CallerDataRealismTests` |
| F4 | Every US station was CQ zone 5 and ITU zone 8, every Canadian zone 4 and 9. Zones now follow the call area. | `CallerDataRealismTests` |
| F5 | All JA and ACAG drew callers from the worldwide list. They now take only Japanese calls from a general list. | `CallerDataRealismTests` |
| F6 | No contest adjusted the worldwide mix, so Field Day, NAQP and SST were half DX. The US and Canada share now follows MRCE's own file for each contest. | `CallerDataRealismTests` |

## Not fixed, waiting for a decision

The built-in country table knows about 30 entities, so most DX calls are unusable in CQ WW, IARU, ARRL DX, ARRL 10m and NAQP. Fixing it needs a new data source. See `docs/CALLSIGN_DATA.md`.

# Eighth audit: Sweepstakes exchange entry (2026-11-13)

I read `Util/SSExchParser.pas`, `Util/Lexer.pas` and `Util/ArrlSections.pas` against `SweepstakesParser`, and ran MRCE's own parser tests (`Test/SSExchParserTest.pas`, 272 cases) against the app. `swift test` passes (346 tests, 7 skipped) and the iOS SDK build succeeds.

## Found and fixed

| # | Difference | MRCE source | Test |
|---|---|---|---|
| G1 | The Sweepstakes parser disagreed with MRCE on 207 of MRCE's 272 test cases. MRCE follows N1MM: fields in any order, fields run together (`23A86CT`), and a field typed again replaces the earlier one. The app kept the first value and reported "Duplicate precedence", "Duplicate section" or "Unrecognized or repeated token", so the normal way of correcting a miscopy (type it again) made the exchange invalid. Two-digit numbers were also assigned differently (`11 22 33` is serial 22, check 33 in MRCE). The parser is now a port and matches all 272. | `SSExchParser.pas` | `MRCESweepstakesParserTests` |
| G2 | The parser accepted cut numbers (`7T` as check 70, `NT` as a check). MRCE's lexer takes digits only, consistent with the earlier decision on logged serials. | `SSExchParser.pas` | `ContestExchangeAuditTests` |
| G3 | The section list had obsolete and non-Sweepstakes entries (`MAR`, `NT`, `NWT`, `NU`, `YT`, `ON`, `GTA`, `DX`) and lacked `TER`. It is now MRCE's 85 sections. | `ArrlSections.pas` | `ContestExchangeAuditTests` |

Error messages are now MRCE's ("Missing/Invalid Serial Number", "…Precedence", "…Check", "…Section"), one at a time in that order.

## Noted, not changed

- An imported Sweepstakes history row whose section is not in the current list is dropped on import. MRCE keeps such a row, but its parser could never accept that section either.

# Ninth audit: the entry boxes (2026-11-15)

I read `ExchFields.pas`, the per-contest `GetExchangeTypes` overrides, and `Main.pas` `Edit1KeyPress`/`Edit2KeyPress`/`Edit3KeyPress`, `Edit1Enter`/`Edit2Enter`/`Edit3Enter`, `ProcessEnter`, `ProcessSpace`, `Advance`, `ConfigureExchangeFields` and `FormKeyPress` against `GameView.swift`, `FieldViewModel.swift` and `ContestRules`. `swift test` passes (355 tests, 7 skipped) and the iOS SDK build succeeds. Nothing here was run on a device, and H2 and H3 are cursor behaviour in UIKit, so both need a try on one.

## Found and fixed

| # | Difference | MRCE source | Test |
|---|---|---|---|
| H1 | The exchange boxes took any character. MRCE filters each box key by key and turns cut-number keys into digits: `5NN` typed in the report box becomes `599`, `TT1` in the serial box becomes `001`, and `A`/`N`/`O`/`T` map in the CQ zone box. Since the follow-up to the second audit the log has read reports and serials in digits only, as MRCE does, so here a contact typed the way it sounded (`5NN`, `TT1`) was scored as a miscopy. The boxes now apply MRCE's filter, mapping and length for each contest's field type; HST competition takes digits only. | `Edit2KeyPress`, `Edit3KeyPress`, `ExchFields.pas` | `EntryFieldFilterTests` |
| H2 | Enter with a partial call (`K1?`, `K12`) moved the cursor to the exchange. MRCE advances only when the call is complete; otherwise the cursor stays in the call box, so the correction can be typed straight away. With a complete call MRCE goes to the second box in report contests and to the first box (name or class) otherwise, whichever box Enter was pressed in. | `ProcessEnter`, `Advance` | `EntryFieldFilterTests` |
| H3 | Nothing was selected when a box took the cursor. MRCE selects the `?` in the call, the middle digit of a three-digit report, and the whole of any other exchange box, so the next key replaces it. Applied when the cursor is moved by Enter, Space or Tab; a tap places the cursor as usual. | `Edit1Enter`, `Edit2Enter`, `Edit3Enter` | `EntryFieldFilterTests` |
| H4 | A key the call box rejects stayed visible in the box until the next accepted key, because the filtered value equalled the stored one and nothing was redrawn. The box is now put back at once. The call box also stops at MRCE's twelve characters (it was twenty). | `Edit1KeyPress`, `Main.dfm` | — |

## Checked and found consistent

- Space: from the call box to the second box in report contests (filling an empty report with `599`), to the first box otherwise, round to the call box from the last box, and a literal space in the Sweepstakes box.
- Which received field type each contest uses, including power or state in ARRL DX by the operator's side.
- The call box's accepted characters (letters, digits, `/`, `?`).

## Noted, not changed

- **When the cursor moves.** MRCE moves it when the operator's transmission ends; the app moves it at once.
- **Typing into a full box.** MRCE refuses the key. Here the text is cut at the field's length, so a character inserted in the middle of a full box pushes the last one out.
- **Keyboard shortcuts** `;` (his call and exchange), `.` `+` `[` `,` (TU and log), Insert, and the arrow and page keys for RIT and speed are not mapped on a hardware keyboard.
- **Power in ARRL DX** keeps cut letters as typed (`1TT`), as in MRCE; the log reduces them when comparing.

# Tenth audit: the operator's own exchange, the device audio path and whole sessions (2026-11-15)

Four parts: the operator's sent exchange (`Main.SetMyExchange`, `SetMyExch1`/`SetMyExch2`, the `ValidateMyExchange` overrides), the rest of `Station.pas` and `MyStn.pas` (`NrAsText`, `SendText`, `SendNextPiece`), `FieldAudio.swift` and `SessionDriver.swift` read end to end, and complete sessions played by a scripted operator. `swift test` passes (366 tests, 7 skipped) and the iOS SDK build succeeds. I1, I2 and J1 change what is heard and were not run on a device.

## Found and fixed

| # | Difference | MRCE source | Test |
|---|---|---|---|
| I1 | In WPX and HST the report and serial were keyed as two words (`5NN 001`). MRCE formats them with no space (`Format('%d%.3d', [RST, NR])`), so `5NN001` runs together with ordinary character spacing, for callers and for the operator. Each exchange is four dits shorter. | `Station.NrAsText` | `CallerExchangeTextTests`, `OwnExchangeTextTests` |
| I2 | The operator's own exchange was sent in plain digits. MRCE's own station always cuts numeric fields: `0` to `T` and `9` to `N` in a serial, CQ zone or power, and `1` to `A` in a CQ zone (and in power for 70% of sessions). Serial 1 is `5NNTT1`, zone 14 is `5NN A4`. At 25 WPM `TT1` is about 1.5 s shorter than `001`, so every contact was that much slower than in MRCE. The log still records `5NN 001`. | `Station.NrAsText` | `OwnExchangeTextTests` |
| I3 | In the Mid and End serial ranges the operator's first number was any value in the range. MRCE starts on `1 + (serial div 10) × 10`, so it always ends in 1. | `Main.SetMyExch2` | `OwnStartingSerialTests` |
| I4 | A LID's corrected serial (`…EEEEE 12`) was repeated at its natural width. MRCE repeats it in at least three digits (`EEEEE 012`). | `Station.NrAsText` | `OwnExchangeTextTests` |
| J1 | A message could lose the start of its first dit or dah. A program is scheduled against the render clock and then handed to the audio thread; if a render cycle ran in between (about 20 ms on a phone), playback began that far into the message. Lead-in silence is still skipped, but playback now never starts past the first keyed element, so a late hand-off delays the message by that amount instead. | — | `AudioProgramStartTests` |
| K1 | A contact whose TU was still being sent when the session clock ran out was scored NIL. MRCE gives it up to 15 s to complete. The app applied that only on the save-without-TU path, not on the normal Enter path. The fifth audit listed this as consistent; it was not. Found by the scripted sessions. | `Contest.ShouldDrainEndSessionQso` | `WholeSessionTests` |

I1 and I2 shortened every transmission, so one timing test (`testTUJustBeforeCallerRepeatIsNotScoredNIL`) was re-timed by 1.78 s, and tests that expected `5NN 001` on the air now expect the keyed form. The compiled-Pascal conversation fixture was generated with the exchange supplied as a literal, so that test decodes the keyed text before comparing.

## Whole sessions

`WholeSessionTests` plays ten simulated minutes in every contest in pile-up and single-call mode, plus WPX and HST competition, with five seeds each (150 sessions). The operator copies perfectly and works stations with Enter: CQ, call plus exchange, TU. The test requires that the session ends on time, that no row is left pending, that every contact is credited (a station worked twice is a dupe), that no caller stops answering, and that there is never a minute without a contact. All 150 pass after K1.

This is a consistency check of the app against itself, not a comparison with MRCE. A session-level comparison with compiled Pascal was not built: the units that run a session (`Contest`, `DxStn`, `Station`, `MyStn`, `Log`) depend on the VCL form, on `PerlRegEx` and on Delphi syntax FPC 3.2.2 does not accept, so they need a stubbed host and source patches rather than the direct extraction used for the keyer, receiver, prefix and parser oracles. MRCE's random stream is also different, so such a comparison would be statistical (contact rate, callers per CQ, repeats per contact), not trace for trace.

## Checked and found consistent

- Operator message assembly: queued messages are joined, his-call is taken when the piece is keyed, the faster report always applies to the operator when the option is on and uses the same `R1` rule.
- Sent-exchange validation for each contest, and the Sweepstakes forms (`#A`, `123 A`, `A`).
- From the first audit's smaller differences, now fixed: commands tick the simulator first, so they are no longer stamped up to 80 ms early; a caller that was sending when the operator started hears garbage unless the message has CQ, TU or NIL.
- Audio path: one render clock for receive and transmit, queued transmit pieces placed end to end, pause and resume keep playheads, route and configuration changes restart the engine, cancelling a caller removes only that caller.

## Noted, not changed

- **A caller's audio starts when its event is delivered**, up to one 80 ms timer tick after the simulator's time for it. MRCE's own granularity is 46 ms.
- **Changing RIT, pitch or bandwidth rebuilds the receiver filter on the audio thread.** A brief glitch is possible at that moment.
- **Unmuting mid-message** does not bring that message back; messages that start while muted are not scheduled.
- **The recording** is taken after the mute switch, so it is silent while muted.
- **Fallback Japanese calls** (no call list installed) come from a small space, so a dupe turns up in roughly one ALL JA or ACAG session in five.

# Eleventh audit: the open list, and the rest of the review (2026-11-15)

This pass closed the items earlier audits had noted without changing, then covered what had not been read: station information (`SbarUpdateStationInfo` and each contest's `GetStationInfo`), the score pop-ups and `UpdateStatsHst`, `Ini.pas` defaults and ranges, and the POTA extension. `swift test` passes (372 tests, 7 skipped) and the iOS SDK build succeeds. Nothing was run on a device; L1, L2, L9 and L10 change what is heard or how keys behave.

## Found and fixed

| # | Difference | MRCE source | Test |
|---|---|---|---|
| L1 | Fading restarted with every transmission. A station's fade now carries over between its transmissions and only advances while it sends. The warm-up count is also MRCE's (`3 × points + 1`). | `Qsb.pas`, `DxStn.pas` | — |
| L2 | The output pitch was exact. MRCE keeps a whole number of samples per cycle, so 600 Hz is heard as 612.5 Hz and 450 Hz as 459.4 Hz. | `TModulator.CalcSinCos` | `SmallMRCEDifferenceTests` |
| L3 | A RIT or pitch change restarted the receiver filter. Only a bandwidth change does now. (The tenth audit said the filter was rebuilt on the audio thread; it is reset in place with no allocation.) | `Contest.GetAudio` | — |
| L4 | Below 15 WPM, callers could be more than 4 WPM slower than the operator. | `UpdCWMinRxSpeed` | `CallerSpeedBoundaryTests` |
| L5 | In a custom WPX serial range, leading zeros had their own draw. They follow `R1 < 0.5`. | `Station.NrAsText` | existing width tests |
| L6 | The Sweepstakes history hint drew from the caller's behaviour stream, so the aid's rate changed that caller's replies for a given seed. It has its own stream. | — | existing hint tests |
| L7 | Continuous pile-up (Ctrl-U) and custom F8 text were missing. Both are settings under the caller options. | `Contest.OnMeFinishedSending`, `Contest.SendMsg` | `SmallMRCEDifferenceTests` |
| L8 | A key typed into a full box pushed the last character out. It is refused. | `MaxLength` | `EntryFieldLimitTests` |
| L9 | Keyboard shortcuts `;` (his call and exchange), `.` `+` `[` `,` (TU and log), up and down arrows (RIT) and Page Up / Page Down (speed, two WPM, or the next multiple of five in HST) were not mapped. | `FormKeyPress`, `FormKeyDown`, `IncSpeed` | `EntryFieldLimitTests` |
| L10 | The session timer ran every 80 ms. It runs at MRCE's block length (46 ms), so a caller's audio and reply timing are no coarser than MRCE's. | `Ini.BufSize` | — |
| L11 | A message that started while muted was never scheduled, so unmuting part-way through gave silence. It is scheduled and silenced. | — | — |
| L12 | Invented calls (no call list installed) could repeat within a session. | — | `WholeSessionTests` |
| L13 | Call-history user text (club, operator note) was shown only for Field Day and Sweepstakes. MRCE shows it in every contest. | `GetStationInfo` overrides | — |
| L14 | Practice duration stopped at 120 minutes; MRCE allows 240. | `Main.dfm` | — |

## Checked and found consistent

- Setting defaults: call, speed, activity, duration, pitch, bandwidth, station-ID rate, faster-5NN rate, Farnsworth rate, single-call delay, hint rate, competition duration, all band conditions off.
- HST score (sum of `CallToScore` over error-free rows) and the raw and verified totals behind the score pop-ups.
- POTA, for internal consistency: exchange, entry fields, caller mix, scoring and CQ text agree with one another, and the whole-session test plays it.
- `Station.pas` and `MyStn.pas` are now covered end to end except for `UpdateCallInMessage` (below).

## Left as they are, and why

- **Callsign information shows more than MRCE's.** With the aid switched on, the app shows a Field Day station's class and section, a Sweepstakes station's check and section, and CQ and ITU zones. MRCE shows only the continent, the entity and the history file's user text, and its source says not to give a hint that affects the exchange. `AGENTS.md` says configured learning aids are preserved, and the aid is off by default (on in MRCE), so this is left for the owner to decide.
- **Re-keying an edited call mid-transmission** and the cursor timing that goes with it were left here, then ported on 2026-11-15 (see below).
- **The recording is silent while muted.** Unclear that anything else is wanted.
- **The log's error column wording**, the unused `AGN?`/`CALL?` commands and the dropped Sweepstakes history rows with an obsolete section are unchanged; none affects play.
- **The speed stepper** still goes below MRCE's 10 WPM floor, for learners.
- **Insert** (his call and exchange) has no key on an iPad keyboard; `;` does the same.

### Follow-up, 2026-11-15

- **Callsign information trimmed to MRCE's content** at the owner's request. It now follows each contest's `GetStationInfo`: history user text, plus continent/entity where MRCE gives it (always in WPX, CQ WW, IARU, ARRL 10m and HST; DX stations only in Field Day; stations without a state in NAQP; from a W/VE home call in ARRL DX; in place of empty user text in CWT and SST; never in Sweepstakes, ALLJA or ACAG). Class, section, check and CQ/ITU zones are no longer shown. In CWT a US or Canadian non-member's user text is replaced by the entity, as in MRCE, because it would give away the state. The entity is the app's prefix code (`NA/K`), not MRCE's entity name. POTA follows the base rule. `CallsignInformationTests`.
- **Unused DSP code removed:** `CWReceiverDSP` (the Butterworth filter used before the MRCE filter port) and `ContinuousRFNoise` (a looped noise bed from before the MRCE noise port), with the four tests that exercised only them. The app's audio path never called either.
- **Correction to "moving the cursor only when the transmission ends"** (tenth and eleventh audits). `MyStn.GetBlock` calls `MainForm.Advance` when each *piece* of the message finishes, and the caller's call is a piece of its own. So after Enter MRCE moves the cursor when his call has been keyed, before the exchange is sent, not at the end of the whole transmission. The app still moves it at once.

### Call re-keying and cursor timing, 2026-11-15

Ported at the owner's request, reversing the 2026-11-13 decision.

- **His call and the exchange are separate keyer pieces** (`MyStn.AddToPieces`), each padded to a 512-sample block, instead of one message with a word space between them. The gap between them is four units plus the padding, as in MRCE, in place of five units.
- **Editing the call box while his call is being keyed** (`Edit1Change`, `UpdateCallInMessage`). If everything keyed so far is keyed the same in the edited call, the rest is sent from the edited call, callers hear the edited call, and it still counts as sent. Otherwise the transmission finishes as it was and the call is owed again; a call queued behind other text is replaced outright. Any edit that is not worked into a transmission clears `CallSent`, including one typed and then undone. Clearing the box also clears `NrSent`. `ContestSimulator.callEdited`, `.rekey` events, `FieldAudio.rekeyTransmit`.
- **The cursor moves when the piece being sent ends** (`MyStn.GetBlock` → `MainForm.Advance`), not at the Enter key: after his call when the call is sent, after the exchange when only that is sent. The empty report is filled with `599` at that moment. The destination is decided then, so a call edited to contain `?` keeps the cursor in the call box. Space cancels the pending move; Esc leaves it pending until the next piece ends, as in MRCE. `.advanceEntry` events.
- **What counts as sent** is MRCE's `SendPos`: the part of the piece already rendered into the output buffer. The audio host reports it per piece (`FieldAudio.transmitSecondsBuffered`), counting one further render callback because the replacement is published from another thread and picked up at the start of a callback. Without an audio host the simulator clock is used, in whole 512-sample blocks. (A fixed 0.1 s allowance was used for a few hours on 2026-11-15 and removed.)
- **Removed:** the unused `AGN?` and `CALL?` commands.

`CallRekeyTests`. The audio hand-over (the new program takes over the old one's slot, playhead and envelope on the render thread) and the cursor move are UIKit and AVAudioEngine behaviour and have not been run on a device.


### Documents, 2026-11-15

Differences found and not addressed are now kept in `docs/KNOWN_DIFFERENCES.md`, and deliberate ones in the README. The "noted, not changed" lists in the audits above are the record of when each was found; the two lists are the current state. The dated reports and audits from October and early November were deleted as stale.

### Settings screen and playback level, 2026-11-15 to 16

- **Settings screen audited control by control** and rearranged with the owner over four rounds of written feedback. Mechanical faults fixed: speed locked in HST, activity locked in WPX competition, the caller range ignoring the low-speed cap, controls live in modes where they do nothing. The 5 Hz RIT step, the seed controls, the "Serial digits" control and the custom sent exchange (replaced by a First serial field) were removed. Settings MRCE keeps in its ini file are on an Advanced page.
- **US prefixes.** `AH6/7`, `NH6/7`, `WH6/7` (Hawaii), `AL`, `NL`, `WL` (Alaska) and `NP2/4`, `WP2/4` (US Caribbean) were read as mainland US, so such a callsign sent a state in ARRL DX and counted as a W/VE station. `CallsignInformationTests`.
- **3 dB lost in the audio engine.** The source node had one channel. `AVAudioEngine`'s main mixer spreads a one-channel source across its stereo output at 0.707 per channel (measured with an offline render: 0.95 in, 0.672 out). The node now has two identical channels and the full 0.95 reaches each output channel. Measured on macOS with the same graph; not yet heard on a device.
- **`FieldAudio.swift` tidied** with no intended change in behaviour: named constants in place of literals, one builder for own-transmission programs, the render callback split into named steps, the unused receive branch of `play` removed (`playTransmit` now), and diagnostics that logged placeholder values removed. Built for iOS and the two app-level scripts pass; not run on a device.
- **Loudness, measured** (`PlaybackLevelTests`). At 500 Hz bandwidth the sidetone at 0 dB monitor peaks at 0.95 of full scale, the strongest caller at 0.845 (1.0 dB under it) and the weakest at 0.41. The AGC's knee follows the noise passing the filter, so at 100 Hz the strongest caller reaches 0.94. A monitor level of about -19 dB makes the sidetone equal the strongest caller. The owner asked for the strongest caller to equal the sidetone; it already does to within a decibel, so the output scaling was left alone. On a phone speaker at 450 Hz the remaining shortfall against music is the speaker's low-frequency roll-off, which the owner confirmed by ear (800 Hz is clearly louder).
- **Session clock reworked** (`SessionDriver`). Simulator time was `now - startTime - suspendedSeconds`, with `startTime` reset when audio finished starting. A pause that began and ended before audio had started was still added to `suspendedSeconds`, so the simulator then stood still for the length of that pause while audio ran. The clock is now a stopwatch (`accumulatedSeconds`, `runningSince`) that runs only while audio is started and nothing has paused the session. `SessionDriverContractTests` (7 cases; the new one fails on the old code).
- **Pause and resume, audited.** Sounds are placed relative to the render clock at the moment they are published, never from an absolute simulator time, so a difference between the two clocks cannot build up over a session. Each pause leaves at most a few milliseconds between the simulator and a sound that was in flight across it (the engine stops and restarts a queue hop away from the simulator); that ends with the sound.
- **Receive volume no longer scales the sidetone.** It was applied to the final mix. It is now cross-faded out by the operator's own keying, delayed to match the filter and AGC (`MRCEAudioRenderer.playbackGain`). At full volume the output is unchanged. `PlaybackLevelTests`.
- **Pitch quantisation removed** at the owner's request; it had been added on 2026-11-15 for fidelity. Now an intentional difference in the README.
- **Audio session** is plain playback (it no longer mixes with other apps' audio). **One audio queue** in place of two. The clean-up timer is gone (finished programs are released at the next publish), buffer sizes are derived from named counts, and per-session audio maps are cleared at shutdown.

