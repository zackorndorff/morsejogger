//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class ExchangeEntryTests:XCTestCase {
    func testContestExchangeEntrySchemasAreSpecific() {
        for contest in ContestID.allCases {
            let fields=contest.receivedExchangeFields
            if contest == .sweepstakes {
                XCTAssertNil(fields.first)
            } else {
                XCTAssertFalse(fields.first?.isEmpty ?? true,"\(contest) first exchange field")
            }
            XCTAssertFalse(fields.second.isEmpty,"\(contest) second exchange field")
            XCTAssertNotEqual(fields.first,fields.second,"\(contest) exchange fields should have distinct labels")
        }
        XCTAssertEqual(ContestID.fieldday.receivedExchangeFields.first,"Class")
        XCTAssertEqual(ContestID.fieldday.receivedExchangeFields.second,"Section")
        XCTAssertNil(ContestID.sweepstakes.receivedExchangeFields.first)
        XCTAssertEqual(ContestID.sweepstakes.receivedExchangeFields.second,"NR PREC CALL CK SEC")
        XCTAssertTrue(ContestID.sweepstakes.receivedExchangeFields.secondAllowsSpaces)
        XCTAssertFalse(ContestID.wpx.receivedExchangeFields.secondAllowsSpaces)
    }

    func testTwoExchangeControlsComposeAndSplitCanonicalContestData() {
        XCTAssertEqual(ContestRules.joinReceivedExchangeFields(first:"5NN",second:"TT1"),"5NN TT1")
        XCTAssertEqual(ContestRules.splitReceivedExchangeFields("599 001",contest:.wpx).first,"599")
        XCTAssertEqual(ContestRules.splitReceivedExchangeFields("599 001",contest:.wpx).second,"001")
        XCTAssertEqual(ContestRules.splitReceivedExchangeFields("023 A K1ABC 86 CT",contest:.sweepstakes).first,"")
        XCTAssertEqual(ContestRules.splitReceivedExchangeFields("023 A K1ABC 86 CT",contest:.sweepstakes).second,"023 A K1ABC 86 CT")
        XCTAssertEqual(
            ContestRules.joinReceivedExchangeFields(first:"023",second:"A K1ABC 86 CT"),
            "023 A K1ABC 86 CT"
        )

        var settings=ContestSettings()
        settings.contest = .wpx
        let wpx=ContestRules.joinReceivedExchangeFields(first:"599",second:"001")
        XCTAssertTrue(ContestRules.isExchangeStructurallyValid(settings,received:wpx,expected:"599 001"))
        settings.contest = .fieldday
        let fieldDay=ContestRules.joinReceivedExchangeFields(first:"3A",second:"ON")
        XCTAssertTrue(ContestRules.isExchangeStructurallyValid(settings,received:fieldDay,expected:"3A ON"))
        settings.contest = .sweepstakes
        let sweepstakes=ContestRules.joinReceivedExchangeFields(first:"023",second:"A K1ABC 86 CT")
        XCTAssertTrue(ContestRules.isExchangeStructurallyValid(settings,received:sweepstakes,expected:"023 A K1ABC 86 CT"))
    }

    func testSpaceAndTabEntryFieldNavigation() {
        XCTAssertEqual(ContestRules.nextEntryField(after:.callsign,contest:.wpx),.exchangeFirst)
        XCTAssertEqual(ContestRules.nextEntryField(after:.exchangeFirst,contest:.wpx),.exchangeSecond)
        XCTAssertEqual(ContestRules.nextEntryField(after:.exchangeSecond,contest:.wpx),.callsign)
        XCTAssertEqual(ContestRules.nextEntryField(after:.callsign,contest:.wpx,backwards:true),.exchangeSecond)
        XCTAssertEqual(ContestRules.nextEntryField(after:.exchangeSecond,contest:.wpx,backwards:true),.exchangeFirst)

        XCTAssertTrue(ContestRules.spaceAdvancesEntryField(contest:.wpx,field:.callsign))
        XCTAssertTrue(ContestRules.spaceAdvancesEntryField(contest:.wpx,field:.exchangeFirst))
        XCTAssertTrue(ContestRules.spaceAdvancesEntryField(contest:.wpx,field:.exchangeSecond))
        XCTAssertFalse(ContestRules.spaceAdvancesEntryField(contest:.sweepstakes,field:.exchangeSecond))
        XCTAssertEqual(ContestRules.nextSpaceEntryField(after:.callsign,contest:.wpx),.exchangeSecond)
        XCTAssertEqual(ContestRules.nextSpaceEntryField(after:.exchangeSecond,contest:.wpx),.callsign)
        XCTAssertEqual(ContestRules.nextSpaceEntryField(after:.callsign,contest:.fieldday),.exchangeFirst)
        XCTAssertEqual(ContestRules.nextSpaceEntryField(after:.callsign,contest:.sweepstakes),.exchangeSecond)
        XCTAssertNil(ContestRules.nextSpaceEntryField(after:.exchangeSecond,contest:.sweepstakes))
        XCTAssertEqual(ContestRules.nextEntryField(after:.callsign,contest:.sweepstakes),.exchangeSecond)
    }
}
