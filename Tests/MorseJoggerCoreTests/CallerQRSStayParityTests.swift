//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class CallerQRSStayParityTests: XCTestCase {
    private func station(skill: Int, state: OperatorState = .needEnd,
                         incomplete: Int = 0, baseWpm: Int = 25) -> Station {
        var value = Station(call: "K1ABC", exchange: "599 001", wpm: baseWpm,
                            tone: 600, volume: 1, shift: 0)
        value.baseWpm = baseWpm
        value.characterWpm = baseWpm
        value.skill = skill
        value.opState = state
        value.incomplete = incomplete
        value.patience = 20
        return value
    }

    private func incomplete(_ station: Station, settings: ContestSettings) -> Station {
        ContestSimulator(settings: settings).fixtureOperatorTransition(
            station, input: .question, confidence: 0
        )
    }

    func testQrsUsesSkillThresholdsAndBaseSpeedDropSchedule() {
        var settings = ContestSettings()
        settings.callerQrs = true

        for skill in 1...3 {
            var caller = station(skill: skill)
            caller.incomplete = skill == 3 ? 3 : 2
            caller = incomplete(caller, settings: settings)
            XCTAssertEqual(caller.incomplete, skill == 3 ? 4 : 3)
            let reduction = skill == 1 ? 0.20 : skill == 2 ? 0.16 : 0.14
            XCTAssertEqual(caller.wpm, Int((25.0 * (1 - reduction)).rounded()), "skill \(skill)")
            XCTAssertEqual(caller.qrsStage, caller.incomplete, "skill \(skill)")
        }

        var repeated = station(skill: 1, incomplete: 3, baseWpm: 25)
        repeated = incomplete(repeated, settings: settings)
        XCTAssertEqual(repeated.wpm, 20, "the fourth error uses a 22% drop from master speed")
    }

    func testQrsRequiresEnabledToggleEligibleStateAndAvailableConditions() {
        var settings = ContestSettings()
        settings.callerQrs = true

        var lids = settings
        lids.effects.lids = true
        XCTAssertEqual(incomplete(station(skill: 1, incomplete: 2), settings: lids).wpm, 25)

        var hst = settings
        hst.mode = .hstCompetition
        XCTAssertEqual(incomplete(station(skill: 1, incomplete: 2), settings: hst).wpm, 25)

        let outsideEligibleStates: [OperatorState] = [.needQso, .needPrevEnd, .done, .failed]
        for state in outsideEligibleStates {
            let changed = incomplete(station(skill: 1, state: state, incomplete: 2), settings: settings)
            XCTAssertEqual(changed.wpm, 25, "state \(state)")
        }

        var disabled = settings
        disabled.callerQrs = false
        XCTAssertEqual(incomplete(station(skill: 1, incomplete: 2), settings: disabled).wpm, 25)
    }

    func testQrsRoundsMediumSkillTargetFromMasterSpeed() {
        var settings = ContestSettings()
        settings.callerQrs = true
        let caller = incomplete(station(skill: 2, incomplete: 2, baseWpm: 10), settings: settings)
        // Pinned MRCE computes Round(10 * (1 - 0.16)) == 8. Its
        // master-minus-four guard applies only when rounding hides a drop.
        XCTAssertEqual(caller.wpm, 8)
    }

    func testHSTForcesCallerStayAndHonorsThreeSilentTimeoutLimit() {
        var settings = ContestSettings()
        settings.mode = .hstCompetition
        settings.callerStays = false
        let simulator = ContestSimulator(settings: settings)
        var caller = station(skill: 2, state: .needEnd)
        caller.patience = 1

        simulator.decrementPatience(&caller, silent: true)
        XCTAssertEqual(caller.patience, 1)
        XCTAssertEqual(caller.opState, .needEnd)
        XCTAssertEqual(caller.silentTimeouts, 1)

        simulator.decrementPatience(&caller, silent: true)
        XCTAssertEqual(caller.patience, 1)
        XCTAssertEqual(caller.opState, .needEnd)
        XCTAssertEqual(caller.silentTimeouts, 2)

        simulator.decrementPatience(&caller, silent: true)
        XCTAssertEqual(caller.patience, 0)
        XCTAssertEqual(caller.opState, .failed)
        XCTAssertEqual(caller.silentTimeouts, 3)
    }
}
