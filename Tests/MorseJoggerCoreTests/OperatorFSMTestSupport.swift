//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

/// Small direct driver for the caller dialogue protocol. The callbacks are
/// recording shims: each test supplies explicit results and side effects.
struct OperatorFSMDriver {
    struct Input {
        var kind: OperatorInput
        var typedCall = ""
        var confidence: Int? = nil
        var selectedCallIsEmpty = false
        var selectedForQSO = true
        var exchangeAccepted = true
        var matchResult = 100
        var contest: ContestID = .wpx
        var mode: SessionMode = .pileup
        var lids = false
    }

    struct Step {
        let accepted: Bool
        let effects: [OperatorFSM.Effect]
        let callbacks: [String]
        let station: Station
    }

    private(set) var station: Station
    private(set) var scenario: String

    init(_ scenario: String, state: OperatorState, patience: Int = 6,
         silentTimeouts: Int = 0, incomplete: Int = 0,
         correctedCallAndExchSent: Bool = false, replyCounter: Int = 0) {
        self.scenario = scenario
        var value = Station(call: "K1ABC", exchange: "599 001", wpm: 25,
                            tone: 600, volume: 1, shift: 0)
        value.opState = state
        value.patience = patience
        value.silentTimeouts = silentTimeouts
        value.incomplete = incomplete
        value.correctedCallAndExchSent = correctedCallAndExchSent
        value.sendNrQuestionCount = replyCounter
        station = value
    }

    @discardableResult
    mutating func step(_ input: Input) -> Step {
        var callbacks: [String] = []
        var settings = ContestSettings()
        settings.contest = input.contest
        settings.mode = input.mode
        settings.effects.lids = input.lids
        let result = OperatorFSM.transition(
            input: input.kind, station: &station, typed: input.typedCall,
            knownConfidence: input.confidence, settings: settings,
            selectedCallIsEmpty: input.selectedCallIsEmpty,
            selectedForQSO: input.selectedForQSO,
            matchCall: { _, _ in callbacks.append("match"); return input.matchResult },
            reset: { station, state in
                callbacks.append("reset(\(state.rawValue))")
                station.opState = state
                station.patience = 7
                station.correctedCallAndExchSent = false
            },
            decrement: { station in callbacks.append("decrement"); station.patience -= 1 },
            morePatience: { station in callbacks.append("morePatience"); station.patience += 2 },
            markIncomplete: { station in callbacks.append("incomplete"); station.incomplete += 1 },
            acceptExchange: { _ in callbacks.append("acceptExchange"); return input.exchangeAccepted }
        )
        return Step(accepted: result.accepted, effects: result.effects,
                    callbacks: callbacks, station: station)
    }

    mutating func run(_ inputs: [Input]) -> [Step] {
        var snapshots: [Step] = []
        for input in inputs { snapshots.append(step(input)) }
        return snapshots
    }
}

/// A lazy, fail-fast source of reply-policy draws. Branches that should
/// short-circuit must leave values unused; call `assertExhausted` afterward.
struct ScriptedReplyRandom {
    private(set) var values: [Double]
    private(set) var consumed: [Double] = []

    init(_ values: [Double]) { self.values = values }

    mutating func next() -> Double {
        guard !values.isEmpty else {
            XCTFail("scripted reply RNG exhausted after \(consumed.count) draw(s)")
            return 0
        }
        let value = values.removeFirst()
        consumed.append(value)
        return value
    }

    func assertExhausted(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(values.isEmpty, "unused scripted reply draws: \(values)", file: file, line: line)
    }
}
