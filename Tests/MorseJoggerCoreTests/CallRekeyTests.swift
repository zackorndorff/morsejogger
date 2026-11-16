//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

/// MRCE `MyStn.UpdateCallInMessage`, `MainForm.Edit1Change` and
/// `MainForm.Advance`: correcting the caller's call while it is being keyed,
/// and moving the cursor when that piece ends.
final class CallRekeyTests: XCTestCase {
    private let start = 6.0 * 512.0 / 11025.0

    private func makeGame() -> ContestSimulator {
        var settings = ContestSettings()
        settings.contest = .wpx; settings.mode = .single; settings.seed = 1234
        let game = ContestSimulator(settings: settings)
        game.start(); game.tick(start); _ = game.drainEvents()
        return game
    }
    private func pieceLength(_ text: String, _ game: ContestSimulator) -> Double {
        MorseTimeline.blockPadded(MorseTimeline.duration(text, wpm: game.settings.wpm))
    }
    /// The call with its last character changed, so the keying differs only at the end.
    private func miscopy(_ call: String) -> String {
        String(call.dropLast()) + (call.last == "A" ? "B" : "A")
    }

    func testSameKeyingComparesOnlyWhatHasBeenSent() {
        let abc = MorseTimeline.marks("K1ABC", wpm: 25), abd = MorseTimeline.marks("K1ABD", wpm: 25)
        let ab = MorseTimeline.marks("K1AB", wpm: 25), w = MorseTimeline.marks("W1ABC", wpm: 25)
        let lastStart = abc[abc.count - 4].start       // C is four elements
        XCTAssertTrue(MorseTimeline.sameKeying(abc, abd, until: lastStart))
        // C (-.-.) and D (-..) share their first two elements.
        XCTAssertTrue(MorseTimeline.sameKeying(abc, abd, until: abc[abc.count - 2].start))
        XCTAssertFalse(MorseTimeline.sameKeying(abc, abd, until: abc[abc.count - 1].start))
        XCTAssertTrue(MorseTimeline.sameKeying(abc, ab, until: lastStart), "a character not yet started can be dropped")
        XCTAssertFalse(MorseTimeline.sameKeying(abc, ab, until: lastStart + 0.01))
        XCTAssertTrue(MorseTimeline.sameKeying(abc, w, until: 0))
        // K (-.-) and W (.--) differ from the first element.
        XCTAssertFalse(MorseTimeline.sameKeying(abc, w, until: 0.06))
    }

    func testCallCorrectedWhileBeingKeyedIsSentCorrectedAndStaysSent() throws {
        let game = makeGame()
        let caller = try XCTUnwrap(game.pileup.first).call
        let typed = miscopy(caller)
        game.command(.esm, call: typed)
        let sent = game.drainEvents().filter { $0.kind == .transmit }
        XCTAssertEqual(sent.first?.text, typed)

        game.tick(start + 0.15)
        XCTAssertTrue(game.callEdited(caller))
        let rekey = game.drainEvents().filter { $0.kind == .rekey }
        XCTAssertEqual(rekey.map(\.text), [caller])
        XCTAssertEqual(rekey.first?.pieceID, sent.first?.pieceID)
        XCTAssertNotNil(rekey.first?.pieceID)
        XCTAssertTrue(game.fixtureSentFlags().call, "the corrected call is the one on the air")

        game.tick(start + 10)
        XCTAssertEqual(game.targetCall, caller, "callers hear the corrected call")
        // A second Enter does not send the call again.
        game.command(.esm, call: caller)
        XCTAssertFalse(game.drainEvents().contains { $0.kind == .transmit && $0.text == caller })
    }

    func testEditToAPartAlreadySentIsNotReKeyedAndTheCallIsOwedAgain() throws {
        let game = makeGame()
        let caller = try XCTUnwrap(game.pileup.first).call
        game.command(.esm, call: caller); _ = game.drainEvents()
        game.tick(start + 0.5)
        let edited = (caller.first == "W" ? "K" : "W") + caller.dropFirst()
        XCTAssertFalse(game.callEdited(edited))
        XCTAssertFalse(game.drainEvents().contains { $0.kind == .rekey })
        XCTAssertFalse(game.fixtureSentFlags().call, "MRCE clears CallSent")
        XCTAssertTrue(game.fixtureSentFlags().exchange)
    }

    func testEditAfterTheCallHasGoneClearsCallSent() throws {
        let game = makeGame()
        let caller = try XCTUnwrap(game.pileup.first).call
        game.command(.esm, call: caller); _ = game.drainEvents()
        game.tick(start + pieceLength(caller, game) + 0.05)   // the exchange is being sent
        XCTAssertFalse(game.callEdited(miscopy(caller)))
        XCTAssertFalse(game.fixtureSentFlags().call)
    }

    func testCallQueuedBehindOtherTextIsReplacedWhatever() throws {
        let game = makeGame()
        game.command(.cq)
        game.command(.hiscall, call: "K1ABC")
        let queued = game.drainEvents().filter { $0.kind == .transmit }
        XCTAssertEqual(queued.last?.text, "K1ABC")
        game.tick(start + 0.4)
        XCTAssertTrue(game.callEdited("W2XYZ"))
        let rekey = game.drainEvents().filter { $0.kind == .rekey }
        XCTAssertEqual(rekey.map(\.text), ["W2XYZ"])
        XCTAssertEqual(rekey.first?.pieceID, queued.last?.pieceID)
    }

    func testEmptyCallBoxIsNeverKeyedAndClearsBothFlags() throws {
        let game = makeGame()
        let caller = try XCTUnwrap(game.pileup.first).call
        game.command(.esm, call: caller); _ = game.drainEvents()
        game.tick(start + 0.1)
        XCTAssertFalse(game.callEdited(""))
        XCTAssertFalse(game.fixtureSentFlags().call)
        XCTAssertFalse(game.fixtureSentFlags().exchange)
    }

    func testLongerCallMovesTheRestOfTheTransmissionBack() throws {
        let game = makeGame()
        game.command(.esm, call: "K1AB"); _ = game.drainEvents()
        game.tick(start + 0.1)
        XCTAssertTrue(game.callEdited("K1ABC"))
        _ = game.drainEvents()
        let callEnd = start + pieceLength("K1ABC", game)
        game.tick(callEnd - 0.03)
        XCTAssertFalse(game.drainEvents().contains { $0.kind == .advanceEntry })
        game.tick(callEnd + 0.001)
        XCTAssertEqual(game.drainEvents().filter { $0.kind == .advanceEntry }.count, 1)
    }

    func testHostBufferPositionDecidesExactlyWhatHasBeenSent() throws {
        // C (-.-.) and D (-..) part company at C's third element.
        let marks = MorseTimeline.marks("K1ABC", wpm: 25)
        let diverge = marks[marks.count - 2].start + marks[marks.count - 2].duration.magnitude * 0 + 0.05
        func edit(sent: Double, to call: String = "K1ABD") -> Bool {
            let game = makeGame()
            game.command(.esm, call: "K1ABC"); _ = game.drainEvents()
            return game.callEdited(call) { _ in sent }
        }
        XCTAssertTrue(edit(sent: marks[marks.count - 2].start), "nothing that differs has reached the buffer")
        XCTAssertTrue(edit(sent: diverge), "a dit and the first third of a dah are the same samples")
        XCTAssertFalse(edit(sent: diverge + 0.002), "the dit has ended in the buffer; the dah has not")
        XCTAssertFalse(edit(sent: .infinity), "the piece has left the buffer")
        XCTAssertTrue(edit(sent: 0, to: "W2XYZ"), "not started: any call can replace it")
        XCTAssertTrue(edit(sent: -0.2, to: "W2XYZ"))
    }

    // MARK: MainForm.Advance

    func testCursorAdvanceIsAnnouncedWhenTheCallHasBeenKeyed() throws {
        let game = makeGame()
        let caller = try XCTUnwrap(game.pileup.first).call
        game.command(.esm, call: caller)
        XCTAssertFalse(game.drainEvents().contains { $0.kind == .advanceEntry }, "not at the key press")
        let callEnd = start + pieceLength(caller, game)
        game.tick(callEnd - 0.03)
        XCTAssertFalse(game.drainEvents().contains { $0.kind == .advanceEntry })
        game.tick(callEnd + 0.001)
        XCTAssertEqual(game.drainEvents().filter { $0.kind == .advanceEntry }.count, 1,
                       "the cursor moves once his call is sent, before the exchange ends")
        game.tick(callEnd + 10)
        XCTAssertFalse(game.drainEvents().contains { $0.kind == .advanceEntry }, "once only")
    }

    func testNoAdvanceForAPartialCallACQOrAfterMovingByHand() throws {
        let game = makeGame()
        game.command(.esm, call: "K1?")
        game.tick(start + 5)
        XCTAssertFalse(game.drainEvents().contains { $0.kind == .advanceEntry })

        game.command(.esm, call: "")
        game.tick(start + 12)
        XCTAssertFalse(game.drainEvents().contains { $0.kind == .advanceEntry })

        game.command(.esm, call: "K1ABC")
        game.cancelEntryAdvance()
        game.tick(start + 20)
        XCTAssertFalse(game.drainEvents().contains { $0.kind == .advanceEntry })
    }

    func testAbortedTransmissionLeavesTheAdvanceForTheNextPiece() throws {
        let game = makeGame()
        game.command(.esm, call: "K1ABC")
        game.tick(start + 0.1)
        game.command(.stop)
        game.tick(start + 5)
        XCTAssertFalse(game.drainEvents().contains { $0.kind == .advanceEntry }, "AbortSend ends no piece")
        game.command(.cq)
        game.tick(start + 12)
        XCTAssertEqual(game.drainEvents().filter { $0.kind == .advanceEntry }.count, 1,
                       "MustAdvance is still set when the next piece ends")
    }

    func testAdvanceTargetFollowsTheCallBoxAtThatMoment() {
        XCTAssertEqual(ContestRules.entryFieldOnAdvance(call: "K1ABC", contest: .wpx), .exchangeSecond, "the report is skipped")
        XCTAssertEqual(ContestRules.entryFieldOnAdvance(call: "K1ABC", contest: .sweepstakes), .exchangeSecond)
        XCTAssertEqual(ContestRules.entryFieldOnAdvance(call: "K1ABC", contest: .cwt), .exchangeFirst)
        XCTAssertEqual(ContestRules.entryFieldOnAdvance(call: "K1A?C", contest: .wpx), .callsign)
        XCTAssertEqual(ContestRules.entryFieldOnAdvance(call: "", contest: .cwt), .callsign)
    }

    func testTransmitSchedulerMovesLaterMacrosWithAReKeyedCall() {
        var scheduler = TransmitFrameScheduler()
        _ = scheduler.schedule(currentFrame: 0, generation: 1, durationFrames: 1000, spacingFrames: 0)
        scheduler.shift(by: 250)
        XCTAssertEqual(scheduler.schedule(currentFrame: 10, generation: 1, durationFrames: 10, spacingFrames: 0).startDelaySamples, 1240)
    }
}
