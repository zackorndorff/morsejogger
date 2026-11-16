//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class NAQPExchangeTests: XCTestCase {
    private func caller(_ call: String, home: String = "K1ABC", state: String? = nil) throws -> Station {
        var settings = ContestSettings()
        settings.contest = .naqp
        settings.mode = .single
        settings.myCall = home
        settings.customCalls = [call]
        var record = HistoryRecord(call: call)
        record.name = "JO"
        record.state = state ?? ""
        settings.customRecords[call] = record
        let simulator = ContestSimulator(settings: settings)
        simulator.start()
        simulator.tick(6.0 * 512.0 / 11025.0)
        let station = try XCTUnwrap(simulator.pileup.first)
        XCTAssertEqual(station.call, call)
        return station
    }

    func testCallerExchangeAndMultiplierUseSameRegion() throws {
        var settings = ContestSettings()
        settings.contest = .naqp
        for (call, location) in [("KH6ABC","HI"),("KL7ABC","AK"),("KP2ABC","KP2"),("XE1ABC","XE"),("DL1ABC","")] {
            let station = try caller(call)
            let expected = location.isEmpty ? "JO" : "JO \(location)"
            XCTAssertEqual(station.exchange, expected, call)
            XCTAssertTrue(ContestRules.isExchangeStructurallyValid(settings, received: expected, expected: station.exchange))
            XCTAssertTrue(ContestRules.checkExchange(settings, received: expected, expected: station.exchange).valid)
            let score = ContestRules.score(settings, station: station)
            XCTAssertEqual(score.points, 1)
            XCTAssertEqual(score.multipliers, location.isEmpty ? [] : ["S:\(location)"])
        }
        let dx = try caller("DL1ABC")
        XCTAssertTrue(ContestRules.checkExchange(settings, received: "JO DX", expected: dx.exchange).valid)
    }

    func testHawaiiCanWorkDXAndDXCanWorkHawaii() throws {
        XCTAssertEqual(try caller("DL1ABC", home: "KH6ABC").exchange, "JO")
        XCTAssertEqual(try caller("KH6ABC", home: "DL1ABC").exchange, "JO HI")
    }

    func testImportedLocationIsPreservedAndSyntheticLocationsMatchCountry() throws {
        XCTAssertEqual(try caller("VE3ABC", state: "ON").exchange, "JO ON")
        XCTAssertEqual(try caller("KP2ABC", state: "VI").exchange, "JO VI")
        XCTAssertEqual(try caller("DL1ABC", state: "DX").exchange, "JO")
        let canadian = try caller("VE3ABC")
        XCTAssertTrue(["ON","QC","BC","AB","SK","MB","NB","NS","PE","NL","YT","NT","NU"].contains(canadian.state))
        XCTAssertNotEqual(try caller("K1XYZ").state, "ON")
    }

    func testOwnExchangeUsesCallRegionAndStructuredExchangeFields() {
        var settings = ContestSettings()
        settings.contest = .naqp
        var profile = settings.exchangeProfile()
        profile.name = "JO"
        profile.state = "HI"
        settings.setExchangeProfile(profile)
        for (call, expected) in [("KH6ABC","JO HI"),("DL1ABC","JO"),("JA1ABC","JO")] {
            settings.myCall = call
            XCTAssertEqual(ContestRules.sentExchange(settings, serial: 1), expected)
            XCTAssertNil(settings.configurationError)
        }
        profile.name = "ALEX"
        settings.setExchangeProfile(profile)
        XCTAssertEqual(ContestRules.sentExchange(settings, serial: 1), "ALEX")
    }
}
