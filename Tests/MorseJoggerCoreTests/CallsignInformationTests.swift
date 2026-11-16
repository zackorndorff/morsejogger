//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class CallsignInformationTests: XCTestCase {
    // MRCE shows callsign information unless switched off; showing the
    // correct answers is this app's own aid and is off.
    func testAssistancePreferencesDefaultsAndPersistIndependently() throws {
        var settings=ContestSettings()
        XCTAssertTrue(settings.showCallsignInfo)
        XCTAssertFalse(settings.showCorrectAnswers)
        settings.showCallsignInfo=false
        let restored=try JSONDecoder().decode(ContestSettings.self,from:JSONEncoder().encode(settings))
        XCTAssertFalse(restored.showCallsignInfo)
        XCTAssertFalse(restored.showCorrectAnswers)

        settings.showCallsignInfo=true
        settings.showCorrectAnswers=true
        let both=try JSONDecoder().decode(ContestSettings.self,from:JSONEncoder().encode(settings))
        XCTAssertTrue(both.showCallsignInfo)
        XCTAssertTrue(both.showCorrectAnswers)
    }

    func testTypedCallShowsKnownGeographyAndOmitsUnknownGeography() {
        let known=ContestRules.callsignInformation("k1abc",settings:ContestSettings())
        XCTAssertEqual(known?.call,"K1ABC")
        XCTAssertEqual(known?.geography,"NA/K")

        let unknown=ContestRules.callsignInformation("ZQ9XYZ",settings:ContestSettings())
        XCTAssertEqual(unknown?.call,"ZQ9XYZ")
        XCTAssertNil(unknown?.geography)
        XCTAssertNil(unknown?.contestHistory)
    }

    func testOlderSelectedLogCallOverridesTypedCallAndEmptyEntryFallsBackToActiveCaller() {
        XCTAssertEqual(ContestRules.callsignInformationCall(typedCall:"K2NEW",selectedLogCall:"K1OLD",activeCall:"K3DX",latestLogCall:"K4LAST"),"K1OLD")
        XCTAssertEqual(ContestRules.callsignInformationCall(typedCall:"",selectedLogCall:nil,activeCall:"K3DX",latestLogCall:"K4LAST"),"K3DX")
        XCTAssertEqual(ContestRules.callsignInformationCall(typedCall:"ZQ9XYZ",selectedLogCall:nil,activeCall:nil,latestLogCall:nil),"ZQ9XYZ")
    }

    private func settings(_ contest:ContestID,_ record:HistoryRecord) -> ContestSettings {
        var settings=ContestSettings();settings.contest=contest
        var history=ImportedHistory();history.calls=[record.call];history.records[record.call]=record
        settings.contestHistories[contest.rawValue]=history
        return settings
    }

    // ArrlFd.GetStationInfo: user text; entity only for a DX station.
    func testFieldDayShowsUserTextButNeverClassOrSection() {
        var record=HistoryRecord(call:"K1ABC");record.fdClass="4A";record.section="CT";record.userText="NORTH CLUB"
        let info=ContestRules.callsignInformation("K1ABC",settings:settings(.fieldday,record))
        XCTAssertNil(info?.geography)
        XCTAssertEqual(info?.contestHistory,"NORTH CLUB")
        XCTAssertEqual(info?.displayText,"NORTH CLUB")

        var dx=HistoryRecord(call:"DL1ABC");dx.fdClass="1D";dx.section="DX"
        XCTAssertEqual(ContestRules.callsignInformation("DL1ABC",settings:settings(.fieldday,dx))?.displayText,"EU/DL")
    }

    // ArrlSS.GetStationInfo: user text only.
    func testSweepstakesShowsUserTextButNeverCheckOrSection() {
        var record=HistoryRecord(call:"K1ABC");record.check="86";record.section="CT";record.userText="LOCAL RADIO CLUB"
        let info=ContestRules.callsignInformation("K1ABC",settings:settings(.sweepstakes,record))
        XCTAssertEqual(info?.displayText,"LOCAL RADIO CLUB")
    }

    func testNoContestShowsZones() {
        for contest in ContestID.allCases {
            var settings=ContestSettings();settings.contest=contest
            let text=ContestRules.callsignInformation("DL1ABC",settings:settings)?.displayText ?? ""
            XCTAssertFalse(text.contains("CQ") || text.contains("ITU"),"\(contest)")
        }
    }

    // CWOPS.GetStationInfo: a non-member's user text would hint at the state.
    func testCWTHidesUserTextOfNorthAmericanNonMembers() {
        var member=HistoryRecord(call:"K1ABC");member.cwops="1234";member.userText="MA CLUB"
        XCTAssertEqual(ContestRules.callsignInformation("K1ABC",settings:settings(.cwt,member))?.displayText,"MA CLUB")
        var guest=HistoryRecord(call:"K1ABC");guest.cwops="MA";guest.userText="MA CLUB"
        XCTAssertEqual(ContestRules.callsignInformation("K1ABC",settings:settings(.cwt,guest))?.displayText,"NA/K")
    }

    // NaQp.GetStationInfo: entity only when the station sends no state.
    func testNAQPShowsEntityOnlyWithoutAState() {
        var home=HistoryRecord(call:"K1ABC");home.state="MA"
        XCTAssertEqual(ContestRules.callsignInformation("K1ABC",settings:settings(.naqp,home))?.displayText,"")
        let dx=HistoryRecord(call:"DL1ABC")
        XCTAssertEqual(ContestRules.callsignInformation("DL1ABC",settings:settings(.naqp,dx))?.displayText,"EU/DL")
    }

    func testHistoryWithoutUsableFieldsDoesNotInventContestMetadata() {
        var settings=ContestSettings();settings.contest = .fieldday
        var history=ImportedHistory();history.calls=["K1ABC"]
        history.records["K1ABC"]=HistoryRecord(call:"K1ABC")
        settings.contestHistories[settings.contest.rawValue]=history

        XCTAssertNil(ContestRules.callsignInformation("K1ABC",settings:settings)?.contestHistory)
    }

    // US calls begin K, N, W or AA-AK. Alaska, Hawaii and the US Caribbean
    // have their own prefixes under all four letters and are separate
    // entities, so in ARRL DX they send power, not a state.
    func testUnitedStatesPrefixesAndItsSeparateEntities() {
        for call in ["K1ABC","N1MM","W1AW","AA1A","AK4Z","KA1ABC","WB2XYZ","NN1N"] {
            XCTAssertTrue(ContestRules.callMeta(call).usve,call)
        }
        for call in ["VE3NEA","VA7XX","VO1AA","VY2TT","VB3A","VG7X","VX9A","XM3A","XO1X","CF3A","CK7B","CZ2A"] {
            XCTAssertTrue(ContestRules.callMeta(call).usve,call)
        }
        for (call,entity) in [("KH6XX","KH6"),("AH6XX","KH6"),("NH7A","KH6"),("WH6R","KH6"),
                              ("KL7AA","KL7"),("AL7X","KL7"),("NL7Y","KL7"),("WL7Z","KL7"),
                              ("KP4AA","KP4"),("NP4A","KP4"),("WP4X","KP4"),("KP2M","KP2"),("NP2P","KP2"),("WP2B","KP2")] {
            let meta=ContestRules.callMeta(call)
            XCTAssertEqual(meta.country,entity,call)
            XCTAssertFalse(meta.usve,call)
        }
        XCTAssertFalse(ContestRules.callMeta("AM1A").usve,"AM-AO is Spain")
    }
}
