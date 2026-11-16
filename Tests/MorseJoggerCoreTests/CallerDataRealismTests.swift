//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import XCTest
@testable import MorseJoggerCore

/// What callers send when the only data is a general call list (the
/// downloaded Super Check Partial file) or nothing at all.
final class CallerDataRealismTests: XCTestCase {
    /// A small worldwide list standing in for MASTER.SCP: 20 US/Canada, 20 elsewhere.
    private static let worldwide: [String] =
        "K1ABC W6XYZ N4OGW VE3NEA VA7XX K0XX W9ZZ N2AA K5TT W8LNS WB6ACK KC5ARZ AA1A K7SS W3LPL N6RO K4BAI VE2FK VE6SV W0AIH"
            .split(separator: " ").map(String.init) +
        "DL1ABC G3ABC JA1XYZ JH4UYB PY2AVE VK3ABC ZL2M 9A1A S51A EA8AB UA3ABC OH2BH F5XYZ I1ZA 4X6TT LU1ABC JR7ABC JE1CKA SM5XYZ ON4UN"
            .split(separator: " ").map(String.init)

    private func callers(_ contest: ContestID, count: Int = 2_000, list: Bool = true, myCall: String = "K1ZZ") -> [Station] {
        var settings = ContestSettings()
        settings.contest = contest; settings.mode = .pileup; settings.seed = 5; settings.myCall = myCall
        var generic = ImportedHistory(); generic.calls = Self.worldwide
        let game = ContestSimulator(settings: settings, genericHistory: list ? generic : nil)
        game.start()
        return (0..<count).map { _ in game.fixtureMakeStation() }
    }
    private func field(_ station: Station, _ index: Int) -> String {
        let parts = station.exchange.split(separator: " ").map(String.init)
        return index < 0 ? parts[parts.count + index] : parts[index]
    }
    private func isUSVE(_ station: Station) -> Bool { station.country == "K" || station.country == "VE" }

    func testExchangeFieldsVaryBetweenCallers() {
        for list in [true, false] {
            XCTAssertGreaterThan(Set(callers(.cwt, list: list).map { field($0, -1) }).count, 15, "CWT numbers")
            XCTAssertGreaterThan(Set(callers(.fieldday, list: list).map { field($0, 0) }).count, 5, "Field Day classes")
            XCTAssertGreaterThan(Set(callers(.sweepstakes, list: list).map { field($0, -2) }).count, 10, "Sweepstakes checks")
            XCTAssertGreaterThan(Set(callers(.arrldx, list: list).map { field($0, -1) }).count, 3, "ARRL DX powers")
        }
        XCTAssertGreaterThan(Set(callers(.allja, list: false).map { field($0, -1) }).count, 20, "All JA prefectures")
        XCTAssertGreaterThan(Set(callers(.acag, list: false).map { field($0, -1) }).count, 20, "ACAG city codes")
    }

    func testOneCallAlwaysSendsTheSameExchange() {
        for contest in [ContestID.cwt, .fieldday, .sweepstakes, .naqp, .sst, .arrldx] {
            var seen: [String: String] = [:]
            for station in callers(contest, count: 600) {
                // The serial changes from one contact to the next, and MRCE
                // draws the precedence afresh each time a caller appears.
                let exchange = contest == .sweepstakes
                    ? station.exchange.split(separator: " ").suffix(2).joined(separator: " ") : station.exchange
                if let earlier = seen[station.call] {
                    XCTAssertEqual(exchange, earlier, "\(contest.rawValue) \(station.call)")
                }
                seen[station.call] = exchange
            }
        }
    }

    func testLocationsFollowTheCallArea() {
        let expected: [String: Set<String>] = [
            "W6XYZ": ["CA"], "VE3NEA": ["ON"], "VA7XX": ["BC"], "K0XX": ["CO", "IA", "KS", "MN", "MO", "NE", "ND", "SD"],
            "W8LNS": ["MI", "OH", "WV"], "VE2FK": ["QC"], "VE6SV": ["AB"],
        ]
        for station in callers(.naqp, count: 600) {
            if let places = expected[station.call] { XCTAssertTrue(places.contains(station.state), "\(station.call) \(station.state)") }
        }
        for station in callers(.sweepstakes, count: 600) where station.call == "VE3NEA" {
            XCTAssertTrue(["ONE", "ONN", "ONS", "GH"].contains(station.section), station.section)
        }
        // Japanese prefecture numbers follow the call area too: area 1 is Kanto (10...17).
        let ja1 = SyntheticExchange.fields(call: "JA1XYZ", country: "JA")
        XCTAssertTrue((10...17).contains(Int(ja1.jaPref) ?? 0), ja1.jaPref)
        let ja8 = SyntheticExchange.fields(call: "JA8ABC", country: "JA")
        XCTAssertTrue((101...114).contains(Int(ja8.jaPref) ?? 0), ja8.jaPref)
        XCTAssertTrue(ja8.jaCity.hasPrefix("01"), ja8.jaCity)
    }

    func testUnitedStatesAndCanadaSpanSeveralZones() {
        func zones(_ call: String) -> [Int] { let m = ContestRules.callMeta(call); return [m.cq, m.itu] }
        XCTAssertEqual(zones("K1ABC"), [5, 8])
        XCTAssertEqual(zones("W6XYZ"), [3, 6])
        XCTAssertEqual(zones("K0XX"), [4, 7])
        XCTAssertEqual(zones("W8LNS"), [4, 8])
        XCTAssertEqual(zones("VA7XX"), [3, 2])
        XCTAssertEqual(zones("VE3NEA"), [4, 4])
        XCTAssertEqual(zones("VY1AA"), [1, 2])
        XCTAssertEqual(zones("KH6ABC"), [31, 61], "other entities keep their own zone")
    }

    func testJapaneseContestsTakeOnlyJapaneseCallsFromAGeneralList() {
        for contest in [ContestID.allja, .acag] {
            let stations = callers(contest, count: 300)
            XCTAssertTrue(stations.allSatisfy { $0.country == "JA" }, contest.rawValue)
        }
    }

    /// The share of US and Canadian callers follows MRCE's own call-history
    /// file for each contest rather than the worldwide list's mix (half here).
    func testCallerMixFollowsTheContest() {
        let expected: [(ContestID, Double)] = [(.fieldday, 0.98), (.naqp, 0.98), (.sst, 0.94), (.cwt, 0.68),
                                               (.cqww, 0.54), (.arrl10, 0.45), (.iaru, 0.32)]
        for (contest, share) in expected {
            for list in [true, false] {
                let stations = callers(contest, list: list)
                let home = Double(stations.filter(isUSVE).count) / Double(stations.count)
                XCTAssertEqual(home, share, accuracy: 0.04, "\(contest.rawValue) list \(list)")
            }
        }
        // Contests without a figure keep the list's own mix.
        let wpx = callers(.wpx)
        XCTAssertEqual(Double(wpx.filter(isUSVE).count) / Double(wpx.count), 0.5, accuracy: 0.04)
        XCTAssertTrue(callers(.sweepstakes, count: 300).allSatisfy { $0.country == "K" || $0.country == "VE" })
    }

    func testImportedContestHistoryIsUsedAsItStands() {
        var settings = ContestSettings()
        settings.contest = .cwt; settings.mode = .pileup; settings.seed = 5
        var history = ImportedHistory()
        var record = HistoryRecord(call: "DL1ABC"); record.name = "HANS"; record.cwops = "777"
        history.calls = ["DL1ABC"]; history.records["DL1ABC"] = record
        settings.contestHistories[ContestID.cwt.rawValue] = history
        let game = ContestSimulator(settings: settings)
        game.start()
        let station = game.fixtureMakeStation()
        XCTAssertEqual(station.call, "DL1ABC")
        XCTAssertEqual(station.exchange, "HANS 777")
    }
}
