//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

/// MRCE `Main.pas` Edit2KeyPress / Edit3KeyPress, `ExchFields.pas` lengths,
/// and the `ProcessEnter` / `Advance` / `Edit*Enter` cursor rules.
final class EntryFieldFilterTests: XCTestCase {
    private func settings(_ contest: ContestID, call: String = "W7SST", mode: SessionMode = .pileup) -> ContestSettings {
        var s = ContestSettings(); s.contest = contest; s.myCall = call; s.mode = mode; return s
    }
    private func typed(_ text: String, _ field: QSOEntryField, _ s: ContestSettings) -> String {
        ContestRules.filterReceivedEntry(text, field: field, settings: s)
    }

    func testReportBoxTurnsCutLettersIntoDigits() {
        let s = settings(.wpx)
        XCTAssertEqual(typed("5nn", .exchangeFirst, s), "599")
        XCTAssertEqual(typed("ENN", .exchangeFirst, s), "599")
        XCTAssertEqual(typed("A", .exchangeFirst, s), "1")
        XCTAssertEqual(typed("5T9", .exchangeFirst, s), "59", "T is not a report key")
        XCTAssertEqual(typed("5999", .exchangeFirst, s), "599")
    }

    func testSerialBoxMapsANTAndStopsAtFourDigits() {
        let s = settings(.wpx)
        XCTAssertEqual(typed("TT1", .exchangeSecond, s), "001")
        XCTAssertEqual(typed("a2n", .exchangeSecond, s), "129")
        XCTAssertEqual(typed("1O5", .exchangeSecond, s), "15", "O is not a serial key")
        XCTAssertEqual(typed("12345", .exchangeSecond, s), "1234")
    }

    func testHSTCompetitionTakesDigitsOnly() {
        let s = settings(.hst, mode: .hstCompetition)
        XCTAssertEqual(typed("5NN", .exchangeFirst, s), "5")
        XCTAssertEqual(typed("TT1", .exchangeSecond, s), "1")
    }

    func testZoneBoxAlsoMapsO() {
        let s = settings(.cqww)
        XCTAssertEqual(typed("O5", .exchangeSecond, s), "05")
        XCTAssertEqual(typed("A4", .exchangeSecond, s), "14")
        XCTAssertEqual(typed("140", .exchangeSecond, s), "14")
    }

    func testARRLDXBoxFollowsTheOperatorsSide() {
        XCTAssertEqual(ContestRules.receivedFieldKind(.exchangeSecond, settings: settings(.arrldx, call: "W7SST")), .power)
        XCTAssertEqual(ContestRules.receivedFieldKind(.exchangeSecond, settings: settings(.arrldx, call: "DL1ABC")), .stateProv)
        XCTAssertEqual(typed("KW", .exchangeSecond, settings(.arrldx)), "KW")
        XCTAssertEqual(typed("5TT", .exchangeSecond, settings(.arrldx)), "5TT", "power keeps cut letters as typed")
        XCTAssertEqual(typed("1TTX", .exchangeSecond, settings(.arrldx)), "1TT")
        XCTAssertEqual(typed("MA1", .exchangeSecond, settings(.arrldx, call: "DL1ABC")), "MA")
    }

    func testNameClassSectionAndJapaneseBoxes() {
        XCTAssertEqual(typed("bob1", .exchangeFirst, settings(.cwt)), "BOB")
        XCTAssertEqual(typed("ALEXANDERTHEGREAT", .exchangeFirst, settings(.naqp)), "ALEXANDERT")
        XCTAssertEqual(typed("KP4/", .exchangeSecond, settings(.naqp)), "KP4/")
        XCTAssertEqual(typed("1234", .exchangeSecond, settings(.cwt)), "1234")
        XCTAssertEqual(typed("3a", .exchangeFirst, settings(.fieldday)), "3A")
        XCTAssertEqual(typed("3G", .exchangeFirst, settings(.fieldday)), "3")
        XCTAssertEqual(typed("DX", .exchangeFirst, settings(.fieldday)), "DX")
        XCTAssertEqual(typed("ENY1", .exchangeSecond, settings(.fieldday)), "ENY")
        XCTAssertEqual(typed("10H", .exchangeSecond, settings(.allja)), "10H")
        XCTAssertEqual(typed("10X", .exchangeSecond, settings(.allja)), "10")
        XCTAssertEqual(typed("100110H", .exchangeSecond, settings(.acag)), "100110H")
    }

    func testSweepstakesBoxKeepsSpaces() {
        let s = settings(.sweepstakes)
        XCTAssertEqual(typed("23 a k1abc 86 ct", .exchangeSecond, s), "23 A K1ABC 86 CT")
        XCTAssertEqual(typed("23-A", .exchangeSecond, s), "23A")
    }

    func testEnterMovesOnlyForACompleteCall() {
        XCTAssertEqual(ContestRules.entryFieldAfterEnter(from: .callsign, call: "K1ABC", contest: .wpx), .exchangeSecond)
        XCTAssertEqual(ContestRules.entryFieldAfterEnter(from: .callsign, call: "K1ABC", contest: .sweepstakes), .exchangeSecond)
        XCTAssertEqual(ContestRules.entryFieldAfterEnter(from: .callsign, call: "K1ABC", contest: .cwt), .exchangeFirst)
        XCTAssertEqual(ContestRules.entryFieldAfterEnter(from: .exchangeSecond, call: "K1ABC", contest: .cwt), .exchangeFirst)
        XCTAssertEqual(ContestRules.entryFieldAfterEnter(from: .callsign, call: "K1?", contest: .wpx), .callsign)
        XCTAssertEqual(ContestRules.entryFieldAfterEnter(from: .callsign, call: "K1A?C", contest: .wpx), .callsign)
        XCTAssertEqual(ContestRules.entryFieldAfterEnter(from: .callsign, call: "K12", contest: .wpx), .callsign)
        XCTAssertEqual(ContestRules.entryFieldAfterEnter(from: .callsign, call: "", contest: .wpx), .callsign)
    }

    func testSelectionOnFocus() {
        XCTAssertEqual(ContestRules.entrySelectionOnFocus(.callsign, text: "K1?BC", contest: .wpx), 2..<3)
        XCTAssertNil(ContestRules.entrySelectionOnFocus(.callsign, text: "K1ABC", contest: .wpx))
        XCTAssertEqual(ContestRules.entrySelectionOnFocus(.exchangeFirst, text: "599", contest: .wpx), 1..<2)
        XCTAssertNil(ContestRules.entrySelectionOnFocus(.exchangeFirst, text: "59", contest: .wpx))
        XCTAssertEqual(ContestRules.entrySelectionOnFocus(.exchangeFirst, text: "BOB", contest: .cwt), 0..<3)
        XCTAssertEqual(ContestRules.entrySelectionOnFocus(.exchangeSecond, text: "123", contest: .wpx), 0..<3)
        XCTAssertNil(ContestRules.entrySelectionOnFocus(.exchangeSecond, text: "", contest: .wpx))
    }
}

final class EntryFieldLimitTests: XCTestCase {
    func testAKeyTypedIntoAFullBoxIsRefused() {
        var s = ContestSettings(); s.contest = .wpx
        XCTAssertEqual(ContestRules.filterReceivedEntry("12534", previous: "1234", field: .exchangeSecond, settings: s), "1234")
        XCTAssertEqual(ContestRules.filterReceivedEntry("123", previous: "1234", field: .exchangeSecond, settings: s), "123")
        XCTAssertEqual(ContestRules.filterReceivedEntry("12345", previous: "", field: .exchangeSecond, settings: s), "1234", "a paste is cut to length")
        XCTAssertEqual(ContestRules.filterReceivedEntry("5799", previous: "599", field: .exchangeFirst, settings: s), "599")
    }

    func testSpeedSteps() {
        XCTAssertEqual(RadioTuning.steppedSpeed(25, up: true, mode: .pileup, range: 5...120), 27)
        XCTAssertEqual(RadioTuning.steppedSpeed(25, up: false, mode: .pileup, range: 5...120), 23)
        XCTAssertEqual(RadioTuning.steppedSpeed(27, up: true, mode: .hstCompetition, range: 5...120), 30)
        XCTAssertEqual(RadioTuning.steppedSpeed(27, up: false, mode: .hstCompetition, range: 5...120), 25)
        XCTAssertEqual(RadioTuning.steppedSpeed(30, up: false, mode: .hstCompetition, range: 5...120), 25)
        XCTAssertEqual(RadioTuning.steppedSpeed(119, up: true, mode: .pileup, range: 5...120), 120)
    }
}
