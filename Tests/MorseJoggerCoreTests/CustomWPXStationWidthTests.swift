//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class CustomWPXStationWidthTests: XCTestCase {
    func testCustom01To99StationRetainsEnteredWidthAndSeededFormattingBranch() throws {
        func firstCaller(seed: UInt32) throws -> (ContestSettings, Station) {
            var settings = ContestSettings()
            settings.contest = .wpx
            settings.mode = .pileup
            settings.serialRange = .custom
            settings.serialMin = 1
            settings.serialMax = 99
            settings.serialMinDigits = 2
            settings.serialMaxDigits = 2
            settings.activity = 9
            settings.seed = seed

            let game = ContestSimulator(settings: settings)
            game.start()
            game.command(.cq)
            game.tick(60)
            return (settings, try XCTUnwrap(game.pileup.first))
        }

        let (settings, station) = try firstCaller(seed: 0x01_99)
        let (_, repeatedStation) = try firstCaller(seed: 0x01_99)
        XCTAssertEqual(station.serialMinimumWidth, 2, "Entered 01–99 minimum keeps two digit width on generated stations")
        XCTAssertEqual(station.serialNaturalWidth, 1)
        XCTAssertEqual(station.serialUsesMinimumWidth, repeatedStation.serialUsesMinimumWidth,
                       "The caller's pad or natural-width branch is stable across the same seeded run")

        let formatted = ContestRules.callerSerialText(
            settings,
            serial: 1,
            customMinimumWidth: station.serialMinimumWidth,
            naturalWidth: station.serialNaturalWidth,
            useMinimumWidth: station.serialUsesMinimumWidth ?? true)
        XCTAssertEqual(formatted, station.serialUsesMinimumWidth == false ? "1" : "01")
    }
}
