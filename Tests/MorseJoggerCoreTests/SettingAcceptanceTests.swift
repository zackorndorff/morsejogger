//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class SettingAcceptanceTests: XCTestCase {
    func testCompetitionEffectiveSettingsAndUnrelatedLiveRadioEdit() throws {
        var saved = ContestSettings()
        saved.effects = .all(false)
        saved.bandwidth = 150
        saved.mode = .wpxCompetition

        let wpx = saved.effective()
        XCTAssertEqual(wpx.effects, .all(true))
        XCTAssertEqual(wpx.bandwidth, 150)

        saved.mode = .hstCompetition
        let hst = saved.effective()
        XCTAssertEqual(hst.effects, .all(false))
        XCTAssertEqual(hst.bandwidth, 600)

        let game = ContestSimulator(settings: saved)
        game.start()
        var unrelatedEdit = saved
        unrelatedEdit.wpm = 120
        unrelatedEdit.bandwidth = 150
        unrelatedEdit.effects = .all(true)
        game.updateRadio(unrelatedEdit)
        XCTAssertEqual(game.settings.effects, .all(false), "An unrelated live edit must retain HST's forced effects")
        XCTAssertEqual(game.settings.bandwidth, 600, "HST bandwidth remains forced after a live edit")

        saved.mode = .pileup
        XCTAssertEqual(saved.effective().effects, .all(false), "Leaving competition restores the saved practice preference")
        XCTAssertEqual(saved.effective().bandwidth, 150)

        let roundTrip = try JSONDecoder().decode(ContestSettings.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(roundTrip.effects, saved.effects)
        XCTAssertEqual(roundTrip.bandwidth, saved.bandwidth)
    }

    func testWPM120AndEvery50HzBandwidthChoiceSurviveCoreSettingsAndLiveUpdate() {
        var settings = ContestSettings()
        settings.mode = .pileup
        settings.wpm = 120
        settings.bandwidth = 150
        XCTAssertEqual(settings.effective().wpm, 120)
        XCTAssertEqual(settings.effective().bandwidth, 150)

        let game = ContestSimulator(settings: settings)
        game.start()
        for bandwidth in stride(from: 100, through: 600, by: 50) {
            settings.wpm = 120
            settings.bandwidth = bandwidth
            game.updateRadio(settings)
            XCTAssertEqual(game.settings.wpm, 120)
            XCTAssertEqual(game.settings.bandwidth, bandwidth)
        }
    }

    func testCustomSerialRangeValidationAndEqualEndpointSemantics() {
        var settings=ContestSettings();settings.serialRange = .custom
        settings.serialMin=1;settings.serialMax=2
        XCTAssertNil(settings.customSerialRangeError)
        var oneOnlyRNG=ContestRNG(seed:18)
        XCTAssertEqual(SerialDistribution.draw(settings,rng:&oneOnlyRNG,elapsed:0,skill:1),1)

        settings.serialMin=5001;settings.serialMax=9999
        XCTAssertNil(settings.customSerialRangeError)
        settings.serialMin=17;settings.serialMax=17
        XCTAssertNil(settings.customSerialRangeError,"Equal endpoints are accepted and handled as a fixed value")
        var equalRNG=ContestRNG(seed:19)
        XCTAssertEqual(SerialDistribution.draw(settings,rng:&equalRNG,elapsed:0,skill:1),17)

        settings.serialMin=18;settings.serialMax=17
        XCTAssertEqual(settings.customSerialRangeError,"Custom serial minimum must not exceed the maximum.")
        settings.serialMin=1;settings.serialMax=10_000
        XCTAssertEqual(settings.customSerialRangeError,"Custom serial maximum must be from 1 to 9999.")
    }

    func testCustomWpxEndpointDigitWidthsSurviveSettingsReloadAndLegacyFallback() throws {
        var settings=ContestSettings();settings.contest = .wpx;settings.serialRange = .custom
        settings.serialMin=1;settings.serialMax=99;settings.serialMinDigits=2;settings.serialMaxDigits=2
        let saved=try JSONEncoder().encode(settings)
        let reloaded=try JSONDecoder().decode(ContestSettings.self,from:saved)
        XCTAssertEqual(reloaded.serialMin,1)
        XCTAssertEqual(reloaded.serialMinDigitWidth,2,"01 retains its entered minimum width")
        XCTAssertEqual(reloaded.serialMaxDigitWidth,2)

        var legacy=try XCTUnwrap(JSONSerialization.jsonObject(with:saved) as? [String:Any])
        legacy.removeValue(forKey:"serialMinDigits");legacy.removeValue(forKey:"serialMaxDigits")
        let legacyData=try JSONSerialization.data(withJSONObject:legacy)
        let migrated=try JSONDecoder().decode(ContestSettings.self,from:legacyData)
        XCTAssertEqual(migrated.serialMinDigitWidth,1,"Old rows infer width from their integer endpoint")
        XCTAssertEqual(migrated.serialMaxDigitWidth,2)
    }

    func testPracticeExpiryAt90And120MinutesAndCompetitionUsesIndependentDuration() {
        for minutes in [90, 120] {
            var settings = ContestSettings()
            settings.mode = .pileup
            settings.duration = minutes
            settings.competitionDuration = 30
            let game = ContestSimulator(settings: settings)
            game.start()
            game.tick(Double(minutes * 60 - 1))
            XCTAssertTrue(game.snapshot.running, "\(minutes)-minute session is active immediately before expiry")
            XCTAssertEqual(game.snapshot.remaining, 1)
            game.tick(Double(minutes * 60))
            XCTAssertFalse(game.snapshot.running, "\(minutes)-minute session stops at expiry")
            XCTAssertEqual(game.snapshot.phase, .finished)
            XCTAssertEqual(game.snapshot.remaining, 0)

            settings.mode = .wpxCompetition
            let competition = ContestSimulator(settings: settings)
            XCTAssertEqual(competition.settings.duration, 30)
            competition.start()
            competition.tick(30 * 60)
            XCTAssertFalse(competition.snapshot.running)
        }
    }

    func testCallsignInformationCanFollowSelectedOlderLogCallAndKeepsHistoryScoped() throws {
        var settings = ContestSettings()
        settings.contest = .fieldday
        var older = HistoryRecord(call: "K1OLD")
        older.fdClass = "2A"
        older.section = "CT"
        older.userText = "older contact"
        var history = ImportedHistory()
        history.records = ["K1OLD": older]
        history.calls = ["K1OLD"]
        settings.contestHistories[ContestID.fieldday.rawValue] = history

        let selected = try XCTUnwrap(ContestRules.callsignInformationCall(
            typedCall: "K2TYPED", selectedLogCall: "k1old", activeCall: "K3ACTIVE", latestLogCall: "K4LATEST"))
        XCTAssertEqual(selected, "K1OLD")
        let info = try XCTUnwrap(ContestRules.callsignInformation(selected, settings: settings))
        XCTAssertEqual(info.call, "K1OLD")
        XCTAssertEqual(info.contestHistory, "older contact", "class and section are the exchange; MRCE shows user text only")

        settings.contest = .wpx
        let unrelatedContest = try XCTUnwrap(ContestRules.callsignInformation("K1OLD", settings: settings))
        XCTAssertNil(unrelatedContest.contestHistory, "Field Day history text is not shown in another contest")
    }

    // SettingsStore and GameView belong to the iOS app target and are not
    // built by the portable core test target. This is the explicit device/UI
    // acceptance gap for fresh default, saved-off reload, and older-row display.
    func testCallsignInformationPreferenceAndVisiblePanelRequireIOSAcceptance() throws {
        throw XCTSkip("On iOS verify fresh default on, saved off survives reload, then select an older QSO and inspect contest history text.")
    }

    // The focused field and pending hint are private FieldViewModel/UI state.
    // A core lookup test would mirror rather than exercise delivery, focus,
    // typing, and caller-switch cancellation.
    func testSweepstakesHintZeroFullTypedAndCallerSwitchRequireIOSAcceptance() throws {
        throw XCTSkip("On iOS verify 0% gives no prefill; 100% prefills only a focused empty field; typed text wins; stale caller hints are discarded.")
    }

    // The portable model tests above do not exercise settings-sheet controls,
    // UserDefaults, or FieldViewModel's entry/session lifecycle. Keep this
    // precise end-to-end acceptance sequence for the iOS simulator gate.
    func testSettingsEntryEditExitAndRelaunchRequireIOSAcceptance() throws {
        throw XCTSkip("On iOS save effects opposite the selected competition and 150 Hz practice BW; enter HST, edit unrelated WPM, verify locked effective controls; exit and relaunch to confirm original practice values restore.")
    }

    func testCustomWpxSerialRangeEntryAndReloadRequireIOSAcceptance() throws {
        throw XCTSkip("On iOS enter Custom WPX bounds 01 and 99, leave and reopen settings, then relaunch and confirm both visible widths remain two digits; verify reversed bounds show an error and Start Session presents validation.")
    }

}
