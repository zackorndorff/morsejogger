//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class CodeReviewRegressionTests: XCTestCase {
    func testDeferredTUReconciliationPreservesSavedContactTimestampAndSentExchange() throws {
        var settings=ContestSettings();settings.mode = .single;settings.seed=1234
        let game=ContestSimulator(settings:settings)
        game.start()
        game.tick(6.0 * 512.0 / 11025.0)
        let caller=try XCTUnwrap(game.pileup.first)
        game.tick(30)
        game.command(.saveOnly,call:caller.call,exchange:"599 001")
        let saved=try XCTUnwrap(game.log.first)
        let savedAt=saved.at,savedSent=saved.sent,savedCall=saved.call
        XCTAssertEqual(savedAt,30)
        XCTAssertEqual(savedSent,"5NN 001")

        game.command(.tu)
        game.tick(50)

        let reconciled=try XCTUnwrap(game.log.first)
        XCTAssertEqual(reconciled.id,saved.id)
        XCTAssertEqual(reconciled.at,savedAt)
        XCTAssertEqual(reconciled.sent,savedSent)
        XCTAssertEqual(reconciled.call,savedCall)
        XCTAssertEqual(reconciled.status,.completed)
    }

    func testIARUScoringUsesResolvedContestLocalExchangeProfile() {
        var settings=ContestSettings();settings.contest = .iaru
        var profile=settings.exchangeProfile(for:.iaru)
        profile.ituZone=28;profile.ituZoneText="28";profile.iaruExchangeMode = .zone
        settings.setExchangeProfile(profile,for:.iaru)
        let caller=Station(call:"K1ABC",exchange:"599 28",wpm:25,tone:450,volume:0.5,shift:0)

        XCTAssertEqual(ContestRules.sentExchange(settings,ownSerial:1),"5NN 28")
        XCTAssertEqual(ContestRules.score(settings,station:caller).points,1,
                       "The profile zone transmitted by the operator should score as a same-zone contact")
        profile.ituZone=29;profile.ituZoneText="29";settings.setExchangeProfile(profile,for:.iaru)
        XCTAssertEqual(ContestRules.score(settings,station:caller).points,3,
                       "A different configured zone should use the same-continent IARU score")
    }

    func testSimulatorRejectsRestartAfterStopAndKeepsItsSessionState() throws {
        var settings=ContestSettings();settings.mode = .single;settings.seed=77
        let game=ContestSimulator(settings:settings)
        XCTAssertTrue(game.start())
        game.tick(0.5)
        game.stopSession()
        let stopped=game.snapshot
        XCTAssertFalse(game.start())
        XCTAssertEqual(game.snapshot.phase,stopped.phase)
        XCTAssertEqual(game.snapshot.elapsed,stopped.elapsed)
        XCTAssertEqual(game.snapshot.serial,stopped.serial)
    }

    func testTypedValidationNoticesHaveSafeDisplayText() {
        let event=RadioEvent(.notice,"Exchange is incomplete or invalid. Correct it before logging.",noticeCode:.exchangeInvalid)
        XCTAssertEqual(RadioActivityText.visible(event),RadioNoticeCode.exchangeInvalid.safeDisplayText)
        XCTAssertEqual(RadioActivityText.visible(RadioEvent(.notice,"Enter a valid callsign before saving.",noticeCode:.callInvalid)),
                       "Enter a valid callsign before saving.")
    }
}
