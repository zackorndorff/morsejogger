//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class CallerSpeedBoundaryTests: XCTestCase {
    private func firstCaller(settings: ContestSettings, at time: Double = 1) -> Station? {
        let game = ContestSimulator(settings: settings)
        game.start()
        game.tick(time)
        return game.pileup.first
    }

    private func singleSettings(seed: UInt32, wpm: Int = 30) -> ContestSettings {
        var settings = ContestSettings()
        settings.mode = .single
        settings.seed = seed
        settings.wpm = wpm
        settings.singleCallStartDelay = 0
        settings.customCalls = ["K1ABC"]
        return settings
    }

    func testUniformThirtyWPMOffsetsProduceTwentyFourThroughThirtyTwo() {
        var observed = Set<Int>()
        for seed in 1...128 {
            var settings = singleSettings(seed: UInt32(seed))
            settings.dxMinWpm = 6
            settings.dxMaxWpm = 2
            guard let caller = firstCaller(settings: settings) else {
                XCTFail("Expected the zero-delay single caller")
                return
            }
            observed.insert(caller.wpm)
            XCTAssertTrue((24...32).contains(caller.wpm), "seed \(seed): \(caller.wpm) WPM")
            XCTAssertEqual(caller.baseWpm, caller.wpm)
            XCTAssertEqual(caller.characterWpm, caller.wpm)
        }
        XCTAssertTrue(observed.count > 1, "Uniform offsets should vary caller speed")
    }

    func testGaussianThirtyWPMOffsetsUseMeanTwentyEightAndLimitFour() {
        var observed = Set<Int>()
        for seed in 1...128 {
            var settings = singleSettings(seed: UInt32(seed))
            settings.dxMinWpm = 6
            settings.dxMaxWpm = 2
            settings.gaussianSpeed = true
            guard let caller = firstCaller(settings: settings) else {
                XCTFail("Expected the zero-delay single caller")
                return
            }
            observed.insert(caller.wpm)
            XCTAssertTrue((24...32).contains(caller.wpm), "seed \(seed): \(caller.wpm) WPM")
        }
        XCTAssertTrue(observed.count > 1, "Gaussian offsets should vary caller speed")
    }

    func testEitherMinusOneOffsetUsesHalfToFullOperatorSpeed() {
        for minOffset in [-1, 0] {
            for maxOffset in [-1, 0] where minOffset == -1 || maxOffset == -1 {
                for seed in 1...64 {
                    var settings = singleSettings(seed: UInt32(seed))
                    settings.dxMinWpm = minOffset
                    settings.dxMaxWpm = maxOffset
                    guard let caller = firstCaller(settings: settings) else {
                        XCTFail("Expected the zero-delay single caller")
                        return
                    }
                    XCTAssertTrue((15...30).contains(caller.wpm), "offsets \(minOffset)/\(maxOffset), seed \(seed): \(caller.wpm) WPM")
                }
            }
        }
    }

    func testOffsetsBeyondOperatingSpeedRespectFiveWPMFloor() {
        for operatorWpm in [5, 15] {
            var settings = singleSettings(seed: 17, wpm: operatorWpm)
            settings.dxMinWpm = 80
            settings.dxMaxWpm = 0
            let caller = firstCaller(settings: settings)
            XCTAssertEqual(caller?.wpm, 5)
            XCTAssertEqual(caller?.baseWpm, 5)
            XCTAssertEqual(caller?.characterWpm, 5)
        }
    }

    /// MRCE `UpdCWMinRxSpeed`: below 15 WPM the slower limit is capped at 4.
    func testBelowFifteenWPMCallersAreAtMostFourSlower() {
        for operatorWpm in [10, 14] {
            for seed in 1...40 {
                var settings = singleSettings(seed: UInt32(seed), wpm: operatorWpm)
                settings.dxMinWpm = 10
                settings.dxMaxWpm = 0
                guard let caller = firstCaller(settings: settings) else { return XCTFail("no caller") }
                XCTAssertTrue((operatorWpm - 4...operatorWpm).contains(caller.wpm), "\(operatorWpm): \(caller.wpm)")
            }
        }
    }

    func testMinimumOffsetSurvivesOperatingSpeedChangesAndReload() throws {
        var settings = singleSettings(seed: 41, wpm: 15)
        settings.dxMinWpm = 8
        XCTAssertEqual(settings.effective().dxMinWpm, 8)

        // Direct settings changes use the same effective value as the UI and
        // simulator, including after a save/reload round trip.
        settings.wpm = 14
        XCTAssertEqual(settings.effective().dxMinWpm, 8)
        settings.wpm = 10
        XCTAssertEqual(settings.effective().dxMinWpm, 8)
        let saved = try JSONEncoder().encode(settings)
        let reloaded = try JSONDecoder().decode(ContestSettings.self, from: saved)
        XCTAssertEqual(reloaded.dxMinWpm, 8, "Decoding alone preserves stored data")
        XCTAssertEqual(reloaded.effective().dxMinWpm, 8, "Low-speed runtime preserves the loaded offset")

        settings.dxMinWpm = -1
        XCTAssertEqual(settings.effective().callerSpeedMode, .halfToFull)
        settings.wpm = 15
        XCTAssertEqual(settings.effective().callerSpeedMode, .halfToFull)
    }

    func testSpeedModeMigrationAndCustomRangeSurviveReloadAndSwitching() throws {
        for offsets in [(-1, 0), (0, -1), (-1, -1), (6, 2)] {
            var settings = singleSettings(seed: 41)
            settings.dxMinWpm = offsets.0
            settings.dxMaxWpm = offsets.1
            let oldData = try JSONEncoder().encode(settings)
            let oldSettings = try JSONDecoder().decode(ContestSettings.self, from: oldData)
            XCTAssertNil(oldSettings.callerSpeedSelection)
            let migrated = oldSettings.effective()
            XCTAssertEqual(migrated.callerSpeedMode, offsets.0 == -1 || offsets.1 == -1 ? .halfToFull : .custom)
            XCTAssertGreaterThanOrEqual(migrated.dxMinWpm, 0)
            XCTAssertGreaterThanOrEqual(migrated.dxMaxWpm, 0)
            let reloaded = try JSONDecoder().decode(ContestSettings.self, from: JSONEncoder().encode(migrated))
            XCTAssertEqual(reloaded, migrated)
        }

        var settings = singleSettings(seed: 41)
        settings.dxMinWpm = 6
        settings.dxMaxWpm = 2
        settings.callerSpeedMode = .halfToFull
        settings.callerSpeedMode = .custom
        XCTAssertEqual(settings.dxMinWpm, 6)
        XCTAssertEqual(settings.dxMaxWpm, 2)
    }

    func testExplicitPercentageModeOverridesCustomOffsetsAndGaussian() {
        for operatorWpm in [5, 10, 30] {
            var observed = Set<Int>()
            for seed in 1...64 {
                var settings = singleSettings(seed: UInt32(seed), wpm: operatorWpm)
                settings.dxMinWpm = 0
                settings.dxMaxWpm = 80
                settings.gaussianSpeed = true
                settings.callerSpeedMode = .halfToFull
                guard let caller = firstCaller(settings: settings) else {
                    XCTFail("Expected a caller")
                    return
                }
                observed.insert(caller.wpm)
                XCTAssertTrue((max(5, operatorWpm / 2)...operatorWpm).contains(caller.wpm))
            }
            if operatorWpm > 5 { XCTAssertGreaterThan(observed.count, 1) }
        }
    }

    func testHSTCallersUseOperatorSpeedAndBoundaryOperatingRatesRemainValid() {
        for operatorWpm in [10, 14, 15, 120] {
            var settings = ContestSettings()
            settings.mode = .hstCompetition
            settings.contest = .hst
            settings.seed = UInt32(operatorWpm)
            settings.wpm = operatorWpm
            settings.dxMinWpm = 80
            settings.dxMaxWpm = 80
            settings.gaussianSpeed = true
            guard let caller = firstCaller(settings: settings) else {
                XCTFail("Expected HST callers at \(operatorWpm) WPM")
                return
            }
            XCTAssertEqual(caller.wpm, operatorWpm)
            XCTAssertEqual(caller.baseWpm, operatorWpm)
            XCTAssertEqual(caller.characterWpm, operatorWpm)
            XCTAssertEqual(settings.effective().wpm, operatorWpm)
        }
    }
}
