//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

/// Plays complete sessions with a scripted operator that copies perfectly and
/// works callers the way a person does with Enter: CQ, call plus exchange,
/// then TU. It exercises every layer together (arrivals, caller timing, the
/// keyer horizon, Enter logic, logging and adjudication).
final class WholeSessionTests: XCTestCase {
    struct Outcome {
        var contacts = 0, correct = 0, pending = 0, wipes = 0, cqs = 0, repeats = 0
        var notes: [String: Int] = [:]
        var longestIdle = 0.0, endedAt = 0.0, finished = false
    }

    static func play(_ settings: ContestSettings, minutes: Int = 10) -> Outcome {
        var s = settings; s.duration = minutes; s.competitionDuration = minutes
        let game = ContestSimulator(settings: s)
        game.start()
        var out = Outcome()
        var now = 0.0, txEnd = 0.0, rxEnd = 0.0, lastAction = -10.0, lastContact = 0.0
        var target: String?, targetReplies: [String] = [], tries = 0
        var heard: [String] = []
        var rxEndByCall: [String: Double] = [:]
        let limit = Double(minutes) * 60 + 40
        while game.running && now < limit {
            now += 0.08
            game.tick(now)
            for event in game.drainEvents() {
                switch event.kind {
                case .transmit:
                    txEnd = max(txEnd, now) + MorseTimeline.duration(event.text, wpm: game.settings.wpm)
                case .receive:
                    for voice in event.voices {
                        let length = MorseTimeline.duration(voice.message, wpm: voice.wpm, characterWpm: max(voice.wpm, voice.characterWpm),
                                                            farnsworthKeyer: voice.farnsworthKeyer)
                        rxEnd = max(rxEnd, event.at + length)
                        rxEndByCall[voice.call] = event.at + length
                        if voice.call == target { targetReplies.append(voice.message) }
                        else if !heard.contains(voice.call) { heard.append(voice.call) }
                    }
                default: break
                }
            }
            // A busy pile never falls quiet, so the operator answers as soon
            // as the station it is working (or about to work) has finished.
            let waitFor = (target ?? heard.first(where: { c in game.pileup.contains { $0.call == c } })).flatMap { rxEndByCall[$0] } ?? rxEnd
            guard now >= txEnd + 0.25, now >= waitFor + 0.25 else { continue }
            if let call = target {
                guard let station = game.pileup.first(where: { $0.call == call }) else {
                    game.command(.wipe); out.wipes += 1; target = nil; lastAction = now; continue
                }
                if let reply = targetReplies.last {
                    targetReplies = []
                    if reply.contains("?") || reply.contains("AGN") {
                        game.command(.exchange, call: call); out.repeats += 1; lastAction = now
                    } else if reply.split(separator: " ").allSatisfy({ $0 == Substring(call) || $0 == "DE" }) {
                        game.command(.call, call: call); out.repeats += 1; lastAction = now
                    } else {
                        let fields = ContestRules.deriveReceivedExchangeFields(station.exchange, contest: game.settings.contest)
                        let before = game.log.count
                        game.command(.esm, call: call, exchange: station.exchange,
                                     exchangeFirst: fields.first, exchangeSecond: fields.second)
                        if game.log.count > before {
                            out.longestIdle = max(out.longestIdle, now - lastContact); lastContact = now
                            target = nil; tries = 0
                        } else { out.repeats += 1 }
                        lastAction = now
                    }
                } else if now - max(txEnd, waitFor) > 6 {
                    tries += 1
                    if tries > 3 { game.command(.wipe); out.wipes += 1; target = nil; tries = 0 }
                    else { game.command(.call, call: call); out.repeats += 1 }
                    lastAction = now
                }
            } else if let call = heard.first(where: { c in game.pileup.contains { $0.call == c } }) {
                heard.removeAll { $0 == call }
                target = call; targetReplies = []; tries = 0
                game.command(.esm, call: call); lastAction = now
            } else if now - max(txEnd, rxEnd, lastAction) > 2 {
                heard = []
                game.command(.esm); out.cqs += 1; lastAction = now
            }
        }
        out.finished = !game.running
        out.endedAt = now
        out.contacts = game.log.count
        for row in game.log {
            if row.correct { out.correct += 1 }
            if row.status != .completed { out.pending += 1 }
            if !row.correct { out.notes[row.note, default: 0] += 1 }
        }
        return out
    }

    /// Every contest and mode, five seeds each, ten simulated minutes. A
    /// perfect operator must be able to keep working stations to the end, and
    /// every contact it logs must be credited (a station worked twice is a
    /// dupe, which the script does not avoid).
    func testAPerfectOperatorIsCreditedForEveryContactInEveryContest() {
        var cases: [(ContestID, SessionMode)] = []
        for contest in ContestID.allCases { cases.append((contest, .pileup)); cases.append((contest, .single)) }
        cases.append((.wpx, .wpxCompetition)); cases.append((.hst, .hstCompetition))
        for (contest, mode) in cases {
            for seed in [4242, 7, 99, 31337, 2026] as [UInt32] {
                var s = ContestSettings(); s.contest = contest; s.mode = mode; s.seed = seed; s.activity = 3
                let o = Self.play(s)
                let label = "\(contest.rawValue) \(mode.rawValue) seed \(seed)"
                XCTAssertTrue(o.finished, "\(label): session did not end")
                XCTAssertLessThanOrEqual(o.endedAt, 616, "\(label): ended late")
                XCTAssertEqual(o.pending, 0, "\(label): rows left pending")
                let dupes = o.notes["DUP — already worked", default: 0]
                XCTAssertEqual(o.contacts - o.correct, dupes, "\(label): uncredited contacts \(o.notes)")
                XCTAssertLessThanOrEqual(dupes, 2, label)
                XCTAssertGreaterThanOrEqual(o.contacts, 15, "\(label): too few contacts")
                XCTAssertLessThanOrEqual(o.longestIdle, 60, "\(label): a minute without a contact")
                XCTAssertEqual(o.wipes, 0, "\(label): a caller stopped answering")
            }
        }
    }

    /// MRCE `ShouldDrainEndSessionQso`: a contact whose TU is on the air when
    /// time runs out is completed, not scored NIL.
    func testAContactInProgressAtTheEndIsCompleted() throws {
        // Find a start time for which the caller has just finished its
        // exchange when the operator presses Enter 0.4 s before the end.
        var exercised = false
        for start in stride(from: 44.0, through: 52.0, by: 0.5) where !exercised {
            var s = ContestSettings(); s.contest = .wpx; s.mode = .single; s.seed = 4242; s.duration = 1
            let game = ContestSimulator(settings: s)
            game.start()
            var now = 0.0, rxEnd = 0.0
            func run(to time: Double) {
                while now < time - 1e-9 {
                    now = min(time, now + 0.08); game.tick(now)
                    for event in game.drainEvents() where event.kind == .receive {
                        for voice in event.voices { rxEnd = max(rxEnd, event.at + MorseTimeline.duration(voice.message, wpm: voice.wpm)) }
                    }
                }
            }
            run(to: start)
            guard let caller = game.pileup.first(where: { $0.opState == .needQso }), rxEnd < start else { continue }
            game.command(.esm, call: caller.call)
            run(to: 59.6)
            guard game.pileup.first(where: { $0.call == caller.call })?.opState == .needEnd, rxEnd < 59.5 else { continue }
            exercised = true
            let fields = ContestRules.deriveReceivedExchangeFields(caller.exchange, contest: .wpx)
            game.command(.esm, call: caller.call, exchange: caller.exchange, exchangeFirst: fields.first, exchangeSecond: fields.second)
            XCTAssertEqual(game.log.first?.status, .pendingTUConfirmation)
            run(to: 60.08)
            XCTAssertTrue(game.running, "the TU is still being sent")
            run(to: 63)
            XCTAssertFalse(game.running)
            XCTAssertEqual(game.log.first?.status, .completed)
            XCTAssertTrue(game.log.first?.correct ?? false, game.log.first?.note ?? "")
        }
        XCTAssertTrue(exercised, "no start time put a finished exchange just before the end")
    }
}
