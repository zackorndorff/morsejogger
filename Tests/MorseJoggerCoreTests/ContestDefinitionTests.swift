//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class ContestDefinitionTests: XCTestCase {
    func testEntryBehaviorForEveryContest() {
        let reportContests: Set<ContestID> = [.wpx,.hst,.cqww,.arrldx,.arrl10,.iaru,.allja,.acag,.pota]
        for contest in ContestID.allCases {
            XCTAssertEqual(contest.definition.usesRST, reportContests.contains(contest))
            XCTAssertFalse(contest.label.isEmpty)
            let target: QSOEntryField = reportContests.contains(contest) || contest == .sweepstakes ? .exchangeSecond : .exchangeFirst
            XCTAssertEqual(ContestRules.nextSpaceEntryField(after: .callsign, contest: contest), target)
        }
    }
    func testSharedConfigurationValidation() {
        var settings = ContestSettings()
        settings.mode = .hstCompetition
        XCTAssertNotNil(settings.configurationError)
        settings.contest = .hst
        XCTAssertNil(settings.configurationError)
        settings.mode = .single
        settings.contest = .wpx
        var profile = settings.exchangeProfile()
        settings.contest = .sweepstakes
        profile = settings.exchangeProfile()
        profile.check = ""
        settings.setExchangeProfile(profile)
        XCTAssertNotNil(settings.configurationError)
    }

    func testCQAndITUZoneBoundariesAndInactiveDrafts() {
        var settings=ContestSettings();settings.contest = .cqww
        var profile=settings.exchangeProfile();profile.zoneText="1";settings.setExchangeProfile(profile)
        XCTAssertNil(settings.configurationError)
        profile.zoneText="40";settings.setExchangeProfile(profile)
        XCTAssertNil(settings.configurationError)
        profile.zoneText="0";settings.setExchangeProfile(profile)
        XCTAssertEqual(settings.sentExchangeConfigurationError,"CQ zone must be between 1 and 40.")
        profile.zoneText="41";settings.setExchangeProfile(profile)
        XCTAssertEqual(settings.sentExchangeConfigurationError,"CQ zone must be between 1 and 40.")

        settings.contest = .iaru
        profile=settings.exchangeProfile();profile.iaruExchangeMode = .zone;profile.ituZoneText="1"
        settings.setExchangeProfile(profile)
        XCTAssertNil(settings.configurationError)
        profile.ituZoneText="90";settings.setExchangeProfile(profile)
        XCTAssertNil(settings.configurationError)
        profile.ituZoneText="0";settings.setExchangeProfile(profile)
        XCTAssertEqual(settings.sentExchangeConfigurationError,"ITU zone must be between 1 and 90.")
        profile.ituZoneText="91";settings.setExchangeProfile(profile)
        XCTAssertEqual(settings.sentExchangeConfigurationError,"ITU zone must be between 1 and 90.")

        settings.contest = .wpx
        XCTAssertNil(settings.configurationError,"Zone values are inactive in a contest that does not send them")
    }

    func testRadioChoiceTiesMatchCoreEffectiveSettings() {
        var settings = ContestSettings()
        settings.pitch = 325
        settings.bandwidth = 125
        XCTAssertEqual(settings.effective().pitch, 300)
        XCTAssertEqual(settings.effective().bandwidth, 100)
        XCTAssertEqual(ContestSettings.nearestChoice(325, choices: [300,350]), 300)
    }
}
