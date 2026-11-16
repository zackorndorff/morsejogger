# Intentional differences from MRCE

Morse Jogger follows Morse Runner Community Edition closely, and `tools/mrce-oracle` checks parts of it against the compiled Pascal source. The differences below are deliberate. Differences that were found and not yet dealt with are listed in [`KNOWN_DIFFERENCES.md`](KNOWN_DIFFERENCES.md).

- **QSK always mutes the receiver at key-down.** In MRCE the receiver gain while keying is `1 - monitor gain x key envelope`, so with the monitor turned down the band stays audible through your own keying. Here the receiver is fully muted while the key is down, whatever the monitor level, and recovers between elements.
- **A call that still contains `?` cannot be logged.** MRCE strips the `?` on save and logs what is left (`WG2M?` is logged as `WG2M`). Here Enter re-sends the partial call and waits for you to complete it.
- **Raw score excludes dupes.** MRCE adds every saved QSO, dupes included, to raw points and raw multipliers. Here a dupe adds nothing to the raw score. The verified score excludes dupes in both.
- **The HST contest never uses cut numbers.** MRCE suppresses cut numbers and `ENN` only in HST competition mode, so the HST contest run in pile-up or single-call mode gets them. Here callers in the HST contest send `5NN` and always spell the serial in digits.
- **Playback level.** MRCE writes its AGC output straight to 16-bit samples, so its loudest sound peaks 4.3 dB below full scale. Morse Jogger scales the same output so that ceiling sits at 95% of full scale, in both output channels. Everything is 3.8 dB louder; no signal changes level relative to another, and nothing can clip.
- **Pitch is exact.** MRCE's tone generator keeps a whole number of samples per cycle, so its 600 Hz setting sounds at 612.5 Hz and 450 Hz at 459.4 Hz. Here the tone is at the pitch you set.
- **Speed can go below 10 WPM.** MRCE's floor is 10 WPM. Here the speed control goes down to 5 WPM, for learners.
- **POTA.** Parks on the Air is an added, experimental contest with no MRCE counterpart.
- **Call lists are not bundled.** MRCE ships a call-history file for each contest. Here callers come from a Super Check Partial list downloaded with your consent, or from files you import. See [`CALLSIGN_DATA.md`](CALLSIGN_DATA.md).
