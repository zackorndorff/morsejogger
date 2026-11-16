//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

/// MRCE `TStation.NrAsText` for DX callers (5NN, ENN, cut numbers, LID serial
/// corrections), plus the Gaussian caller pitch from `TDxStation.CreateStation`.
final class CallerExchangeTextTests: XCTestCase {
    /// Decodes cut numbers and 5NN/ENN in exchange tokens so transcript tests that
    /// predate NrAsText can compare against canonical digits.
    /// The operator's keyed text (`K1ABC 5NNTT1`) in the log's form (`K1ABC 5NN 001`).
    static func ownCanonical(_ text: String) -> String {
        decodeCuts(text).replacingOccurrences(of: "599", with: "5NN")
    }
    static func decodeCuts(_ text: String) -> String {
        // WPX and HST key the report and serial as one word (`5NNTT1`).
        let words = text.split(separator: " ").flatMap { token -> [String] in
            let t = String(token)
            guard t.count > 3, ["5NN", "ENN", "599"].contains(String(t.prefix(3))),
                  t.dropFirst(3).allSatisfy({ "0123456789TNOA".contains($0) }) else { return [t] }
            return [String(t.prefix(3)), String(t.dropFirst(3))]
        }
        return words.map { t -> String in
            if t == "5NN" || t == "ENN" { return "599" }
            guard t.contains(where: { $0.isNumber }),
                  t.allSatisfy({ "0123456789TNOA".contains($0) }) else { return t }
            return String(t.map { c -> Character in
                switch c { case "T", "O": "0"; case "A": "1"; case "N": "9"; default: c }
            })
        }.joined(separator: " ")
    }

    private func simulator(_ contest: ContestID, mode: SessionMode = .pileup, lids: Bool = false,
                           seed: UInt32 = 1) -> ContestSimulator {
        var settings = ContestSettings()
        settings.contest = contest
        settings.mode = mode
        settings.seed = seed
        settings.effects.lids = lids
        let sim = ContestSimulator(settings: settings)
        XCTAssertTrue(sim.start())
        return sim
    }

    /// One keyed exchange, as the caller's "R <exchange>" reply.
    private func send(_ st: inout Station, contest: ContestID, mode: SessionMode = .pileup,
                      repeated: Bool = false) -> String {
        st.opState = .needEnd; st.patience = 5; st.ghosting = false
        let draw = repeated ? 0.95 : 0.5
        let reply = ContestSimulator.OperatorReplyPolicy.reply(
            &st, cause: .corrected, mode: mode, contest: contest, lids: false, nextRandom: { draw })
        XCTAssertTrue(reply.hasPrefix("R "))
        return String(reply.dropFirst(2))
    }

    func testCanonicalExchangeStaysDigitsWhileAirTextUses5NN() {
        let sim = simulator(.wpx)
        var sawENN = false, sawCut = false
        for _ in 0..<300 {
            var st = sim.fixtureMakeStation()
            let canonical = st.exchange
            XCTAssertTrue(canonical.hasPrefix("599 "), canonical)
            let air = send(&st, contest: .wpx)
            XCTAssertEqual(st.exchange, canonical, "canonical exchange must not change")
            XCTAssertFalse(air.contains("599"), air)
            XCTAssertTrue(air.hasPrefix("5NN") || air.hasPrefix("ENN"), air)
            XCTAssertFalse(air.contains(" "), "report and serial are one word: \(air)")
            XCTAssertEqual(Self.decodeCuts(air), canonical)
            sawENN = sawENN || air.hasPrefix("ENN")
            sawCut = sawCut || air.contains("T")
        }
        XCTAssertTrue(sawENN && sawCut)
    }

    func testWpxRuleFrequencies() {
        let sim = simulator(.wpx)
        var template = sim.fixtureMakeStation()
        let trials = 6000
        var enn = 0, tCut = 0, nCut = 0
        for _ in 0..<trials {
            template.exchange = "599 090"
            let air = send(&template, contest: .wpx)
            if air.hasPrefix("ENN") { enn += 1 }
            let serial = String(air.dropFirst(3))
            if serial == "TNT" { tCut += 1 }
            if serial.contains("N") { nCut += 1 }
        }
        XCTAssertEqual(Double(enn) / Double(trials), 0.05, accuracy: 0.015)
        // 0 -> T 98% + 2% * (60% * 97%); 9 -> N 97%.
        XCTAssertEqual(Double(nCut) / Double(trials), 0.97, accuracy: 0.015)
        XCTAssertEqual(Double(tCut) / Double(trials), 0.97 * (0.98 + 0.02 * 0.6 * 0.97), accuracy: 0.02)
        // Leading zero groups always cut.
        template.exchange = "599 001"
        XCTAssertTrue(send(&template, contest: .wpx).hasSuffix("NNTT1"))
        template.exchange = "599 000"
        _ = send(&template, contest: .wpx)
        template.exchange = "599 007"
        XCTAssertTrue(send(&template, contest: .wpx).hasSuffix("TT7"))
    }

    func testHSTSkipsENNAndCutNumbers() {
        let sim = simulator(.hst, mode: .hstCompetition)
        var st = sim.fixtureMakeStation()
        for _ in 0..<500 {
            st.exchange = "599 090"
            XCTAssertEqual(send(&st, contest: .hst, mode: .hstCompetition), "5NN090")
        }
    }

    func testCQZoneAndPowerUseStableR1Choice() {
        let cq = simulator(.cqww)
        var zone = cq.fixtureMakeStation()
        zone.exchange = "599 10"
        zone.stationDraw = 0.3
        for _ in 0..<200 {
            let air = send(&zone, contest: .cqww)
            XCTAssertTrue(air.hasSuffix(" AT"), air)
        }
        zone.stationDraw = 0.9
        for _ in 0..<200 {
            let air = send(&zone, contest: .cqww)
            XCTAssertTrue(air.hasSuffix(" 10"), "zones never use the 0/O draws: \(air)")
        }
        zone.exchange = "599 19"
        zone.stationDraw = 0.2
        XCTAssertTrue(send(&zone, contest: .cqww).hasSuffix(" AN"))

        let dx = simulator(.arrldx)
        var power = dx.fixtureMakeStation()
        power.country = "DL"
        power.exchange = "599 100"
        power.stationDraw = 0.1
        XCTAssertTrue(send(&power, contest: .arrldx).hasSuffix(" ATT"))
        power.stationDraw = 0.8
        XCTAssertTrue(send(&power, contest: .arrldx).hasSuffix(" 1TT"))
        // US/VE callers send a state: no cut numbers.
        power.country = "K"
        power.exchange = "599 NY"
        XCTAssertTrue(["5NN NY", "ENN NY"].contains(send(&power, contest: .arrldx)))
    }

    func testJapaneseContestRules() {
        let sim = simulator(.allja)
        var st = sim.fixtureMakeStation()
        let trials = 6000
        var o = 0, t = 0, plain = 0
        for _ in 0..<trials {
            st.exchange = "599 10H"
            let field = send(&st, contest: .allja).split(separator: " ").last.map(String.init) ?? ""
            switch field { case "1OH": o += 1; case "1TH": t += 1; case "10H": plain += 1
            default: XCTFail(field) }
        }
        XCTAssertEqual(Double(o) / Double(trials), 0.4, accuracy: 0.03)
        XCTAssertEqual(Double(t) / Double(trials), 0.6 * 0.8, accuracy: 0.03)
        XCTAssertEqual(Double(plain) / Double(trials), 0.6 * 0.2, accuracy: 0.03)
        st.exchange = "599 1002M"
        let acag = send(&st, contest: .acag)
        XCTAssertFalse(acag.contains("599"))
    }

    func testIARUAndNonRSTContestsDoNotCutDigits() {
        let sim = simulator(.iaru)
        var st = sim.fixtureMakeStation()
        st.exchange = "599 20"
        for _ in 0..<100 {
            XCTAssertTrue(["5NN 20", "ENN 20"].contains(send(&st, contest: .iaru)))
        }
        st.exchange = "ABC 100"
        XCTAssertEqual(send(&st, contest: .naqp), "ABC 100")
    }

    func testLidSerialErrorIsCorrectedOnceOnFirstSend() {
        let sim = simulator(.wpx, lids: true, seed: 77)
        var flagged = 0, corrected = 0, total = 0
        for _ in 0..<1500 {
            var st = sim.fixtureMakeStation()
            total += 1
            guard st.nrWithError else { continue }
            flagged += 1
            // Fresh WPX callers start at 001; pick serials that exercise each branch.
            st.exchange = "599 " + ["123", "150", "190", "001"][flagged % 4]
            let serial = String(st.exchange.split(separator: " ").last!)
            let first = send(&st, contest: .wpx)
            XCTAssertFalse(st.nrWithError, "flag is cleared by the first send")
            let second = send(&st, contest: .wpx)
            XCTAssertFalse(second.contains("EEEEE"), "repeats are correct: \(second)")
            XCTAssertEqual(Self.decodeCuts(second), st.exchange)
            let last = serial.last!, near = serial.count > 1 ? serial[serial.index(before: serial.index(before: serial.endIndex))] : last
            if ("2"..."7").contains(last) || ("2"..."7").contains(near) {
                corrected += 1
                let parts = first.components(separatedBy: "EEEEE")
                XCTAssertEqual(parts.count, 2, first)
                XCTAssertEqual(Self.decodeCuts(parts[1].trimmingCharacters(in: .whitespaces)), serial)
                let wrong = Self.decodeCuts(parts[0].trimmingCharacters(in: .whitespaces)).split(separator: " ").last.map(String.init) ?? ""
                XCTAssertNotEqual(wrong, serial)
                XCTAssertEqual(wrong.count, serial.count)
                let diffs = zip(wrong, serial).filter { $0 != $1 }
                XCTAssertEqual(diffs.count, 1)
                XCTAssertEqual(abs((diffs[0].0.wholeNumberValue ?? 0) - (diffs[0].1.wholeNumberValue ?? 0)), 1)
            } else {
                XCTAssertFalse(first.contains("EEEEE"))
            }
        }
        XCTAssertEqual(Double(flagged) / Double(total), 0.1, accuracy: 0.03)
        XCTAssertGreaterThan(corrected, 0)
        // Without LIDs no caller errs.
        let clean = simulator(.wpx, lids: false)
        for _ in 0..<200 { XCTAssertFalse(clean.fixtureMakeStation().nrWithError) }
    }

    func testLidReportIsTheCanonicalReport() {
        let sim = simulator(.wpx, lids: true, seed: 5)
        var odd = 0
        let trials = 3000
        for _ in 0..<trials {
            var st = sim.fixtureMakeStation()
            let rst = String(st.exchange.prefix(3))
            if rst != "599" {
                odd += 1
                XCTAssertTrue(["559", "569", "579", "589"].contains(rst), rst)
                let air = send(&st, contest: .wpx)
                let sentRST = String(air.prefix(3))
                XCTAssertTrue(sentRST == String(rst.dropLast()) + "N" || sentRST == rst, sentRST)
                var settings = ContestSettings(); settings.contest = .wpx
                XCTAssertTrue(ContestRules.checkExchange(settings, received: "\(rst) 001", expected: st.exchange).errors
                    .allSatisfy { $0 != DiagnosticText.rst })
                XCTAssertTrue(ContestRules.checkExchange(settings, received: "599 001", expected: st.exchange).errors
                    .contains(DiagnosticText.rst))
            }
        }
        XCTAssertEqual(Double(odd) / Double(trials), 0.03, accuracy: 0.015)
        let plain = simulator(.wpx, lids: false)
        for _ in 0..<300 { XCTAssertTrue(plain.fixtureMakeStation().exchange.hasPrefix("599 ")) }
    }

    /// The caller keys cut numbers, but the log is read the way MRCE reads it
    /// (`SaveEnteredExchToQso`, `CheckExch2`): digits, except where MRCE
    /// itself reduces cut letters (CQ zone, power, ARRL 10m serial).
    func testLoggedFieldsAreReadTheWayMRCEReadsThem() {
        func check(_ contest: ContestID, _ received: String, _ expected: String) -> Bool {
            var s = ContestSettings(); s.contest = contest
            return ContestRules.checkExchange(s, received: received, expected: expected).valid
        }
        XCTAssertTrue(check(.wpx, "599 001", "599 001"))
        XCTAssertTrue(check(.wpx, "599 1", "599 001"))
        XCTAssertTrue(check(.wpx, "001", "599 001"))
        XCTAssertFalse(check(.wpx, "599 TT1", "599 001"), "serial: StrToIntDef")
        XCTAssertFalse(check(.wpx, "599 T9T", "599 090"))
        XCTAssertFalse(check(.wpx, "5NN 001", "599 001"), "report: StrToIntDef")
        XCTAssertFalse(check(.wpx, "599 002", "599 001"))
        XCTAssertTrue(check(.cqww, "599 10", "599 10"))
        XCTAssertTrue(check(.cqww, "599 AT", "599 10"), "CQ zone: T, O, A, N reduced")
        XCTAssertTrue(check(.cqww, "599 1O", "599 10"))
        XCTAssertTrue(check(.cqww, "599 05", "599 5"))
        XCTAssertTrue(check(.arrldx, "599 ATT", "599 100"), "power: T, O, A, N reduced")
        XCTAssertTrue(check(.arrldx, "599 1OO", "599 100"))
        XCTAssertTrue(check(.arrldx, "599 KW", "599 KW"))
        XCTAssertTrue(check(.allja, "599 10H", "599 10H"))
        XCTAssertFalse(check(.allja, "599 1OH", "599 10H"), "JA prefecture: exact text")
        XCTAssertFalse(check(.allja, "599 1TH", "599 10H"))
        XCTAssertTrue(check(.acag, "599 1002M", "599 1002M"))
        XCTAssertFalse(check(.acag, "599 1TT2M", "599 1002M"), "JA city: exact text")
        XCTAssertTrue(check(.arrl10, "599 100", "599 100"))
        XCTAssertTrue(check(.arrl10, "599 ATT", "599 100"), "ARRL 10m serial: T, A, N reduced")
        XCTAssertFalse(check(.arrl10, "599 1OO", "599 100"), "but not O")
        XCTAssertTrue(check(.iaru, "599 8", "599 8"))
        XCTAssertFalse(check(.iaru, "599 08", "599 8"), "IARU zone: exact text")
        var ss = ContestSettings(); ss.contest = .sweepstakes
        XCTAssertTrue(ContestRules.checkExchange(ss, received: "12 A K1ABC 72 CT", expected: "12 A K1ABC 72 CT").valid)
        XCTAssertFalse(ContestRules.checkExchange(ss, received: "A2 A K1ABC 72 CT", expected: "12 A K1ABC 72 CT").valid)
    }

    func testPitchSpreadFollowsMRCEGaussianLimits() {
        for (mode, limit) in [(SessionMode.pileup, 300.0), (.single, 50.0)] {
            let sim = simulator(.wpx, mode: mode, seed: 9)
            let center = Double(ContestSettings().pitch)
            var offsets: [Double] = []
            for _ in 0..<3000 { offsets.append(Double(sim.fixtureMakeStation().tone) - center) }
            XCTAssertTrue(offsets.allSatisfy { abs($0) <= limit }, "mode \(mode) exceeded +/-\(limit)")
            let mean = offsets.reduce(0, +) / Double(offsets.count)
            let sd = (offsets.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(offsets.count)).squareRoot()
            XCTAssertEqual(mean, 0, accuracy: limit * 0.05)
            // Gaussian with sigma = limit/2, truncated at the limit (about 0.88 sigma kept).
            XCTAssertEqual(sd, limit * 0.5 * 0.88, accuracy: limit * 0.06)
            if mode == .pileup {
                XCTAssertGreaterThan(offsets.filter { abs($0) > 90 }.count, 1000, "wider than the old uniform +/-90")
            }
        }
    }
}
