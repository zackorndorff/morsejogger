//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class OperatorFSMTests: XCTestCase {
    func testRayleighPatienceLowTailBoundaryAndQsoTimeout() {
        let tieUniform = exp(-1.0 / 72.0)
        let belowHalfDraw = tieUniform * (1 + 1e-8)
        let aboveHalfDraw = tieUniform * (1 - 1e-8)

        XCTAssertEqual(ContestSimulator.rayleighPatience(first: tieUniform,
                                                          second: tieUniform), 3,
                       "the exact 0.5 boundary rounds to even zero, matching Delphi Round")
        XCTAssertEqual(ContestSimulator.rayleighPatience(first: belowHalfDraw,
                                                          second: belowHalfDraw), 3,
                       "a Rayleigh value below 0.5 rounds to zero, leaving the source minimum of three")
        XCTAssertEqual(ContestSimulator.rayleighPatience(first: aboveHalfDraw,
                                                          second: aboveHalfDraw), 4,
                       "a value above the half boundary rounds to one")

        var settings = ContestSettings()
        settings.callerStays = false
        let simulator = ContestSimulator(settings: settings)
        var station = Station(call: "K1ABC", exchange: "599 001", wpm: 25,
                              tone: 600, volume: 1, shift: 0)
        station.opState = .needQso
        station.patience = ContestSimulator.rayleighPatience(first: belowHalfDraw,
                                                              second: belowHalfDraw)
        simulator.decrementPatience(&station)
        XCTAssertEqual(station.patience, 2)
        simulator.decrementPatience(&station)
        XCTAssertEqual(station.patience, 1)
        simulator.decrementPatience(&station)
        XCTAssertEqual(station.patience, 0)
        XCTAssertEqual(station.opState, .failed,
                       "the three-count low-tail patience reaches the ordinary needQso timeout")
    }

    func testTUIsDirectlyExercisedFromEveryOperatorState() {
        let cases: [(OperatorState, Bool, OperatorState, [OperatorFSM.Effect])] = [
            (.needPrevEnd, true, .needQso, [.reset(.needQso), .decrementPatience]),
            (.needQso, true, .needQso, [.reset(.needQso), .decrementPatience]),
            (.needNr, true, .done, [.setState(.done), .decrementPatience]),
            (.needCall, true, .done, [.setState(.done), .decrementPatience]),
            (.needCallNr, true, .needQso, [.reset(.needQso), .decrementPatience]),
            (.needEnd, true, .done, [.setState(.done), .decrementPatience]),
            (.done, true, .done, [.decrementPatience]),
            (.failed, true, .failed, [.decrementPatience])
        ]

        for (state, selected, expectedState, expectedEffects) in cases {
            var driver = OperatorFSMDriver("TU from \(state.rawValue)", state: state)
            let step = driver.step(.init(kind: .tu, selectedForQSO: selected))
            XCTAssertTrue(step.accepted, "\(driver.scenario)")
            XCTAssertEqual(step.effects, expectedEffects, "\(driver.scenario)")
            XCTAssertEqual(step.station.opState, expectedState, "\(driver.scenario)")
        }
    }

    func testSelectedAndUnselectedTUHaveDistinctResetEffects() {
        var selected = OperatorFSMDriver("selected caller", state: .needCall)
        let selectedStep = selected.step(.init(kind: .tu, selectedForQSO: true))
        XCTAssertEqual(selectedStep.effects, [.setState(.done), .decrementPatience])
        XCTAssertEqual(selectedStep.callbacks, ["decrement"])

        var unselected = OperatorFSMDriver("unselected caller", state: .needCall)
        let unselectedStep = unselected.step(.init(kind: .tu, selectedForQSO: false))
        XCTAssertEqual(unselectedStep.effects, [.reset(.needQso), .decrementPatience])
        XCTAssertEqual(unselectedStep.callbacks, ["reset(needQso)", "decrement"])
        XCTAssertEqual(unselectedStep.station.patience, 6)
    }

    func testNeedCallNrTURequiresBothSelectionAndCorrectedCallExchangeFlags() {
        for selected in [false, true] {
            for correctedSent in [false, true] {
                var driver = OperatorFSMDriver(
                    "needCallNr selected=\(selected) corrected=\(correctedSent)",
                    state: .needCallNr, patience: 2, incomplete: 3,
                    correctedCallAndExchSent: correctedSent
                )
                let step = driver.step(.init(kind: .tu, selectedForQSO: selected))
                let succeeds = selected && correctedSent
                XCTAssertEqual(step.station.opState, succeeds ? .done : .needQso, driver.scenario)
                XCTAssertEqual(step.effects, succeeds
                    ? [.setState(.done), .decrementPatience]
                    : [.reset(.needQso), .decrementPatience], driver.scenario)
                XCTAssertEqual(step.callbacks, succeeds
                    ? ["decrement"]
                    : ["reset(needQso)", "decrement"], driver.scenario)
                XCTAssertEqual(step.station.patience, succeeds ? 1 : 6, driver.scenario)
                XCTAssertEqual(step.station.correctedCallAndExchSent, succeeds ? correctedSent : false,
                               driver.scenario)
                XCTAssertEqual(step.station.incomplete, 3,
                               "\(driver.scenario): the recording reset shim does not model production incomplete-state side effects")
            }
        }
    }

    func testOrdinaryQSOSequenceReturnsSnapshotsAndOrderedEffects() {
        var driver = OperatorFSMDriver("ordinary QSO", state: .needPrevEnd)
        let steps = driver.run([
            .init(kind: .cq),
            .init(kind: .call, typedCall: "K1ABC", confidence: 100),
            .init(kind: .exchange, exchangeAccepted: true),
            .init(kind: .tu)
        ])

        XCTAssertEqual(steps.map(\.station.opState), [.needQso, .needNr, .needEnd, .done])
        XCTAssertEqual(steps.map(\.effects), [
            [.reset(.needQso)],
            [.reset(.needNr), .decrementPatience],
            [.reset(.needEnd), .decrementPatience],
            [.setState(.done), .decrementPatience]
        ])
        XCTAssertEqual(steps[2].callbacks, ["acceptExchange", "reset(needEnd)", "decrement"])
    }

    func testCompoundCallAndExchangeRunsCallBeforeExchange() {
        var driver = OperatorFSMDriver("compound input", state: .needQso)
        let step = driver.step(.init(kind: .callAndExchange, typedCall: "K1ABC", confidence: 100))
        XCTAssertEqual(step.station.opState, .needEnd)
        XCTAssertEqual(step.effects, [.reset(.needNr), .reset(.needEnd), .decrementPatience])
        XCTAssertEqual(step.callbacks, ["reset(needNr)", "acceptExchange", "reset(needEnd)", "decrement"])
    }

    func testRejectedExchangeExtendsPatienceWithoutAdvancing() {
        var driver = OperatorFSMDriver("exchange retry", state: .needNr, patience: 3)
        let rejected = driver.step(.init(kind: .exchange, exchangeAccepted: false))
        XCTAssertEqual(rejected.station.opState, .needNr)
        XCTAssertEqual(rejected.effects, [.morePatience, .decrementPatience])
        XCTAssertEqual(rejected.station.patience, 4)

        let accepted = driver.step(.init(kind: .exchange, exchangeAccepted: true))
        XCTAssertEqual(accepted.station.opState, .needEnd)
        XCTAssertEqual(accepted.effects, [.reset(.needEnd), .decrementPatience])
    }

    func testQSOExchangeRetriesRemainPendingUntilAccepted() {
        var driver = OperatorFSMDriver("QSO with two rejected exchanges", state: .needPrevEnd)
        let opening = driver.step(.init(kind: .cq))
        let addressed = driver.step(.init(kind: .call, typedCall: "K1ABC", confidence: 100))
        let firstRetry = driver.step(.init(kind: .exchange, exchangeAccepted: false))
        let secondRetry = driver.step(.init(kind: .exchange, exchangeAccepted: false))
        let accepted = driver.step(.init(kind: .exchange, exchangeAccepted: true))
        let closed = driver.step(.init(kind: .tu))

        XCTAssertEqual([opening.station.opState, addressed.station.opState,
                        firstRetry.station.opState, secondRetry.station.opState,
                        accepted.station.opState, closed.station.opState],
                       [.needQso, .needNr, .needNr, .needNr, .needEnd, .done], driver.scenario)
        XCTAssertEqual([firstRetry.station.patience, secondRetry.station.patience,
                        accepted.station.patience, closed.station.patience], [7, 8, 6, 5], driver.scenario)
        XCTAssertEqual(firstRetry.effects, [.morePatience, .decrementPatience], driver.scenario)
        XCTAssertEqual(secondRetry.effects, [.morePatience, .decrementPatience], driver.scenario)
        XCTAssertEqual(accepted.effects, [.reset(.needEnd), .decrementPatience], driver.scenario)
        XCTAssertEqual(accepted.callbacks, ["acceptExchange", "reset(needEnd)", "decrement"], driver.scenario)
        XCTAssertEqual(closed.effects, [.setState(.done), .decrementPatience], driver.scenario)
    }

    func testCompoundPartialCallAndAcceptedExchangePreserveBothTransitions() {
        var driver = OperatorFSMDriver("compound partial call plus exchange", state: .needQso)
        let step = driver.step(.init(kind: .callAndExchange, typedCall: "K1AB?",
                                     confidence: 60, exchangeAccepted: true))
        XCTAssertEqual(step.station.opState, .needCall)
        XCTAssertEqual(step.station.incomplete, 1)
        XCTAssertEqual(step.effects, [.reset(.needCallNr), .incomplete,
                                      .reset(.needCall), .decrementPatience])
        XCTAssertEqual(step.callbacks, ["reset(needCallNr)", "incomplete", "acceptExchange",
                                        "reset(needCall)", "decrement"])
    }

    func testEarlyTUInNeedNrDependsOnWhetherCallerWasSelected() {
        var selected = OperatorFSMDriver("selected caller receives early TU", state: .needNr, patience: 3)
        let selectedStep = selected.step(.init(kind: .tu, selectedForQSO: true))
        XCTAssertEqual(selectedStep.station.opState, .done)
        XCTAssertEqual(selectedStep.station.patience, 2)
        XCTAssertEqual(selectedStep.effects, [.setState(.done), .decrementPatience])
        XCTAssertEqual(selectedStep.callbacks, ["decrement"])

        var unselected = OperatorFSMDriver("unselected caller receives early TU", state: .needNr, patience: 3)
        let unselectedStep = unselected.step(.init(kind: .tu, selectedForQSO: false))
        XCTAssertEqual(unselectedStep.station.opState, .needQso)
        XCTAssertEqual(unselectedStep.station.patience, 6)
        XCTAssertEqual(unselectedStep.effects, [.reset(.needQso), .decrementPatience])
        XCTAssertEqual(unselectedStep.callbacks, ["reset(needQso)", "decrement"])
    }

    func testPartialCallAndCorrectionUseOrderedResetAndIncompleteEffects() {
        var driver = OperatorFSMDriver("partial then exact", state: .needNr)
        let partial = driver.step(.init(kind: .call, typedCall: "K1AB?", confidence: 60))
        XCTAssertEqual(partial.station.opState, .needCallNr)
        XCTAssertEqual(partial.effects, [.reset(.needCallNr), .incomplete, .decrementPatience])
        XCTAssertEqual(partial.station.incomplete, 1)

        let exact = driver.step(.init(kind: .call, typedCall: "K1ABC", confidence: 100))
        XCTAssertEqual(exact.station.opState, .needNr)
        XCTAssertEqual(exact.effects, [.reset(.needNr), .decrementPatience])
        XCTAssertEqual(exact.station.incomplete, 1, "the reset shim records reset without modeling production side effects")
    }

    func testQuestionAndGarbageHaveDifferentPatienceEffects() {
        var question = OperatorFSMDriver("question", state: .needEnd)
        let q = question.step(.init(kind: .question))
        XCTAssertEqual(q.effects, [.incomplete, .decrementPatience])
        XCTAssertEqual(q.callbacks, ["incomplete", "decrement"])

        var garbage = OperatorFSMDriver("garbage", state: .needNr, patience: 2)
        let g = garbage.step(.init(kind: .garbage, lids: false))
        XCTAssertEqual(g.effects, [.morePatience, .decrementPatience])
        XCTAssertEqual(g.station.patience, 3)
    }

    func testCqAndNilCompleteOrFailNeedEndDifferently() {
        var cq = OperatorFSMDriver("CQ while ending", state: .needEnd)
        let cqStep = cq.step(.init(kind: .cq))
        XCTAssertEqual(cqStep.effects, [.setState(.done)])
        XCTAssertEqual(cqStep.station.opState, .done)

        var nilInput = OperatorFSMDriver("NIL while ending", state: .needEnd)
        let nilStep = nilInput.step(.init(kind: .nilInput))
        XCTAssertEqual(nilStep.effects, [.setState(.failed)])
        XCTAssertEqual(nilStep.station.opState, .failed)
    }

    func testCallMatchingDistinguishesExactPartialAndNoMatch() {
        var exact = OperatorFSMDriver("exact call", state: .needQso)
        let exactStep = exact.step(.init(kind: .call, typedCall: "K1ABC", matchResult: 100))
        XCTAssertEqual(exactStep.station.opState, .needNr)
        XCTAssertEqual(exactStep.effects, [.reset(.needNr), .decrementPatience])
        XCTAssertEqual(exactStep.callbacks, ["match", "reset(needNr)", "decrement"])

        var partial = OperatorFSMDriver("partial call", state: .needNr)
        let partialStep = partial.step(.init(kind: .call, typedCall: "K1AB", matchResult: 60))
        XCTAssertEqual(partialStep.station.opState, .needCallNr)
        XCTAssertEqual(partialStep.effects, [.reset(.needCallNr), .incomplete, .decrementPatience])

        var miss = OperatorFSMDriver("no call match", state: .needNr)
        let missStep = miss.step(.init(kind: .call, typedCall: "W9XYZ", matchResult: 0))
        XCTAssertEqual(missStep.station.opState, .needPrevEnd)
        XCTAssertEqual(missStep.effects, [.setState(.needPrevEnd)])
        XCTAssertEqual(missStep.callbacks, ["match"])
    }

    func testB4MyCallNumberQuestionAndEmptySelectionPaths() {
        var b4 = OperatorFSMDriver("B4 during exchange", state: .needNr)
        let b4Step = b4.step(.init(kind: .b4))
        XCTAssertEqual(b4Step.station.opState, .failed)
        XCTAssertEqual(b4Step.effects, [.setState(.failed), .decrementPatience])

        var myCall = OperatorFSMDriver("MY CALL in need call", state: .needCall)
        let myCallStep = myCall.step(.init(kind: .myCall))
        XCTAssertEqual(myCallStep.effects, [.decrementPatience])
        XCTAssertEqual(myCallStep.station.incomplete, 0)

        var nrQuestion = OperatorFSMDriver("NR question", state: .needNr, patience: 4)
        let nrStep = nrQuestion.step(.init(kind: .numberQuestion))
        XCTAssertEqual(nrStep.effects, [.decrementPatience])
        XCTAssertEqual(nrStep.station.patience, 3)

        var emptyQuestion = OperatorFSMDriver("question before selected call", state: .needPrevEnd)
        let emptyStep = emptyQuestion.step(.init(kind: .question, selectedCallIsEmpty: true))
        XCTAssertEqual(emptyStep.effects, [.reset(.needQso), .decrementPatience])
        XCTAssertEqual(emptyStep.station.opState, .needQso)
    }

    func testReplyPolicyConsumesOnlyLazyBranchDraws() {
        var station = OperatorFSMDriver("NR question at patience four", state: .needNr,
                                        patience: 4, replyCounter: 1).station
        var script = ScriptedReplyRandom([])
        let first = ContestSimulator.OperatorReplyPolicy.reply(
            &station, cause: .timeout, mode: .pileup, contest: .wpx, lids: false,
            nextRandom: { script.next() })
        XCTAssertEqual(first, "NR?")
        XCTAssertEqual(station.sendNrQuestionCount, 1,
                       "patience four short-circuits before the post-increment counter check")
        XCTAssertTrue(script.consumed.isEmpty, "patience four short-circuits before the random fallback")
        script.assertExhausted()

        station.patience = 3
        var fallback = ScriptedReplyRandom([0.8])
        let second = ContestSimulator.OperatorReplyPolicy.reply(
            &station, cause: .timeout, mode: .pileup, contest: .wpx, lids: false,
            nextRandom: { fallback.next() })
        XCTAssertEqual(second, "AGN")
        XCTAssertEqual(station.sendNrQuestionCount, 2,
                       "the next non-forced reply advances the counter once")
        XCTAssertEqual(fallback.consumed, [0.8])
        fallback.assertExhausted()

        // The post-increment returns the old value. A previous count of three
        // selects NR? without evaluating the random fallback.
        station.sendNrQuestionCount = 3
        var modulo = ScriptedReplyRandom([])
        let third = ContestSimulator.OperatorReplyPolicy.reply(
            &station, cause: .timeout, mode: .pileup, contest: .wpx, lids: false,
            nextRandom: { modulo.next() })
        XCTAssertEqual(third, "NR?")
        XCTAssertEqual(station.sendNrQuestionCount, 4)
        XCTAssertTrue(modulo.consumed.isEmpty)
        modulo.assertExhausted()
    }

    func testReplyPolicyCorrectedNeedEndUsesOrdinary90To10Choice() {
        var single = OperatorFSMDriver("corrected call single exchange", state: .needEnd, patience: 5).station
        var singleDraw = ScriptedReplyRandom([0.89])
        let singleReply = ContestSimulator.OperatorReplyPolicy.reply(
            &single, cause: .corrected, mode: .pileup, contest: .wpx, lids: false,
            nextRandom: { singleDraw.next() })
        XCTAssertEqual(singleReply, "R 599 001")
        XCTAssertEqual(singleDraw.consumed, [0.89], "corrected replies take the ordinary 90% branch draw")
        singleDraw.assertExhausted()

        var repeated = OperatorFSMDriver("corrected call repeated exchange", state: .needEnd, patience: 5).station
        var repeatDraw = ScriptedReplyRandom([0.95])
        let repeatedReply = ContestSimulator.OperatorReplyPolicy.reply(
            &repeated, cause: .corrected, mode: .pileup, contest: .wpx, lids: false,
            nextRandom: { repeatDraw.next() })
        XCTAssertEqual(repeatedReply, "R 599 001 599 001")
        XCTAssertEqual(repeatDraw.consumed, [0.95], "the 10% repeat branch consumes exactly one draw")
        repeatDraw.assertExhausted()

        for (mode, contest) in [(SessionMode.hstCompetition, ContestID.wpx), (.pileup, .sweepstakes)] {
            var exception = OperatorFSMDriver("corrected call policy exception", state: .needEnd, patience: 5).station
            var unused = ScriptedReplyRandom([])
            let reply = ContestSimulator.OperatorReplyPolicy.reply(
                &exception, cause: .corrected, mode: mode, contest: contest, lids: false,
                nextRandom: { unused.next() })
            XCTAssertEqual(reply, "R 599 001")
            XCTAssertTrue(unused.consumed.isEmpty, "verified deterministic exceptions skip the random choice")
            unused.assertExhausted()
        }
    }
}
