//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

/// MRCE `TStation.NrAsText` for the operator's station (`MyCall = Ini.Call`).
final class OwnExchangeTextTests: XCTestCase {
    private func own(_ contest: ContestID, _ exchange: String, call: String = "W7SST",
                     mode: SessionMode = .pileup, r1: Double = 0.9) -> String {
        var s = ContestSettings(); s.contest = contest; s.myCall = call; s.mode = mode
        return CallerExchangeText.renderOwn(exchange, settings: s, r1: r1)
    }

    func testWPXRunsReportIntoSerialAndAlwaysCuts() {
        XCTAssertEqual(own(.wpx, "5NN 001"), "5NNTT1")
        XCTAssertEqual(own(.wpx, "599 019"), "5NNT1N")
        XCTAssertEqual(own(.wpx, "5NN 100"), "5NN1TT")
        XCTAssertEqual(own(.wpx, "5NN 1234"), "5NN1234")
    }

    func testHSTKeepsDigitsButStillRunsTogether() {
        XCTAssertEqual(own(.hst, "5NN 009", mode: .hstCompetition), "5NN009")
        XCTAssertEqual(own(.wpx, "5NN 009", mode: .hstCompetition), "5NN009")
    }

    func testZoneCutsOneAsWell() {
        XCTAssertEqual(own(.cqww, "5NN 3"), "5NN 3")
        XCTAssertEqual(own(.cqww, "5NN 14"), "5NN A4")
        XCTAssertEqual(own(.cqww, "5NN 10"), "5NN AT")
        XCTAssertEqual(own(.cqww, "5NN 9"), "5NN N")
    }

    func testPowerIsCutOnlyForADXOperatorAndOneFollowsR1() {
        XCTAssertEqual(own(.arrldx, "5NN MA"), "5NN MA")
        XCTAssertEqual(own(.arrldx, "5NN 100", call: "DL1ABC", r1: 0.9), "5NN 1TT")
        XCTAssertEqual(own(.arrldx, "5NN 100", call: "DL1ABC", r1: 0.2), "5NN ATT")
        XCTAssertEqual(own(.arrldx, "5NN KW", call: "DL1ABC"), "5NN KW")
    }

    func testTenMetreSerialIsCutForADXOperator() {
        XCTAssertEqual(own(.arrl10, "5NN OR"), "5NN OR")
        XCTAssertEqual(own(.arrl10, "5NN 109", call: "DL1ABC"), "5NN 1TN")
    }

    func testOtherContestsAreSentAsConfigured() {
        XCTAssertEqual(own(.iaru, "5NN 10"), "5NN 10")
        XCTAssertEqual(own(.allja, "5NN 10H"), "5NN 10H")
        XCTAssertEqual(own(.sweepstakes, "10 A W7SST 90 OR"), "10 A W7SST 90 OR")
        XCTAssertEqual(own(.cwt, "DAVID 190"), "DAVID  190")
    }

    func testLidCorrectionRepeatsTheSerialInThreeDigits() {
        var st = Station(call: "K1ABC", exchange: "599 12", wpm: 25, tone: 600, volume: 1, shift: 0)
        st.exchangeRNGState = 7; st.nrWithError = true
        let air = CallerExchangeText.render(&st, contest: .arrl10, mode: .pileup)
        XCTAssertTrue(air.contains("EEEEE "), air)
        XCTAssertEqual(CallerExchangeTextTests.decodeCuts(String(air.components(separatedBy: "EEEEE ").last ?? "")), "012")
    }
}

final class OwnStartingSerialTests: XCTestCase {
    /// `Main.SetMyExch2`: in the Mid and End ranges the operator starts at
    /// `1 + (random serial div 10) * 10`, so the first number always ends in 1.
    func testMidAndEndRangesStartOnANumberEndingInOne() {
        for range in [SerialRange.mid, .end] {
            var starts = Set<Int>()
            for seed in 1...60 {
                var s = ContestSettings(); s.contest = .wpx; s.serialRange = range; s.seed = UInt32(seed)
                let game = ContestSimulator(settings: s); game.start()
                XCTAssertEqual(game.snapshot.serial % 10, 1, "\(range) seed \(seed)")
                starts.insert(game.snapshot.serial)
            }
            XCTAssertGreaterThan(starts.count, 10)
        }
    }
}

final class SmallMRCEDifferenceTests: XCTestCase {
    func testCustomNilTextReplacesNILOnTheAir() {
        var s = ContestSettings(); s.mode = .single; s.seed = 5
        XCTAssertEqual(s.effectiveNilText, "NIL")
        s.nilText = " qrz? "
        let game = ContestSimulator(settings: s); game.start(); game.tick(1)
        _ = game.drainEvents()
        game.command(.nil)
        XCTAssertEqual(game.drainEvents().first { $0.kind == .transmit }?.text, "QRZ?")
    }

    /// MRCE Ctrl-U: every CQ brings at least one caller.
    func testContinuousPileupAlwaysAnswersACQ() {
        func emptyCQs(continuous: Bool) -> Int {
            var empty = 0
            for seed in 1...40 {
                var s = ContestSettings(); s.mode = .pileup; s.activity = 1; s.seed = UInt32(seed); s.continuousPileup = continuous
                let game = ContestSimulator(settings: s); game.start(); game.tick(1)
                game.command(.cq); game.tick(8)
                if game.pileup.isEmpty { empty += 1 }
            }
            return empty
        }
        XCTAssertEqual(emptyCQs(continuous: true), 0)
        XCTAssertGreaterThan(emptyCQs(continuous: false), 5)
    }
}
