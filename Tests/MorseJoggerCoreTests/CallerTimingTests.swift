//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

/// MRCE gives every DX station its own state machine and timer, and delivers
/// one message set per keyer burst. These tests pin that per-station timing:
/// callers overlap and never wait for each other, one burst gets one reply,
/// and a caller that was on the air misses most of the operator's message.
final class CallerTimingTests: XCTestCase {
    private struct Heard {
        var call: String, start: Double, end: Double, text: String
    }

    /// Ticks in 80 ms steps (the app's timer) up to `time`. With `ack` each
    /// caller event is acknowledged the way `SessionDriver.apply` does.
    @discardableResult
    private func run(_ game: ContestSimulator, from start: Double, to time: Double,
                     ack: Bool = false) -> [RadioEvent] {
        var events: [RadioEvent] = []
        var now = start
        while now < time - 1e-9 {
            now = min(time, now + 0.08)
            game.tick(now)
            let drained = game.drainEvents()
            if ack {
                for event in drained where event.kind == .receive {
                    let seconds = event.voices.map { ContestRules.cwSeconds($0.message, wpm: $0.wpm) }.max() ?? 0
                    game.acknowledgeReceive(duration: seconds + 0.33, calls: event.stationCalls)
                }
            }
            events += drained
        }
        return events
    }

    private func heard(_ events: [RadioEvent]) -> [Heard] {
        events.filter { $0.kind == .receive }.flatMap { event in
            event.voices.map {
                Heard(call: $0.call, start: event.at,
                      end: event.at + ContestRules.cwSeconds($0.message, wpm: $0.wpm), text: $0.message)
            }
        }
    }

    private func pileupGame(seed: UInt32, activity: Int) -> ContestSimulator {
        var s = ContestSettings()
        s.contest = .wpx
        s.mode = .pileup
        s.seed = seed
        s.activity = activity
        let game = ContestSimulator(settings: s)
        game.start()
        return game
    }

    // MARK: (a) pileup callers overlap and nobody is starved

    private func assertPileupOverlapsWithoutStarvation(ack: Bool) throws {
        let game = pileupGame(seed: 4242, activity: 6)
        run(game, from: 0, to: 4.0)
        game.command(.cq)
        let events = run(game, from: 4.0, to: 44.0, ack: ack)
        let calls = heard(events).sorted { $0.start < $1.start }
        let first = try XCTUnwrap(calls.first)

        // The first burst: independent 0.1-0.6 s send delays, not one shared start.
        let burst = calls.filter { $0.start < first.start + 1.0 }
        XCTAssertGreaterThanOrEqual(burst.count, 3, "a pileup of several callers answers the CQ")
        XCTAssertEqual(Set(burst.map(\.start)).count, burst.count, "each caller starts on its own send delay")
        let spread = burst.map(\.start).max()! - burst.map(\.start).min()!
        XCTAssertGreaterThan(spread, 0)
        XCTAssertLessThanOrEqual(spread, 0.6 + 0.05, "MRCE send delays span 0.1-0.6 s")

        // After the first burst callers still land on top of each other.
        let later = calls.filter { $0.start > first.start + 1.0 }
        var overlapping = false
        for (index, a) in later.enumerated() {
            for b in later[(index + 1)...] where a.call != b.call && b.start < a.end && a.start < b.end {
                overlapping = true
            }
        }
        XCTAssertTrue(overlapping, "callers keep overlapping after the first burst")

        // Nobody waits for another caller, so every remaining caller keeps calling.
        let survivors = game.pileup.filter { $0.opState == .needQso && !$0.ghosting }
        XCTAssertFalse(survivors.isEmpty)
        for survivor in survivors {
            let count = calls.filter { $0.call == survivor.call }.count
            XCTAssertGreaterThanOrEqual(count, 3, "\(survivor.call) called only \(count) times in 40 s")
        }
    }

    func testPileupCallersOverlapAfterTheFirstBurstAndNoneIsStarved() throws {
        try assertPileupOverlapsWithoutStarvation(ack: false)
    }

    func testPileupTimingHoldsWhenPlaybackIsAcknowledgedPerStation() throws {
        try assertPileupOverlapsWithoutStarvation(ack: true)
    }

    func testAcknowledgedReceiveOnlyMovesTheTimersOfItsOwnStations() throws {
        let game = pileupGame(seed: 4242, activity: 6)
        run(game, from: 0, to: 4.0)
        game.command(.cq)
        run(game, from: 4.0, to: 14.0)
        let before = Dictionary(uniqueKeysWithValues: game.pileup.map { ($0.call, $0.nextAction) })
        let heardCaller = try XCTUnwrap(game.pileup.first { $0.nextAction > 0 }).call
        game.acknowledgeReceive(duration: 30, calls: [heardCaller])
        for station in game.pileup {
            if station.call == heardCaller {
                XCTAssertGreaterThanOrEqual(station.nextAction, game.fixtureClock + 30,
                                            "the acknowledged caller waits out its own audio")
            } else {
                XCTAssertEqual(station.nextAction, before[station.call],
                               "\(station.call) must not wait for another caller")
            }
        }
        // The old signature stays source compatible and leaves every timer alone.
        let timers = game.pileup.map(\.nextAction)
        game.acknowledgeReceive(duration: 30)
        XCTAssertEqual(game.pileup.map(\.nextAction), timers)
    }

    // MARK: (b) HST competition

    func testHSTCallersAllKeepCalling() throws {
        var s = ContestSettings()
        s.contest = .hst
        s.mode = .hstCompetition
        s.seed = 5
        s.wpm = 30
        let game = ContestSimulator(settings: s)
        game.start()
        let calls = heard(run(game, from: 0, to: 20))
        let callers = Set(calls.map(\.call))
        XCTAssertGreaterThanOrEqual(callers.count, 4)
        for caller in callers {
            XCTAssertGreaterThanOrEqual(calls.filter { $0.call == caller }.count, 3,
                                        "\(caller) should keep calling in HST")
        }
    }

    // MARK: (c) TU makes the waiting pile call at once

    func testLeftoverCallersCallWithinTheSendDelayAfterTU() throws {
        let game = pileupGame(seed: 99, activity: 4)
        run(game, from: 0, to: 4.0)
        game.command(.cq)
        run(game, from: 4.0, to: 16.0)
        let logged = try XCTUnwrap(game.pileup.first).call
        let leftover = Set(game.pileup.map(\.call)).subtracting([logged])
        XCTAssertFalse(leftover.isEmpty)
        game.command(.call, call: logged)
        run(game, from: 16.0, to: 40.0)
        _ = game.drainEvents()
        let row = game.logQSO(call: logged, exchange: "599 001")
        XCTAssertNotNil(row)
        let tx = try XCTUnwrap(game.drainEvents().first { $0.kind == .transmit })
        let tuEnd = tx.at + MorseTimeline.blockPadded(ContestRules.cwSeconds(tx.text, wpm: game.settings.wpm))
        let after = heard(run(game, from: 40.0, to: tuEnd + 3))
        let firstLeftover = try XCTUnwrap(after.filter { leftover.contains($0.call) }.map(\.start).min(),
                                          "a waiting caller must answer the TU")
        XCTAssertGreaterThanOrEqual(firstLeftover, tuEnd - 0.01)
        XCTAssertLessThanOrEqual(firstLeftover, tuEnd + 0.7, "MRCE send delay is 0.1-0.6 s")
    }

    // MARK: (d) one burst, one reply

    private func singleGame(seed: UInt32 = 1234) throws -> (ContestSimulator, Station, Double) {
        var s = ContestSettings()
        s.contest = .wpx
        s.mode = .single
        s.seed = seed
        let game = ContestSimulator(settings: s)
        game.start()
        let now = 6.0 * 512.0 / 11025.0
        game.tick(now)
        let station = try XCTUnwrap(game.pileup.first)
        _ = game.drainEvents()
        return (game, station, now)
    }

    func testHisCallFollowedByExchangeProducesOneReplyThatIsNotNumberQuestion() throws {
        let (game, station, start) = try singleGame()
        game.command(.hiscall, call: station.call)
        game.command(.exchange)
        let keyed = game.drainEvents().filter { $0.kind == .transmit }.map(\.text)
        XCTAssertEqual(keyed.count, 2, "F5 then F2 are two macros in one burst")
        let events = run(game, from: start, to: start + 25)
        let replies = heard(events).filter { $0.call == station.call && $0.start > start + 1 }
        let first = try XCTUnwrap(replies.first)
        XCTAssertFalse(first.text.contains("NR?"), "the caller heard its call and the number together")
        XCTAssertTrue(first.text.hasPrefix("R "), "got \(first.text)")
        XCTAssertEqual(game.pileup.first?.opState, .needEnd)
        // One reaction for the burst: the next sound is its timeout repeat, seconds later.
        if replies.count > 1 { XCTAssertGreaterThan(replies[1].start - first.end, 1.0) }
    }

    func testEnterWithCorrectedCallAndFilledExchangeAnswersTUWithoutASpuriousReply() throws {
        let (game, station, start) = try singleGame()
        var misspelled = station.call
        misspelled.removeLast()
        game.command(.esm, call: misspelled, exchange: "")
        var now = start
        now += 0.0
        let early = run(game, from: now, to: now + 30)
        now += 30
        XCTAssertEqual(game.pileup.first?.opState, .needCall,
                       "the caller took the exchange and wants its call corrected; heard \(heard(early).map(\.text))")
        // Wait for a gap in the caller's own transmission, then Enter with the fix.
        while game.fixtureCallerTransmitRanges(station.call).contains(where: { $0.start <= now && now < $0.end }) {
            now += 0.08
            game.tick(now)
        }
        _ = game.drainEvents()
        game.command(.esm, call: station.call, exchange: station.exchange)
        let keyed = game.drainEvents().filter { $0.kind == .transmit }.map(\.text)
        XCTAssertEqual(keyed, [station.call, "TU"], "corrected call plus TU in one burst")
        let after = heard(run(game, from: now, to: now + 20)).filter { $0.call == station.call }
        XCTAssertTrue(after.isEmpty, "no spurious reply to call + TU; heard \(after.map(\.text))")
        XCTAssertEqual(game.log.first?.correct, true)
    }

    // MARK: (e) doubling

    /// Runs until the single-mode caller is on the air, returning that moment.
    private func advanceUntilOnAir(_ game: ContestSimulator, call: String, from start: Double) throws -> Double {
        var now = start
        while now < start + 60 {
            now += 0.04
            game.tick(now)
            if game.fixtureCallerTransmitRanges(call).contains(where: { $0.start <= now && now < $0.end }) {return now}
        }
        XCTFail("caller never keyed up")
        return now
    }

    func testCallerThatWasSendingTreatsCallAndExchangeAsGarbage() throws {
        let (game, station, start) = try singleGame()
        let onAir = try advanceUntilOnAir(game, call: station.call, from: start)
        _ = game.drainEvents()
        game.command(.call, call: station.call)
        let window = try XCTUnwrap(game.fixtureCallerTransmitRanges(station.call).first { $0.start <= onAir && onAir < $0.end })
        let tx = try XCTUnwrap(game.drainEvents().first { $0.kind == .transmit })
        let burstEnd = onAir + MorseTimeline.blockPadded(ContestRules.cwSeconds(tx.text, wpm: game.settings.wpm))
        XCTAssertLessThan(window.end, burstEnd, "the caller finishes during the operator's message")
        run(game, from: onAir, to: burstEnd + 0.2)
        XCTAssertEqual(game.pileup.first?.opState, .needQso,
                       "a call and exchange heard only in part is garbage, not a QSO step")
    }

    func testCallerThatWasSendingStillActsOnTU() throws {
        let (game, station, start) = try singleGame()
        let onAir = try advanceUntilOnAir(game, call: station.call, from: start)
        _ = game.drainEvents()
        // Still sending when TU ends, so only a caller awaiting a call fix hears it.
        game.fixtureSetOperatorState(station.call, .needCall)
        game.command(.tu)
        let tx = try XCTUnwrap(game.drainEvents().first { $0.kind == .transmit })
        let burstEnd = onAir + MorseTimeline.blockPadded(ContestRules.cwSeconds(tx.text, wpm: game.settings.wpm))
        run(game, from: onAir, to: burstEnd + 0.2)
        XCTAssertEqual(game.pileup.first(where: { $0.call == station.call })?.opState ?? .done, .done,
                       "TU is always understood, even from a partial copy")
    }

    func testCallerThatWasSendingStillActsOnCQ() throws {
        var s = ContestSettings()
        s.contest = .wpx
        s.mode = .pileup
        s.seed = 4242
        s.activity = 6
        let game = ContestSimulator(settings: s)
        game.start()
        run(game, from: 0, to: 4.0)
        game.command(.cq)
        // Run into the first burst, then key CQ again while callers are on the air.
        var now = 4.0
        var onAir = false
        while now < 40 && !onAir {
            now += 0.04
            game.tick(now)
            onAir = game.pileup.contains { !game.fixtureCallerTransmitRanges($0.call).filter { $0.start <= now && now < $0.end }.isEmpty }
        }
        XCTAssertTrue(onAir)
        let live = game.pileup.filter { !game.fixtureCallerTransmitRanges($0.call).filter { $0.start <= now && now < $0.end }.isEmpty }
        let call = try XCTUnwrap(live.first).call
        game.fixtureSetOperatorState(call, .needNr)
        _ = game.drainEvents()
        game.command(.cq)
        run(game, from: now, to: now + 12)
        // CQ fails a caller waiting for the number: it was understood in full.
        XCTAssertNil(game.pileup.first { $0.call == call && $0.opState == .needNr })
    }

    // MARK: (f) a bare TU draws arrivals

    func testBareTUWithNonEmptyLogDrawsArrivalsButNotBeforeAnyQSO() throws {
        func newCallers(afterTU log: Bool, seed: UInt32) throws -> Int {
            var s = ContestSettings()
            s.contest = .wpx
            s.mode = .pileup
            s.seed = seed
            s.activity = 9
            let game = ContestSimulator(settings: s)
            game.start()
            var now = 0.0
            if log {
                // Seed the log through the normal path, then let its TU play out.
                game.command(.cq)
                run(game, from: now, to: 30)
                now = 30
                let target = try XCTUnwrap(game.pileup.first)
                game.fixtureSetOperatorState(target.call, .needEnd)
                _ = game.logQSO(call: target.call, exchange: target.exchange)
                run(game, from: now, to: now + 20)
                now += 20
            }
            _ = game.drainEvents()
            let before = game.pileup.count
            game.command(.tu)
            run(game, from: now, to: now + 6)
            return game.pileup.count - before
        }
        var grew = 0
        for seed in UInt32(1)...UInt32(12) {
            let withLog = try newCallers(afterTU: true, seed: seed)
            if withLog > 0 { grew += 1 }
            let noLog = try newCallers(afterTU: false, seed: seed)
            XCTAssertLessThanOrEqual(noLog, 0, "an empty log never draws arrivals on TU (seed \(seed))")
        }
        XCTAssertGreaterThanOrEqual(grew, 3, "a bare TU after a logged QSO adds callers")
    }
}

/// The operator's transmission ends on MRCE's 512-sample block boundary and
/// callers time their replies from there. Nothing else is added to it.
final class OwnTransmissionEndTests: XCTestCase {
    private func firstReply(acknowledge: Bool) throws -> (reply: Double, txEnd: Double) {
        var s = ContestSettings(); s.contest = .wpx; s.mode = .single; s.seed = 4242
        let game = ContestSimulator(settings: s); game.start()
        var now = 0.0
        func run(to time: Double) -> [RadioEvent] {
            var events: [RadioEvent] = []
            while now < time - 1e-9 { now = min(time, now + 0.08); game.tick(now); events += game.drainEvents() }
            return events
        }
        _ = run(to: 4.0)
        let caller = try XCTUnwrap(game.pileup.first)
        game.command(.esm, call: caller.call, exchange: "")
        // His call and the exchange are separate block-padded keyer pieces.
        let pieces = game.drainEvents().filter { $0.kind == .transmit }
        let tx = try XCTUnwrap(pieces.first)
        let onAir = pieces.reduce(0) { $0 + MorseTimeline.blockPadded(ContestRules.cwSeconds($1.text, wpm: s.wpm)) }
        // The audio host answers a tick late; that must not move the end.
        _ = run(to: 4.08)
        if acknowledge { game.acknowledgeTransmit(duration: onAir, startedAt: tx.at) }
        let reply = try XCTUnwrap(run(to: 30).first { $0.kind == .receive })
        return (reply.at, tx.at + onAir)
    }

    func testBlockPaddingRoundsUpToWholeBlocks() {
        let block = 512.0 / 11_025.0
        XCTAssertEqual(MorseTimeline.blockPadded(block * 10), block * 10, accuracy: 1e-9)
        XCTAssertEqual(MorseTimeline.blockPadded(block * 10 + 0.001), block * 11, accuracy: 1e-9)
        XCTAssertEqual(MorseTimeline.blockPadded(1.0), block * 22, accuracy: 1e-9)
    }

    func testCallerRepliesWithinMRCEsSendDelayOfTheBlockPaddedEnd() throws {
        let plain = try firstReply(acknowledge: false)
        // DxOper.GetSendDelay: 0.1 + 0.5 * Random seconds, in whole blocks.
        XCTAssertGreaterThanOrEqual(plain.reply - plain.txEnd, 0.1 - 0.025)
        XCTAssertLessThanOrEqual(plain.reply - plain.txEnd, 0.6 + 0.025)
        let acknowledged = try firstReply(acknowledge: true)
        XCTAssertEqual(acknowledged.reply, plain.reply, accuracy: 1e-9,
                       "an acknowledgement anchored to the event time leaves the schedule alone")
    }
}

final class HSTRefillTests: XCTestCase {
    /// MRCE refills the HST pile to Activity on every block. Callers that run
    /// out of patience must be replaced even when the operator does nothing.
    func testIdleHSTPileIsToppedUpAfterCallersGiveUp() {
        var settings=ContestSettings()
        settings.contest = .hst;settings.mode = .hstCompetition;settings.seed=5
        settings.competitionDuration=3;settings.wpm=30
        let game=ContestSimulator(settings:settings)
        game.start()
        var time=0.0
        var seen=Set<String>()
        while time < 90 {
            time += 0.08;game.tick(time)
            for event in game.drainEvents() where event.kind == .receive {seen.formUnion(event.stationCalls)}
            if time > 1 {XCTAssertEqual(game.pending,game.settings.activity,"pile size at \(time)")}
        }
        XCTAssertGreaterThan(seen.count,game.settings.activity,"callers that gave up should have been replaced")
    }
}
