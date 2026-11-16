//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class CallerSessionTraceTests: XCTestCase {
    func testOrdinaryContactWaitsForTXAcknowledgementAndFinalizesCapturedRowOnce() throws {
        var settings = ContestSettings()
        settings.mode = .single
        settings.seed = 0x7A31
        let game = ContestSimulator(settings: settings)
        game.start()
        var now = 6.0 * 512.0 / 11025.0
        game.tick(now)
        let caller = try XCTUnwrap(game.pileup.first)

        game.command(.call, call: caller.call)
        // His call and the exchange are separate keyer pieces, as in MRCE.
        let callTX = game.drainEvents().filter { $0.kind == .transmit }.map(\.text)
        XCTAssertNil(game.targetCall, "The caller must not process an uncompleted call")
        let callDuration = callTX.reduce(0) { $0 + MorseTimeline.blockPadded(ContestRules.cwSeconds($1, wpm: settings.wpm)) }
        game.acknowledgeTransmit(duration: callDuration + 0.4)
        game.tick(now + callDuration)
        XCTAssertNil(game.targetCall, "The audio acknowledgement extends the predicted TX boundary")
        now += callDuration + 0.41
        game.tick(now)
        XCTAssertEqual(game.targetCall, caller.call)
        XCTAssertEqual(game.target?.opState, .needEnd,
                       "The call macro includes the sent exchange and advances directly to the caller's report")

        // Drain and acknowledge the caller's first reply before sending the exchange.
        now += 5
        game.tick(now)
        let firstReply = game.drainEvents().first { $0.kind == .receive }
        if let firstReply {
            let duration = ContestRules.cwSeconds(firstReply.text, wpm: caller.wpm)
            game.acknowledgeReceive(duration: duration + 0.1)
            now += duration + 0.11
            game.tick(now)
        }

        // Allow the report to arrive, then create the pending row and key TU.
        now += 5
        game.tick(now)
        let report = game.drainEvents().first { $0.kind == .receive }
        if let report {
            let duration = ContestRules.cwSeconds(report.text, wpm: caller.wpm)
            game.acknowledgeReceive(duration: duration + 0.1)
            now += duration + 0.11
            game.tick(now)
        }
        let row = try XCTUnwrap(game.logQSO(call: caller.call, exchange: caller.exchange))
        XCTAssertEqual(row.status, .pendingTUConfirmation)
        XCTAssertEqual(game.verified, 0)
        let tuTX = try XCTUnwrap(game.drainEvents().first { $0.kind == .transmit })
        XCTAssertEqual(game.target?.opState, .needEnd, "TU is not processed when merely queued")
        let tuDuration = ContestRules.cwSeconds(tuTX.text, wpm: settings.wpm)
        game.acknowledgeTransmit(duration: tuDuration + 0.5)
        now += tuDuration
        game.tick(now)
        XCTAssertEqual(game.target?.opState, .needEnd)
        XCTAssertEqual(game.log.first?.id, row.id)
        XCTAssertEqual(game.log.first?.status, .pendingTUConfirmation)

        now += 6
        game.tick(now)
        XCTAssertNil(game.targetCall, "Single mode removes the caller after its accepted TU")
        XCTAssertEqual(game.log.count, 1)
        XCTAssertEqual(game.log.first?.id, row.id, "TU reconciles the captured row rather than appending another")
        XCTAssertEqual(game.log.first?.status, .completed)
        XCTAssertTrue(game.log.first?.correct ?? false)
        XCTAssertEqual(game.verified, 1)

        now += 10
        game.tick(now)
        XCTAssertEqual(game.log.count, 1, "Later ticks must not finalize the same contact twice")
        XCTAssertEqual(game.verified, 1)
    }

    func testIncompleteCorrectedTUWaitsForAcknowledgedTXThenLeavesPendingRowUnverified() throws {
        var settings = ContestSettings()
        settings.mode = .single
        settings.seed = 0x7A32
        let game = ContestSimulator(settings: settings)
        game.start()
        let startup = 6.0 * 512.0 / 11025.0
        game.tick(startup)
        let caller = try XCTUnwrap(game.pileup.first)
        game.fixtureSetOperatorState(caller.call, .needCallNr)
        let row = try XCTUnwrap(game.logQSO(call: caller.call, exchange: caller.exchange))

        game.command(.tu)
        let tx = try XCTUnwrap(game.drainEvents().first { $0.kind == .transmit })
        let actualDuration = ContestRules.cwSeconds(tx.text, wpm: settings.wpm) + 2
        game.acknowledgeTransmit(duration: actualDuration)
        game.tick(startup + actualDuration - 0.01)
        XCTAssertEqual(game.target?.opState, .needCallNr)
        XCTAssertEqual(game.log.first?.id, row.id)
        XCTAssertEqual(game.log.first?.status, .pendingTUConfirmation)
        XCTAssertEqual(game.verified, 0)

        game.tick(startup + actualDuration + 0.01)
        XCTAssertEqual(game.target?.opState, .needQso, "Rejected corrected TU takes the F01 fallback after TX completes")
        XCTAssertEqual(game.log.count, 1)
        XCTAssertEqual(game.log.first?.id, row.id)
        // The caller is still in the QSO, so the row stays provisional until a
        // later TU that it accepts (or its departure) reconciles it.
        XCTAssertEqual(game.log.first?.status, .pendingTUConfirmation)
        XCTAssertFalse(game.log.first?.correct ?? true)
        XCTAssertEqual(game.verified, 0)
    }
}
