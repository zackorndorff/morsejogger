//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class LiveActivityRadioTests: XCTestCase {
    func testActivitySettingSurvivesSettingsPersistenceRoundTrip() throws {
        var settings = ContestSettings()
        settings.activity = 9
        let saved = try JSONEncoder().encode(settings)
        let reloaded = try JSONDecoder().decode(ContestSettings.self, from: saved)
        XCTAssertEqual(reloaded.activity, 9)
    }

    func testActivityChangesApplyToFutureArrivalsWithoutDroppingExistingCallers() {
        var settings = ContestSettings()
        settings.mode = .pileup
        settings.activity = 9
        settings.seed = 77

        let game = ContestSimulator(settings: settings)
        game.start()
        game.command(.cq)
        game.tick(20)
        let callersBeforeEdit = game.pileup.map(\.call)
        XCTAssertFalse(callersBeforeEdit.isEmpty)

        settings.activity = 1
        game.updateRadio(settings)
        XCTAssertEqual(game.settings.activity, 1)
        XCTAssertEqual(game.pileup.map(\.call), callersBeforeEdit,
                       "Changing activity must not replace callers already on the band")

        // The next CQ's arrival draw uses the new Activity while the current
        // callers continue through the same session.
        game.command(.cq)
        game.tick(40)
        XCTAssertEqual(game.settings.activity, 1)

        var lowSettings = ContestSettings()
        lowSettings.mode = .pileup
        lowSettings.activity = 1
        lowSettings.seed = 17
        var highSettings = lowSettings
        highSettings.activity = 9
        let low = ContestSimulator(settings: lowSettings)
        let high = ContestSimulator(settings: highSettings)
        low.start(); high.start()
        low.command(.cq); high.command(.cq)
        low.tick(20); high.tick(20)
        XCTAssertGreaterThan(high.pileup.count, low.pileup.count,
                             "Future arrival draws use the current Activity value")
    }

    func testActivityClampsAtLiveUpdateBoundariesAndHSTKeepsEffectiveLock() {
        var settings = ContestSettings()
        settings.mode = .pileup
        let game = ContestSimulator(settings: settings)

        settings.activity = 0
        game.updateRadio(settings)
        XCTAssertEqual(game.settings.activity, 1)
        settings.activity = 10
        game.updateRadio(settings)
        XCTAssertEqual(game.settings.activity, 9)

        var hstSettings = ContestSettings()
        hstSettings.mode = .hstCompetition
        hstSettings.seed = 92
        let hst = ContestSimulator(settings: hstSettings)
        hst.start()
        let hstCallersBeforeEdit = hst.pileup.map(\.call)
        hstSettings.activity = 9
        hstSettings.bandwidth = 150
        hstSettings.effects = .all(true)
        hst.updateRadio(hstSettings)
        XCTAssertEqual(hst.settings.activity, 4)
        XCTAssertEqual(hst.settings.bandwidth, 600)
        XCTAssertEqual(hst.settings.effects, .all(false))
        XCTAssertEqual(hst.pileup.map(\.call), hstCallersBeforeEdit,
                       "HST's fixed effective Activity preserves existing callers")
    }
}
