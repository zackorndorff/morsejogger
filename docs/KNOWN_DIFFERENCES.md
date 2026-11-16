# Known differences from MRCE that have not been addressed

This is the list to read before starting another comparison with Morse Runner Community Edition (MRCE, pinned at `304e51aece5a17f4cba548527816a385a8f6f814`, see `tools/mrce-oracle/README.md`). Everything here was found and deliberately left, or has not been compared yet.

- Differences that are **deliberate** are in `docs/INTENTIONAL_DIFFERENCES.md`.
- Differences that were **found and fixed** are in `FABLE_REVIEW.md`, audit by audit.
- Differences in **where callers and their exchanges come from** are in `docs/CALLSIGN_DATA.md`, with the decisions still open.

When one of these is fixed or made deliberate, remove it from this file. When a new difference is found and not fixed, add it here.

Last updated 2026-11-15.

## Found, not addressed

### Timing and audio

| Difference | MRCE | Morse Jogger | Effect |
|---|---|---|---|
| End of a caller's transmission | Padded to the next 512-sample block (46 ms at 11,025 Hz); the reply timer starts there | Exact length, not padded. The operator's own transmissions are padded | A caller's timer can start up to 46 ms early. Not perceptible |
| Start of a caller's audio | On the audio block it was created in | When the simulator event is delivered, up to one 46 ms timer tick later | Not perceptible |
| Re-keying an edited call: what counts as sent | Samples already written to the sound buffer (`SendPos`) | Samples rendered, plus one further render callback (the replacement is handed over between callbacks) | An edit can be refused a few milliseconds earlier than in MRCE |
| Caller duration reported to the simulator | Not applicable (one thread) | The audio layer reports each caller's keyed length plus 0.33 s (`receiveTailSeconds` 0.15 and `receiveAcknowledgementMarginSeconds` 0.18 in `FieldAudio.swift`), and the simulator adds 0.05 s, before a caller's reply timer may expire. The figures are inherited, not derived from MRCE | A caller that would repeat immediately after its own transmission waits about a third of a second longer |
| Recording while muted | Not applicable | The recording is taken after the mute switch, so it is silent while muted | Only if recording with the sound off |

### Entry and display

| Difference | MRCE | Morse Jogger | Effect |
|---|---|---|---|
| Sweepstakes check/section hint | Put into the box when the cursor advances (after his call is keyed) | Put in when the callers have heard the whole transmission | The hint appears a moment later |
| Log error column | The correct values of what was miscopied, or `DUP`/`NIL`; a short code when corrections are off | A diagnosis and the expected exchange | Same information, different words |
| Callsign information: entity | Entity name (`NA/United States of America`) | Prefix code (`NA/K`). There is no entity-name table; see `docs/CALLSIGN_DATA.md` decision 2 | Cosmetic |
| Callsign information without a history record | Nothing shown | The entity line is still shown where the contest shows one | Only without an imported history |
| Insert key | His call and exchange | No such key on an iPad keyboard; `;` does the same | None |
| Keying his call by hand (`CallsFromKeyer`) | Optional: the `<his>` piece is left silent for the operator's own key | Not ported | Only for operators who key with a paddle |

### Settings

| Difference | MRCE | Morse Jogger | Effect |
|---|---|---|---|
| Caller speed range | Menu choices of 0, 1, 2, 4, 6, 8 or 10 WPM slower and faster | Any value from 0 to 80 | Wider choice |
| Receive volume | No such control (MRCE's volume slider is the monitor level) | Extra control. It turns down what the receiver hears and leaves the sidetone alone | Extension |
| Show correct answers | No such option | Extra learning aid | Extension |
| First serial | Typed into the Exchange box in place of `#` | A "First serial" field for WPX, Sweepstakes and ARRL 10m (DX call) | Same result. A report other than 5NN can no longer be set, by the owner's choice. The core still parses a custom sent exchange (`parseStructuredSentExchange`), but nothing in the app sets one and a saved one is dropped on load |
| Competition length | Ini file only (`CompetitionDuration`) | Stepper under Advanced settings | Easier to change |
| Fixed random seed | None; every run is random | None in the app. The core takes a seed, used by tests | Same |

### Scoring and data

| Difference | MRCE | Morse Jogger | Effect |
|---|---|---|---|
| Points and multipliers | Computed from what the operator logged | Computed from the true station | The two agree for every verified contact, which is all that counts toward the verified score |
| CQ WW caller with no resolvable entity | One point and a zone multiplier | Nothing | Cannot occur: such callers are not generated |
| Sweepstakes history rows with an obsolete section | Kept on load | Dropped on import | None: MRCE's parser could never accept that section either |
| Country table | `DXCC.LIST` | About 30 entities built in | Most DX calls are unusable in CQ WW, IARU, ARRL DX, ARRL 10m and NAQP. See `docs/CALLSIGN_DATA.md` |

## Not compared yet

- **Whole sessions against compiled Pascal.** `WholeSessionTests` checks the app against itself. MRCE's session units (`Contest`, `DxStn`, `Station`, `MyStn`, `Log`) do not compile under FPC 3.2.2 without a stubbed host and source patches, and MRCE's random stream differs, so the comparison would be statistical (contact rate, callers per CQ, repeats per contact).
- **Results and score screens.** The totals match; the presentation was not compared.
- **The settings screen** was audited control by control on 2026-11-15 (ranges, defaults, what each control does, which modes lock it). Mechanical faults were fixed; label and explanatory-text suggestions are with the owner. The older setting audit of 2026-10-26 (35 gaps, 13 open questions) was not walked row by row; that plan predates the public history and is not included.
- **File imports.** The importer accepts MRCE `MASTER.DTA`, MRCE call-history text (`!!Order!!`), the ARRL 10m results TSV, a prefix CSV (`PREFIX,COUNTRY,CONTINENT,CQ_ZONE,ITU_ZONE`) and a plain call list, plus a `MASTER.SCP` list. None was tested against a real or malformed file in this review, and the app no longer lists the formats on screen. The owner asked on 2026-11-15 to come back to this.
- **POTA** is an extension with no MRCE counterpart; it was checked only for internal consistency.

## Changed but not yet run on a device

These are covered by tests in the core, but what is heard or how the keyboard behaves has not been confirmed on an iPhone or iPad:

- Re-keying an edited call (the audio hand-over) and the cursor moving when his call has been keyed.
- Fading carried over between a station's transmissions; RIT and pitch changes no longer restarting the receiver filter.
- Receive volume leaving the sidetone alone; the extra 3 dB from the two-channel source; the reorganised `FieldAudio.swift`.
- Pause and resume after the session clock rework.
- The 46 ms simulation timer; unmuting part-way through a message.
- Keyboard shortcuts `;`, `.` `+` `[` `,`, arrow keys for RIT, Page Up and Page Down for speed.
- Entry boxes: key filtering, refusal of a key in a full box, selection when a box takes the cursor.
