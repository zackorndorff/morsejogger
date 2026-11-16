# Where callers come from, and what that does to realism

Written 2026-11-13 as part of the MRCE review (`FABLE_REVIEW.md`). The section "Decisions waiting for the owner" lists what has not been decided.

## What MRCE does

MRCE ships a call-history file for each contest, built from real logs: who takes part, and what each of them sends (name, state, section, class, check, zone, power, member number). A caller is drawn uniformly from that file and sends its real exchange. WPX and HST use `MASTER.DTA`, a plain list of calls. Zones and countries come from `DXCC.LIST`, which covers every entity.

Two things follow. The mix of callers matches the contest (Sweepstakes is all US and Canada, CQ WW is worldwide). And what you copy is what that station really sends, so practice builds the same call-to-exchange familiarity the contest rewards.

## What Morse Jogger has

None of MRCE's data files are bundled. There are three sources, tried in this order for each caller:

| Source | What it is | What it knows |
|---|---|---|
| Imported contest history | A file the user imports for one contest: an MRCE or N1MM `!!Order!!` call-history file, or the ARRL 10m TSV | Calls and their real exchange fields |
| General call list | `MASTER.SCP`, downloaded from supercheckpartial.com with the user's consent, or a `MASTER.DTA`, `MASTER.SCP` or plain list the user imports | Calls only |
| Generator | `CallsignGenerator` | Invented calls from about 60 prefixes |

A fresh install that accepts the download has only the general list. Everything below is about that state, since an imported contest history behaves as in MRCE.

## Effect by contest, with only the general list

| Contest | Who calls | What they send |
|---|---|---|
| WPX, HST | Real calls, worldwide. Same kind of data MRCE uses. | Serial numbers, as in MRCE. Faithful. |
| Sweepstakes | Real US and Canadian calls | Serial and precedence as in MRCE. Check and section are invented; the section follows the call area. |
| Field Day | Real calls, 98% US and Canada | Class and section invented. Class follows the mix in MRCE's file (mostly 1D, 1E, 1B). |
| NAQP | Real calls, 98% US and Canada | Name invented. State follows the call area. |
| SST | Real calls, 94% US and Canada | Name invented. State follows the call area; others send `DX`. |
| CWT | Real calls, 68% US and Canada | Name and member number invented. Every caller sends a number; real non-members send a state or country. |
| ARRL DX | Real calls from the right side (DX if you are W/VE) | Power invented from a weighted list; states follow the call area. |
| CQ WW | Real calls, 54% US and Canada, **from about 30 entities only** | Zone from the built-in table; US and Canadian zones follow the call area. |
| IARU | Real calls, 32% US and Canada, same 30 entities | ITU zone from the table. No headquarters stations. |
| ARRL 10m | Real calls, 45% US and Canada, same 30 entities | State by call area, or a serial. |
| All JA, ACAG | Real Japanese calls only | Prefecture follows the call area. City codes are a prefecture plus an invented number, so they are the right shape but not real codes. Power letter invented. |
| POTA | Real calls, 90% US and Canada (estimate) | State by call area. |

The US and Canada shares are the shares in MRCE's own file for each contest at the pinned commit. WPX, HST and the contests restricted by rule keep the list's natural mix.

## What is lost compared with MRCE

- **Nothing you copy except the call is true.** K1ABC's name, state, check or member number here is not K1ABC's. Operators who use practice to learn real pairings (CWT and NAQP regulars especially) get no benefit, and anyone who knows the real pairing hears a wrong one.
- **Each call is at least self-consistent.** The invented details are derived from the call, so a station sends the same thing every time, in every session. Names are the exception: they are consistent within a session only.
- **Geography is thin.** The built-in country table knows about 30 entities (`ContestRules.countries`). Calls outside it are dropped from CQ WW, IARU, ARRL DX, ARRL 10m and NAQP, so those contests never produce, for example, a Ukrainian, Greek, Chinese or South African caller, and CQ WW offers few zones and countries to work. Russia is matched only by `UA`, and all of it is treated as European. A user can import a prefix CSV to extend the table; nothing ships with one.
- **Call areas are a guess.** US states, Canadian provinces and Japanese prefectures follow the call area, which is right for most stations and wrong for anyone who moved or holds a vanity call.
- **Sampling is uniform over the list.** Active and rare stations are equally likely, as in MRCE.

## Fixed in this pass ("Make callers without call history vary, stay consistent and fit the contest", 2026-11-13)

Before it, with only the general list: every caller sent the same CWT number, Field Day class, Sweepstakes check, ARRL DX power and Japanese prefecture; states ignored the call area; a returning call sent a different name; All JA drew non-Japanese calls; every US station was CQ zone 5; and no contest adjusted the worldwide mix. `CallerDataRealismTests` covers each of these.

## Decisions waiting for the owner

1. **Bundle or fetch MRCE's contest files?** They would close most of the gap above. Their licence is unclear: the MRCE repository is MPL-2.0, but the files carry no licence of their own and their headers credit outside sources (N1MM call-history maintainers, the CWops list, K1USN, ARRL results pages, public logs). Several pair calls with operator names. Options: ask the MRCE maintainers; download them on demand from the MRCE repository, as the SCP list is; or leave import manual.
2. **A full entity table.** MRCE's `DXCC.LIST` (14 KB) or a CTY-derived table would fix the 30-entity limit. Same licence question for `DXCC.LIST`; `CTY.DAT` has its own terms.
3. **CWT non-members.** Should some callers send a state or country instead of a number, as in the real contest and in MRCE's file (about half its rows)?
4. **POTA share.** The 90% US and Canada figure is a guess.
5. **Names across sessions.** Derive the name from the call too, at the cost of occasional repeats among callers heard together?
