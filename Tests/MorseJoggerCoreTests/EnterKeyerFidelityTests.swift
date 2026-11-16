//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

/// Regression tests for MRCE ProcessEnter fidelity: separate RST/exchange
/// boxes, a keyer that never depends on hidden caller state, and rows that are
/// not scored NIL because TU landed just before a caller's scheduled repeat.
final class EnterKeyerFidelityTests: XCTestCase {
    private func makeGame(seed: UInt32 = 4242) -> ContestSimulator {
        var s = ContestSettings()
        s.contest = .wpx
        s.mode = .single
        s.seed = seed
        let game = ContestSimulator(settings: s)
        game.start()
        return game
    }

    /// Ticks in 80 ms steps (the app's timer) up to `time`, collecting events.
    @discardableResult
    private func run(_ game: ContestSimulator, to time: Double, from start: Double) -> [RadioEvent] {
        var events: [RadioEvent] = []
        var now = start
        while now < time - 1e-9 {
            now = min(time, now + 0.08)
            game.tick(now)
            events += game.drainEvents()
        }
        return events
    }

    private func transmits(_ events: [RadioEvent]) -> [String] {
        events.filter { $0.kind == .transmit }.map(\.text)
    }

    // MARK: Finding 4

    func testEnterWithOnlyRSTFilledAsksForRepeatInsteadOfSendingTU() throws {
        let game = makeGame()
        run(game, to: 4.0, from: 0)
        let call = try XCTUnwrap(game.pileup.first).call
        game.command(.esm, call: call, exchange: "599", exchangeFirst: "599", exchangeSecond: "")
        run(game, to: 18.08, from: 4.0)
        XCTAssertNotNil(game.target)
        let events = { () -> [RadioEvent] in
            game.command(.esm, call: call, exchange: "599", exchangeFirst: "599", exchangeSecond: "")
            return game.drainEvents()
        }()
        XCTAssertEqual(transmits(events), ["?"])
        XCTAssertTrue(game.log.isEmpty, "RST alone must not log a contact")
    }

    func testJoinedExchangeWithOnlyReportAlsoAsksForRepeat() throws {
        // Callers that only pass the joined string still get the MRCE rule.
        let game = makeGame()
        run(game, to: 4.0, from: 0)
        let call = try XCTUnwrap(game.pileup.first).call
        game.command(.esm, call: call, exchange: "")
        run(game, to: 18.08, from: 4.0)
        game.command(.esm, call: call, exchange: "599")
        XCTAssertEqual(transmits(game.drainEvents()), ["?"])
        XCTAssertTrue(game.log.isEmpty)
    }

    func testBothBoxesFilledSendsTUAndLogs() throws {
        let game = makeGame()
        run(game, to: 4.0, from: 0)
        let caller = try XCTUnwrap(game.pileup.first)
        game.command(.esm, call: caller.call, exchange: "")
        run(game, to: 18.08, from: 4.0)
        let parts = caller.exchange.split(separator: " ").map(String.init)
        game.command(.esm, call: caller.call, exchange: caller.exchange,
                     exchangeFirst: parts[0], exchangeSecond: parts.dropFirst().joined(separator: " "))
        XCTAssertEqual(transmits(game.drainEvents()), ["TU"])
        XCTAssertEqual(game.log.count, 1)
    }

    func testEmptyFirstBoxWithSecondFilledAsksForRepeat() throws {
        let game = makeGame()
        run(game, to: 4.0, from: 0)
        let caller = try XCTUnwrap(game.pileup.first)
        game.command(.esm, call: caller.call, exchange: "")
        run(game, to: 18.08, from: 4.0)
        game.command(.esm, call: caller.call, exchange: "001", exchangeFirst: "", exchangeSecond: "001")
        XCTAssertEqual(transmits(game.drainEvents()), ["?"])
        XCTAssertTrue(game.log.isEmpty)
    }

    func testLoneReportIsNeverAStructurallyCompleteExchange() {
        var s = ContestSettings()
        for contest in [ContestID.wpx, .cqww, .arrldx, .arrl10, .iaru, .allja, .acag, .pota] {
            s.contest = contest
            XCTAssertFalse(ContestRules.isExchangeStructurallyValid(s, received: "599", expected: "599 001"), "\(contest)")
        }
        s.contest = .wpx
        XCTAssertTrue(ContestRules.isExchangeStructurallyValid(s, received: "599 001", expected: "599 001"))
    }

    func testNAQPDXCallNeedsNoState() throws {
        var s = ContestSettings()
        s.contest = .naqp
        s.mode = .single
        s.seed = 4242
        let game = ContestSimulator(settings: s)
        game.start()
        run(game, to: 1.0, from: 0)
        // First Enter sends call + exchange; a DX call with a name only counts as complete.
        game.command(.esm, call: "DL1ABC", exchange: "", exchangeFirst: "", exchangeSecond: "")
        _ = game.drainEvents()
        game.command(.esm, call: "DL1ABC", exchange: "BOB", exchangeFirst: "BOB", exchangeSecond: "")
        XCTAssertEqual(transmits(game.drainEvents()), ["TU"])
        XCTAssertEqual(game.log.count, 1)
    }

    // MARK: Finding 7

    func testUnmatchedCallTransmitsNormalMessageAndCallersRunNormalTransitions() throws {
        let game = makeGame()
        run(game, to: 4.0, from: 0)
        let caller = try XCTUnwrap(game.pileup.first)
        game.command(.esm, call: "ZZ9ZZZ", exchange: "")
        let tx = transmits(game.drainEvents())
        XCTAssertEqual(tx.count, 2, "his call, then the exchange")
        XCTAssertEqual(tx[0], "ZZ9ZZZ")
        XCTAssertFalse(tx.joined().contains("?"))
        var now = 4.0, sawPrevEnd = false
        while now < 20.0 && !sawPrevEnd {
            now += 0.08
            game.tick(now)
            sawPrevEnd = game.pileup.first(where: { $0.call == caller.call })?.opState == .needPrevEnd
        }
        XCTAssertTrue(sawPrevEnd, "No-match callers wait for the previous QSO to end")
        XCTAssertNil(game.target)
    }

    func testEmptyPileupStillTransmitsCallExchangeAndRequests() {
        for (command, call, expected): (Command, String, String?) in [
            (.esm, "K1ABC", nil), (.repeatMessage, "", "?"), (.numberAgain, "", "NR?"),
        ] {
            var s = ContestSettings()
            s.mode = .pileup
            s.seed = 7
            let game = ContestSimulator(settings: s)
            game.start()
            XCTAssertTrue(game.pileup.isEmpty)
            game.command(command, call: call, exchange: "")
            let tx = transmits(game.drainEvents())
            if let expected { XCTAssertEqual(tx, [expected]) } else { XCTAssertEqual(tx.first, "K1ABC");XCTAssertEqual(tx.count, 2, "\(command)") }
        }
    }

    func testSecondEnterLogsUnmatchedCallAsNILAndAdvancesSerial() throws {
        let game = makeGame()
        run(game, to: 4.0, from: 0)
        let serialBefore = game.snapshot.serial
        game.command(.esm, call: "ZZ9ZZZ", exchange: "")
        run(game, to: 10.0, from: 4.0)
        let notices = { () -> [RadioEvent] in
            game.command(.esm, call: "ZZ9ZZZ", exchange: "599 001", exchangeFirst: "599", exchangeSecond: "001")
            return game.drainEvents()
        }()
        XCTAssertEqual(transmits(notices), ["TU"])
        let row = try XCTUnwrap(game.log.first)
        XCTAssertEqual(game.log.count, 1)
        XCTAssertFalse(row.correct)
        XCTAssertEqual(row.points, 0)
        XCTAssertEqual(row.diagnosis.code, "NIL")
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(game.snapshot.serial, serialBefore + 1)
        XCTAssertEqual(game.verified, 0)
        XCTAssertEqual(game.selectedCall, "")
        // Nothing the player is meant to copy by ear may be announced as text.
        let text = notices.filter { $0.kind == .notice }.map(\.text).joined(separator: " ")
        XCTAssertFalse(text.lowercased().contains("matched"))
        XCTAssertFalse(text.lowercased().contains("no caller"))
    }

    // MARK: Finding 5

    /// Replays the review's scenario: Enter at 4.00 s, then Enter with the
    /// correct fields so that TU ends just before the caller's repeat (21.41 s).
    private func logAfterRepeatWindow(enterAt: Double) throws -> (ContestSimulator, QSOEntry) {
        let game = makeGame()
        run(game, to: 4.0, from: 0)
        let caller = try XCTUnwrap(game.pileup.first)
        game.command(.esm, call: caller.call, exchange: "")
        run(game, to: enterAt, from: 4.0)
        let parts = caller.exchange.split(separator: " ").map(String.init)
        game.command(.esm, call: caller.call, exchange: caller.exchange,
                     exchangeFirst: parts[0], exchangeSecond: parts.dropFirst().joined(separator: " "))
        run(game, to: 60.0, from: enterAt)
        return (game, try XCTUnwrap(game.log.first))
    }

    func testTUJustBeforeCallerRepeatIsNotScoredNIL() throws {
        // The earliest was already fine; the later two used to be scored NIL.
        for enterAt in [20.98, 21.14, 21.30] {
            let (game, row) = try logAfterRepeatWindow(enterAt: enterAt)
            XCTAssertTrue(row.correct, "Enter at \(enterAt) must log a correct QSO: \(row.note)")
            XCTAssertEqual(row.status, .completed)
            XCTAssertEqual(game.verified, 1)
        }
    }

    /// Enter one tick after the caller has started its repeat: the caller is
    /// sending and never hears the TU (MRCE `evMeFinished`), repeats until its
    /// patience runs out, and leaves. The row must turn NIL when it goes,
    /// without waiting for the operator's next CQ or TU.
    func testCallerThatNeverHearsTULeavesANilRowWhenItGivesUp() throws {
        let (game, row) = try logAfterRepeatWindow(enterAt: 21.44)
        XCTAssertFalse(game.pileup.contains { $0.call == row.call }, "the caller has left by 60 s")
        XCTAssertEqual(row.status, .completed)
        XCTAssertFalse(row.correct)
        XCTAssertEqual(row.diagnosis.code, "NIL")
        XCTAssertEqual(game.verified, 0)
    }

    func testCancelledScheduledReplyDoesNotLeaveAPhantomTransmitRange() throws {
        let game = makeGame()
        run(game, to: 4.0, from: 0)
        let caller = try XCTUnwrap(game.pileup.first)
        game.command(.esm, call: caller.call, exchange: "")
        _ = game.drainEvents()
        // Run until the caller has a reply scheduled but not yet audible.
        var now = 4.0
        var found = false
        while now < 40 && !found {
            now += 0.08
            game.tick(now)
            let events = game.drainEvents()
            if events.contains(where: { $0.kind == .receive }) { continue }
            if let range = game.fixtureCallerTransmitRanges(caller.call).first, range.start > now {
                found = true
                game.command(.repeatMessage)
                XCTAssertTrue(game.fixtureCallerTransmitRanges(caller.call).isEmpty,
                              "A reply cancelled by the operator's keying is no longer a transmission")
            }
        }
        XCTAssertTrue(found, "scenario should reach a scheduled reply")
    }

    func testRowStaysProvisionalUntilCallerAcceptsALaterTU() throws {
        let game = makeGame()
        run(game, to: 4.0, from: 0)
        let caller = try XCTUnwrap(game.pileup.first)
        game.fixtureSetOperatorState(caller.call, .needCallNr)
        game.command(.esm, call: caller.call, exchange: "", exchangeFirst: "", exchangeSecond: "")
        _ = game.drainEvents()
        let row = try XCTUnwrap(game.logQSO(call: caller.call, exchange: caller.exchange))
        run(game, to: 9.0, from: 4.0)
        XCTAssertEqual(game.log.first?.id, row.id)
        XCTAssertEqual(game.log.first?.status, .pendingTUConfirmation)
        // The caller accepts a later TU: the row becomes a correct contact.
        game.fixtureSetOperatorState(caller.call, .needEnd)
        game.command(.tu)
        run(game, to: 14.0, from: 9.0)
        XCTAssertEqual(game.log.count, 1)
        XCTAssertEqual(game.log.first?.status, .completed)
        XCTAssertTrue(game.log.first?.correct ?? false)
        XCTAssertEqual(game.verified, 1)
    }
}
