//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class ContestExchangeAuditTests: XCTestCase {
    private func settings(_ contest: ContestID, call: String = "VE3NEA") -> ContestSettings {
        var result = ContestSettings()
        result.contest = contest
        result.myCall = call
        result.mode = .single
        result.seed = 42
        result.effects = .all(false)
        return result
    }

    private func caller(_ contest: ContestID, _ record: HistoryRecord, home: String = "VE3NEA") throws -> (ContestSettings, Station) {
        var s = settings(contest, call: home)
        s.customCalls = [record.call]
        s.customRecords[record.call] = record
        let game = ContestSimulator(settings: s)
        game.start()
        game.tick(6.0 * 512.0 / 11025.0)
        let station = try XCTUnwrap(game.pileup.first)
        XCTAssertEqual(station.call, record.call)
        XCTAssertTrue(ContestRules.isExchangeStructurallyValid(s, received: station.exchange, expected: station.exchange), contest.rawValue)
        XCTAssertTrue(ContestRules.checkExchange(s, received: station.exchange, expected: station.exchange, callerCall: station.call).valid, contest.rawValue)
        return (s, station)
    }

    func testEveryContestGeneratedExchangeCanBeCopiedAndLogged() throws {
        for contest in ContestID.allCases {
            let call = [.allja,.acag].contains(contest) ? "JA1ABC" : contest == .arrldx ? "DL1ABC" : "K1ABC"
            var s = settings(contest)
            s.customCalls = [call]
            let game = ContestSimulator(settings: s)
            game.start()
            game.tick(6.0 * 512.0 / 11025.0)
            let st = try XCTUnwrap(game.pileup.first, contest.rawValue)
            let split = ContestRules.splitReceivedExchangeFields(st.exchange, contest: contest)
            let joined = ContestRules.joinReceivedExchangeFields(first: split.first, second: split.second)
            XCTAssertEqual(joined, st.exchange, contest.rawValue)
            XCTAssertTrue(ContestRules.isExchangeStructurallyValid(s, received: joined, expected: st.exchange), contest.rawValue)
            XCTAssertTrue(ContestRules.checkExchange(s, received: joined, expected: st.exchange, callerCall: st.call).valid, contest.rawValue)
            game.command(.saveOnly, call: st.call, exchange: joined)
            let row = try XCTUnwrap(game.log.first, contest.rawValue)
            XCTAssertTrue(row.exchangeErrors.isEmpty, contest.rawValue)
            XCTAssertEqual(row.expected, st.exchange, contest.rawValue)
            XCTAssertEqual(row.sent, ContestRules.sentExchange(s, ownSerial: 1), contest.rawValue)
            XCTAssertFalse(ContestRules.checkExchange(s, received: "WRONG", expected: st.exchange).valid, contest.rawValue)
        }
    }

    func testHistoryFieldsSurviveImportAndCallerGeneration() throws {
        let cases: [(ContestID, String, String, String)] = [
            (.cwt, "!!Order!!,Call,Name,Exch1\nK1ABC,JO,MA", "K1ABC", "JO MA"),
            (.arrldx, "!!Order!!,Call,Exch1\nDL1ABC,KW", "DL1ABC", "599 KW"),
            (.fieldday, "!!Order!!,Call,Exch1,Exch2\nK1ABC,1D,CT", "K1ABC", "1D CT"),
            (.allja, "!!Order!!,Call,Exch1\nJA1ABC,13L", "JA1ABC", "599 13L"),
            (.acag, "!!Order!!,Call,Exch1\nJA1ABC,010101P", "JA1ABC", "599 010101P"),
            (.iaru, "!!Order!!,Call,Sect\nK1ABC,ARRL", "K1ABC", "599 ARRL"),
            (.cqww, "!!Order!!,Call,CQZone\nK1ABC,4", "K1ABC", "599 4"),
            (.sst, "!!Order!!,Call,Name,Exch1\nK1ABC,JO,CT", "K1ABC", "JO CT"),
            (.naqp, "!!Order!!,Call,Name,State\nK1ABC,JO,CT", "K1ABC", "JO CT")
        ]
        for (contest, text, call, expected) in cases {
            let history = try HistoryImport.mrceHistory(text, contest: contest)
            let record = try XCTUnwrap(history.records[call])
            let (_, station) = try caller(contest, record)
            XCTAssertEqual(station.exchange, expected, contest.rawValue)
        }
        let reordered = try HistoryImport.mrceHistory("!!Order!!,Name,Exch1,Call\nJO,MA,K1ABC", contest: .cwt)
        XCTAssertEqual(reordered.records["K1ABC"]?.cwops, "MA")
    }

    func testARRL10LocationsSerialsAndMaritimeRegions() throws {
        for (call, state) in [("KH6ABC","HI"),("KL7ABC","AK"),("XE1ABC","DF"),("VE3ABC","ON")] {
            var record = HistoryRecord(call: call); record.state = state
            let (s, station) = try caller(.arrl10, record)
            XCTAssertEqual(station.exchange, "599 \(state)")
            XCTAssertEqual(ContestRules.score(s, station: station).multipliers, ["S:\(state)"])
            var home = settings(.arrl10, call: call)
            var profile = home.exchangeProfile(); profile.state = state; home.setExchangeProfile(profile)
            XCTAssertEqual(ContestRules.sentExchange(home, serial: 7), "5NN \(state)")
            XCTAssertNil(home.configurationError)
        }
        var maritime = HistoryRecord(call: "K1ABC/MM"); maritime.state = "3"
        let (s, station) = try caller(.arrl10, maritime)
        XCTAssertEqual(station.exchange, "599 3")
        XCTAssertEqual(ContestRules.score(s, station: station).multipliers, ["ITU:3"])
        var home = settings(.arrl10, call: "K1ABC/MM")
        var profile = home.exchangeProfile(); profile.state = "3"; home.setExchangeProfile(profile)
        XCTAssertNil(home.configurationError)
        XCTAssertEqual(ContestRules.initialOwnSerial(home), 1)
        XCTAssertEqual(ContestRules.sentExchange(home, serial: 9), "5NN 3")
        let dx = settings(.arrl10, call: "DL1ABC")
        XCTAssertEqual(ContestRules.sentExchange(dx, serial: 9), "5NN 9")
        XCTAssertTrue(ContestRules.checkExchange(dx, received: "599 TT9", expected: "599 009", callerCall: "DL1ABC").valid)
    }

    func testReportAndNumericComparisonAreContestSpecific() {
        for contest in ContestID.allCases where contest.definition.usesRST {
            let s = settings(contest)
            XCTAssertTrue(ContestRules.checkExchange(s, received: "599 123", expected: "599 123").valid, "\(contest)")
            // MRCE stores the report with StrToIntDef, so a cut report is an RST error.
            for rst in ["5NN","5N9","59N","ENN"] {
                XCTAssertEqual(ContestRules.checkExchange(s, received: "\(rst) 123", expected: "599 123").errors,
                               [DiagnosticText.rst], "\(contest): \(rst)")
            }
            XCTAssertFalse(ContestRules.checkExchange(s, received: "579 123", expected: "599 123").valid)
        }
        let ss = settings(.sweepstakes)
        XCTAssertTrue(ContestRules.checkExchange(ss, received: "599 A K1ABC 72 CT", expected: "599 A K1ABC 72 CT").valid)
        XCTAssertTrue(ContestRules.checkExchange(settings(.arrldx), received: "599 ATT", expected: "599 100").valid)
        XCTAssertFalse(ContestRules.checkExchange(settings(.iaru), received: "599 19", expected: "599 AN").valid)
        XCTAssertTrue(ContestRules.checkExchange(settings(.naqp), received: "JO DX", expected: "JO").valid)
        XCTAssertFalse(ContestRules.checkExchange(settings(.naqp), received: "JO CA", expected: "JO").valid)
    }

    func testIARUHQAndSSTLocationScoringMatchTransmittedExchange() throws {
        var hq = HistoryRecord(call: "K1ABC"); hq.society = "ARRL"
        let (s, station) = try caller(.iaru, hq)
        XCTAssertEqual(station.exchange, "599 ARRL")
        XCTAssertEqual(ContestRules.score(s, station: station).multipliers, ["HQ:ARRL"])
        XCTAssertEqual(ContestRules.score(s, station: station).points, 1)
        for (state, mult) in [("DX","DX:DL"),("EU","S:EU")] {
            var record = HistoryRecord(call: "DL1ABC"); record.name = "JO"; record.state = state
            let (s, station) = try caller(.sst, record)
            XCTAssertEqual(station.exchange, "JO \(state)")
            XCTAssertEqual(ContestRules.score(s, station: station).multipliers, [mult])
        }
        let dx = settings(.sst, call: "DL1ABC")
        XCTAssertEqual(ContestRules.sentExchange(dx, serial: 1), "BRUCE DX")
    }

    func testFieldDayDXAndSweepstakesEligibility() throws {
        let (_, dx) = try caller(.fieldday, HistoryRecord(call: "DL1ABC"))
        XCTAssertEqual(dx.section, "DX")
        XCTAssertEqual(ContestRules.sentExchange(settings(.fieldday, call: "DL1ABC"), serial: 1), "3A DX")
        var s = settings(.sweepstakes)
        s.customCalls = ["DL1ABC", "KH6ABC"]
        let game = ContestSimulator(settings: s)
        game.start()
        game.tick(6.0 * 512.0 / 11025.0)
        let station = try XCTUnwrap(game.pileup.first)
        XCTAssertEqual(station.call, "KH6ABC")
        XCTAssertEqual(station.section, "PAC")
        XCTAssertTrue(SweepstakesParser.parse(call: station.call, exchange: station.exchange).complete)
    }

    func testSweepstakesSectionsAndCutNumbers() {
        for section in ["OR","OK","NNY","NTX","SJV","WWA"] {
            let parsed = SweepstakesParser.parse(call: "K1ABC", exchange: "599 A K1ABC 70 \(section)")
            XCTAssertTrue(parsed.complete, section)
            XCTAssertEqual(parsed.serial, "599")
            XCTAssertEqual(parsed.check, "70")
            XCTAssertEqual(parsed.section, section)
        }
        // MRCE reads Sweepstakes numbers as digits: a cut check is not a check.
        let cut = SweepstakesParser.parse(call: "K1ABC", exchange: "599 A K1ABC 7T OR")
        XCTAssertFalse(cut.complete)
        XCTAssertEqual(cut.errors, ["Missing/Invalid Check"])
        XCTAssertEqual(SweepstakesParser.sections, Set(SweepstakesParser.orderedSections))
        XCTAssertEqual(SweepstakesParser.sections.count, 85)
        XCTAssertTrue(SweepstakesParser.sections.contains("TER"))
        XCTAssertFalse(SweepstakesParser.sections.contains("MAR"))
    }

    func testARRL10SectionImportUsesStateAndProvince() throws {
        let text = "cabrillo_id\tyear\tcall\tsection\tdxcc\nARRL-10\t2025\tK1ABC\tSJV\tK\nARRL-10\t2025\tVE3ABC\tONE\tVE"
        let history = try HistoryImport.arrl10TSV(text)
        XCTAssertEqual(history.records["K1ABC"]?.state, "CA")
        XCTAssertEqual(history.records["VE3ABC"]?.state, "ON")
    }

    func testEveryDefaultProfileIsValidAndEmptyRequiredFieldsFail() {
        for contest in ContestID.allCases {
            var s = settings(contest)
            XCTAssertNil(s.configurationError, contest.rawValue)
            var p = s.exchangeProfile()
            p.name = ""; p.state = ""; p.section = ""; p.fdClass = ""
            p.zoneText = ""; p.ituZoneText = ""; p.cwopsNumber = ""
            p.jaPrefecture = ""; p.jaCity = ""; p.jaPower = ""
            s.setExchangeProfile(p)
            if ![ContestID.wpx,.hst].contains(contest) {
                XCTAssertNotNil(s.configurationError, contest.rawValue)
            }
        }
    }
}
