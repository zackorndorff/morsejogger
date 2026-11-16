//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

/// Contest-specific on-air texts from MRCE `TContest.SendMsg` and its
/// overrides in `CWOPS.pas`, `CWSST.pas`, `ArrlFd.pas` and `ArrlSS.pas`.
final class ContestMessageTests: XCTestCase {
    private func station(_ state: OperatorState, exchange: String, style: Double = 0.5) -> Station {
        var st = Station(call: "K1ABC", exchange: exchange, wpm: 25, tone: 600, volume: 1, shift: 0)
        st.opState = state; st.patience = 5; st.replyStyle = style
        return st
    }
    /// A caller with a given `Station.R1` and a fixed, different `DxOper.R2`.
    private func asker(exchange: String, r1: Double) -> Station {
        var st = station(.needNr, exchange: exchange, style: 0.01)
        st.stationDraw = r1
        return st
    }
    private func reply(_ st: inout Station, contest: ContestID, draws: [Double], name: String = "ZACK") -> (String, Int) {
        var index = 0
        let text = ContestSimulator.OperatorReplyPolicy.reply(
            &st, cause: .timeout, mode: .pileup, contest: contest, lids: false, operatorName: name,
            nextRandom: { defer { index += 1 }; return index < draws.count ? draws[index] : 0.5 })
        return (text, index)
    }

    func testQRMStationsCallCQWithTheirOwnCallAndOnlyQSYNamesTheOperator() {
        func text(_ type: QRMMessageType, _ contest: ContestID = .wpx) -> String {
            QRMSourceModel.message(type, stationCall: "K1ABC", operatorCall: "VE3NEA", contest: contest)
        }
        XCTAssertEqual(text(.cq), "CQ CQ TEST K1ABC K1ABC TEST")
        XCTAssertEqual(text(.cq, .cwt), "CQ CQ CWT K1ABC K1ABC")
        XCTAssertEqual(text(.cq, .sst), "CQ CQ SST K1ABC K1ABC")
        XCTAssertEqual(text(.cq, .sweepstakes), "CQ CQ SS K1ABC K1ABC SS")
        XCTAssertEqual(text(.cq, .fieldday), "CQ CQ FD K1ABC K1ABC FD")
        XCTAssertEqual(text(.qsy), "VE3NEA  QSY QSY")
        XCTAssertEqual(text(.qrl), "QRL?")
        XCTAssertEqual(text(.repeatedQRL), "QRL?   QRL?")
    }

    func testLiveQRMNeverCallsCQWithTheOperatorsCall() {
        var settings = ContestSettings()
        settings.seed = 31; settings.mode = .pileup; settings.duration = 60; settings.effects.qrm = true
        let game = ContestSimulator(settings: settings)
        game.start()
        var cqs = 0, time = 0.0
        while time < 3_600 {
            time += 0.5; game.tick(time)
            for event in game.drainEvents() where event.kind == .interference {
                guard let voice = event.voices.first, voice.message.hasPrefix("CQ CQ") else { continue }
                cqs += 1
                XCTAssertEqual(voice.message, "CQ CQ TEST \(voice.call) \(voice.call) TEST")
                XCTAssertFalse(voice.message.contains(settings.myCall))
            }
        }
        XCTAssertGreaterThan(cqs, 0, "an hour of QRM should include at least one CQ")
    }

    func testFieldDayAndSSTRepeatRequestsFollowTheStationsStableDraw() {
        let policy = ContestSimulator.OperatorReplyPolicy.self
        let fd = [0.05: "NR?", 0.25: "NR?", 0.45: "SECT?", 0.65: "CLASS?", 0.85: "CL?"]
        for (r1, expected) in fd {
            XCTAssertEqual(policy.numberQuestion(asker(exchange: "2A CT", r1: r1), contest: .fieldday), expected)
        }
        let sst = [0.10: "NR?", 0.40: "NR?", 0.60: "NAME?", 0.90: "ST?"]
        for (r1, expected) in sst {
            XCTAssertEqual(policy.numberQuestion(asker(exchange: "BOB MA", r1: r1), contest: .sst), expected)
        }
        XCTAssertEqual(policy.numberQuestion(asker(exchange: "599 001", r1: 0.9), contest: .wpx), "NR?")
        // The reply path uses it: patience four forces the request.
        var asking = asker(exchange: "BOB MA", r1: 0.60)
        asking.patience = 4
        XCTAssertEqual(reply(&asking, contest: .sst, draws: []).0, "NAME?")
    }

    /// `Station.R1` words the repeat request and `DxOper.R2` picks the
    /// call-correction style. MRCE draws them separately, so every wording
    /// occurs with every correction style.
    func testRepeatRequestWordingIsIndependentOfCorrectionStyle() {
        var settings = ContestSettings()
        settings.contest = .fieldday; settings.mode = .pileup; settings.seed = 77
        let game = ContestSimulator(settings: settings)
        game.start()
        let policy = ContestSimulator.OperatorReplyPolicy.self
        var seen: [String: Set<Int>] = [:]
        var differing = 0
        for _ in 0..<3_000 {
            let st = game.fixtureMakeStation()
            if st.stationDraw != st.replyStyle { differing += 1 }
            seen[policy.numberQuestion(st, contest: .fieldday), default: []].insert(min(5, Int(st.replyStyle * 6)))
        }
        XCTAssertEqual(differing, 3_000)
        XCTAssertEqual(Set(seen.keys), ["NR?", "SECT?", "CLASS?", "CL?"])
        for (wording, styles) in seen {
            XCTAssertEqual(styles, [0, 1, 2, 3, 4, 5], "\(wording) must occur with every correction style")
        }
    }

    func testCWTUsuallyOmitsTheRBeforeTheExchange() {
        var plain = station(.needEnd, exchange: "BOB 1234")
        XCTAssertEqual(reply(&plain, contest: .cwt, draws: [0.5, 0.5]).0, "BOB 1234")
        var roger = station(.needEnd, exchange: "BOB 1234")
        XCTAssertEqual(reply(&roger, contest: .cwt, draws: [0.5, 0.95]).0, "R BOB 1234")
        var doubled = station(.needEnd, exchange: "BOB 1234")
        XCTAssertEqual(reply(&doubled, contest: .cwt, draws: [0.95, 0.5]).0, "BOB 1234 BOB 1234")
        var other = station(.needEnd, exchange: "599 001")
        XCTAssertEqual(reply(&other, contest: .wpx, draws: [0.5]).0, "R 599 001")
    }

    func testSSTExchangeCarriesAnOccasionalRAndAStableGreeting() {
        var st = station(.needEnd, exchange: "BOB MA")
        // single exchange, R (10%), greeting (20%), first of ten greeting slots
        XCTAssertEqual(reply(&st, contest: .sst, draws: [0.5, 0.05, 0.10, 0.0]).0, "R GM ZACK BOB MA")
        // The greeting was chosen once; a later draw cannot change it.
        let again = reply(&st, contest: .sst, draws: [0.5, 0.5, 0.10, 0.75])
        XCTAssertEqual(again.0, "GM ZACK BOB MA")
        XCTAssertEqual(again.1, 3, "a cached greeting consumes no further draw")
        XCTAssertEqual(reply(&st, contest: .sst, draws: [0.5, 0.5, 0.5]).0, "BOB MA")

        var afternoon = station(.needEnd, exchange: "BOB MA")
        XCTAssertEqual(reply(&afternoon, contest: .sst, draws: [0.5, 0.5, 0.1, 0.45]).0, "GA ZACK BOB MA")
        var evening = station(.needEnd, exchange: "BOB MA")
        XCTAssertEqual(reply(&evening, contest: .sst, draws: [0.5, 0.5, 0.1, 0.75]).0, "GE ZACK BOB MA")
        var silent = station(.needEnd, exchange: "BOB MA")
        XCTAssertEqual(reply(&silent, contest: .sst, draws: [0.5, 0.5, 0.1, 0.95]).0, "BOB MA")
    }

    private func transmitted(_ contest: ContestID, _ command: Command, call: String = "") -> [String] {
        var settings = ContestSettings(); settings.myCall = "VE3NEA"
        settings.contest = contest; settings.mode = .single; settings.seed = 7
        let game = ContestSimulator(settings: settings)
        game.start(); game.tick(0.5)
        game.command(command, call: call)
        return game.drainEvents().filter { $0.kind == .transmit }.map(\.text)
    }

    func testSSTAlwaysSignsItsTU() {
        XCTAssertEqual(transmitted(.sst, .tu), ["TU VE3NEA"])
        XCTAssertEqual(transmitted(.wpx, .tu), ["TU"], "single-call mode has no station ID elsewhere")
    }

    func testCWTExchangeIsKeyedWithAWiderGapBetweenNameAndNumber() {
        let own = try? XCTUnwrap(transmitted(.cwt, .exchange).first)
        let fields = (own ?? "").split(separator: " ", omittingEmptySubsequences: true)
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(own, fields.joined(separator: "  "))
        let single = MorseTimeline.duration(fields.joined(separator: " "), wpm: 25)
        let unit = MorseTimeline.marks("E", wpm: 25)[0].duration
        XCTAssertEqual(MorseTimeline.duration(own ?? "", wpm: 25), single + 2 * unit, accuracy: 1e-9)

        var caller = station(.needEnd, exchange: "BOB 1234")
        caller.exchangeRNGState = 99
        XCTAssertEqual(CallerExchangeText.render(&caller, contest: .cwt, mode: .pileup), "BOB  1234")
        XCTAssertEqual(caller.exchange, "BOB 1234", "the canonical exchange used for scoring is unchanged")
    }
}

final class OwnFarnsworthSendingTests: XCTestCase {
    /// MRCE `TMyStation.SetWpm`: in SST the operator's characters use the
    /// Farnsworth character rate when it is above the sending speed.
    func testSSTOperatorTransmissionsUseTheFarnsworthCharacterRate() {
        func cqEvent(_ contest: ContestID, wpm: Int) -> RadioEvent? {
            var settings = ContestSettings()
            settings.contest = contest; settings.mode = .pileup; settings.seed = 7
            settings.wpm = wpm; settings.farnsworthCharRate = 25
            let game = ContestSimulator(settings: settings)
            game.start(); game.tick(0.5); game.command(.cq)
            return game.drainEvents().first { $0.kind == .transmit }
        }
        XCTAssertEqual(cqEvent(.sst, wpm: 15)?.characterWpm, 25)
        XCTAssertNil(cqEvent(.sst, wpm: 30)?.characterWpm, "at or above the character rate there is nothing to stretch")
        XCTAssertNil(cqEvent(.wpx, wpm: 15)?.characterWpm, "only the Farnsworth contest stretches spacing")
        // Characters at 25 WPM, spaced so a word still takes 60/15 seconds.
        let marks = MorseTimeline.marks("CQ SST VE3NEA", wpm: 15, characterWpm: 25, sampleRate: 11_025)
        XCTAssertEqual(marks[0].duration * 11_025, 3 * 551, accuracy: 0.5)
    }
}

final class CallerExchangeGenerationTests: XCTestCase {
    private func callers(_ contest: ContestID, count: Int, seed: UInt32 = 11, myCall: String = "VE3NEA") -> [Station] {
        var settings = ContestSettings()
        settings.contest = contest; settings.mode = .pileup; settings.seed = seed; settings.myCall = myCall
        let game = ContestSimulator(settings: settings)
        game.start()
        return (0..<count).map { _ in game.fixtureMakeStation() }
    }

    /// `DxStn.CreateStation` and `DxOper.SetState`: the only double call is
    /// `RepeatCnt`, one pile-up caller in ten. LIDs change the report, the
    /// serial and how calls are matched, not how a caller signs.
    func testLidsDoNotMakeCallersSignMoreOften() {
        func signTwice(lids: Bool, mode: SessionMode) -> (twice: Double, more: Int) {
            var settings = ContestSettings()
            settings.contest = .wpx; settings.mode = mode; settings.seed = 31; settings.effects.lids = lids
            let game = ContestSimulator(settings: settings)
            game.start()
            let stations = (0..<4_000).map { _ in game.fixtureMakeStation() }
            let counts = stations.map { $0.sentCall.split(separator: " ").count }
            return (Double(counts.filter { $0 == 2 }.count) / 4_000, counts.filter { $0 > 2 }.count)
        }
        for lids in [false, true] {
            let pileup = signTwice(lids: lids, mode: .pileup)
            XCTAssertEqual(pileup.twice, 0.10, accuracy: 0.02, "lids \(lids)")
            XCTAssertEqual(pileup.more, 0, "lids \(lids)")
            let single = signTwice(lids: lids, mode: .single)
            XCTAssertEqual(single.twice, 0, "lids \(lids)")
        }
    }

    /// `ArrlSS.pas` draws a precedence for every caller: 43% A, 19% B, 28% U,
    /// 10% Q/M/S. Without it every caller would send the same precedence.
    func testSweepstakesCallersDrawTheirPrecedence() {
        let stations = callers(.sweepstakes, count: 4_000)
        var counts: [String: Int] = [:]
        for st in stations {
            counts[st.precedence, default: 0] += 1
            XCTAssertEqual(st.exchange.split(separator: " ")[1], Substring(st.precedence))
        }
        let total = Double(stations.count)
        XCTAssertEqual(Double(counts["A", default: 0]) / total, 0.43, accuracy: 0.03)
        XCTAssertEqual(Double(counts["B", default: 0]) / total, 0.19, accuracy: 0.03)
        XCTAssertEqual(Double(counts["U", default: 0]) / total, 0.28, accuracy: 0.03)
        let rest = ["Q", "M", "S"].map { Double(counts[$0, default: 0]) / total }
        XCTAssertEqual(rest.reduce(0, +), 0.10, accuracy: 0.02)
        for share in rest { XCTAssertEqual(share, 0.10 / 3, accuracy: 0.015) }
    }

    /// Outside WPX and HST, MRCE's default serial range is
    /// `1 + Random(175)` from the first caller on, not a number that starts
    /// near 1 and creeps up with the session clock.
    func testSweepstakesSerialsSpanTheDefaultRangeFromTheStart() {
        let serials = callers(.sweepstakes, count: 3_000).map(\.serial)
        XCTAssertEqual(serials.min(), 1)
        XCTAssertEqual(serials.max(), 175)
        XCTAssertEqual(Double(serials.reduce(0, +)) / Double(serials.count), 88, accuracy: 4)
        XCTAssertGreaterThan(serials.filter { $0 > 100 }.count, 1_000)
    }

    /// WPX keeps `DxOper.GetNR`: `1 + Round(Random * minutes * skill)`.
    func testWPXStartSerialsStillGrowWithElapsedTime() {
        XCTAssertTrue(callers(.wpx, count: 200).allSatisfy { $0.serial == 1 }, "no time has elapsed")
    }
}

final class CallsignValidityTests: XCTestCase {
    /// `CallsignUtils.IsValidCall` in the pinned source: an unanchored match of
    /// `(([0-9][A-Z])|([A-Z]{1,2}))[0-9][A-Z0-9]*[A-Z]`.
    func testValidCallFollowsThePinnedRegularExpression() {
        for call in ["K1A", "W1AW", "VE3NEA", "9A1A", "4X6TT", "DL1ABC/P", "W1AW/3", "KH6/W1AW", "K12A", "3DA0RU"] {
            XCTAssertTrue(ContestSimulator.isValidCall(call), call)
        }
        for call in ["", "K1", "K12", "ABC", "123", "ABC1", "1AB", "W1/", "ZZZZ", "A"] {
            XCTAssertFalse(ContestSimulator.isValidCall(call), call)
        }
    }

    /// `ProcessEnter` only keys the exchange after a complete, valid call.
    func testEnterSendsOnlyTheCallUntilItIsAValidCallsign() {
        func enter(_ call: String) -> [String] {
            var settings = ContestSettings()
            settings.contest = .wpx; settings.mode = .pileup; settings.seed = 3
            let game = ContestSimulator(settings: settings)
            game.start(); game.tick(0.5)
            game.command(.esm, call: call)
            return game.drainEvents().filter { $0.kind == .transmit }.map(\.text)
        }
        XCTAssertEqual(enter("K12"), ["K12"], "digit with no letter after it is not yet a callsign")
        XCTAssertEqual(enter("K1A"), ["K1A", "5NNTT1"])
    }
}

final class ContestKeyerSelectionTests: XCTestCase {
    /// MRCE builds its Farnsworth keyer for SST and uses it for every station
    /// there, so the choice follows the contest and not the character rate.
    func testSSTVoicesAlwaysUseTheFarnsworthKeyer() {
        func voices(_ contest: ContestID) -> [RadioVoice] {
            var settings = ContestSettings()
            settings.contest = contest; settings.mode = .single; settings.seed = 21
            settings.wpm = 35; settings.duration = 60; settings.effects.qrm = true
            let game = ContestSimulator(settings: settings)
            game.start()
            var found: [RadioVoice] = [], time = 0.0
            while time < 1_800 {
                time += 0.5; game.tick(time)
                for event in game.drainEvents() where event.kind == .receive || event.kind == .interference {
                    found += event.voices
                }
            }
            return found
        }
        let sst = voices(.sst)
        XCTAssertFalse(sst.isEmpty)
        XCTAssertTrue(sst.allSatisfy { $0.farnsworthKeyer == true })
        XCTAssertTrue(voices(.wpx).allSatisfy { $0.farnsworthKeyer == nil })
        // Above the character rate the two keyers differ only in how an extra space is keyed.
        let text = "VE3NEA  QSY QSY"
        let unit = MorseTimeline.marks("E", wpm: 35)[0].duration
        XCTAssertEqual(MorseTimeline.duration(text, wpm: 35, characterWpm: 35, farnsworthKeyer: true),
                       MorseTimeline.duration(text, wpm: 35) + 3 * unit, accuracy: 1e-9)
    }
}

/// `Log.ShowRate`: the rate shown is contacts in the last five minutes, per
/// hour, not the average since the session began.
final class RateDisplayTests: XCTestCase {
    func testRateCoversTheLastFiveMinutesOnly() {
        var settings = ContestSettings()
        settings.contest = .wpx; settings.mode = .single; settings.seed = 9; settings.duration = 30
        let game = ContestSimulator(settings: settings)
        game.start()
        var now = 0.0
        func run(to time: Double) { while now < time - 1e-9 { now = min(time, now + 0.08); game.tick(now); _ = game.drainEvents() } }
        run(to: 30); XCTAssertNotNil(game.logQSO(call: "ZZ9ZZZ", exchange: "599 001"))
        run(to: 50); XCTAssertNotNil(game.logQSO(call: "ZZ8ZZZ", exchange: "599 002"))
        run(to: 60)
        XCTAssertEqual(game.snapshot.rate, 120, "two contacts in the first minute")
        run(to: 600)
        XCTAssertEqual(game.snapshot.contacts, 2)
        XCTAssertEqual(game.snapshot.rate, 0, "nothing in the last five minutes")
        XCTAssertNotNil(game.logQSO(call: "ZZ7ZZZ", exchange: "599 003"))
        run(to: 610)
        XCTAssertEqual(game.snapshot.rate, 12, "one contact in five minutes")
    }
}
