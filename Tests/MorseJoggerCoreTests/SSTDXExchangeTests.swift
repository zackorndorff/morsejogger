//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class SSTDXExchangeTests: XCTestCase {
    private func caller(_ call: String, record: HistoryRecord? = nil) -> Station {
        var settings = ContestSettings()
        settings.contest = .sst
        settings.mode = .single
        settings.customCalls = [call]
        if let record { settings.customRecords[call] = record }
        let simulator = ContestSimulator(settings: settings)
        simulator.start()
        simulator.tick(6.0 * 512.0 / 11025.0)
        return try! XCTUnwrap(simulator.pileup.first)
    }

    func testSyntheticForeignSSTCallerUsesDXExchange() {
        let station = caller("F1ABC")

        XCTAssertEqual(station.country, "F")
        XCTAssertEqual(station.state, "DX")
        XCTAssertTrue(station.exchange.hasSuffix(" DX"))
    }

    func testImportedSSTSecondExchangeIsPreservedForForeignCaller() {
        var record = HistoryRecord(call: "F1ABC")
        record.name = "JEAN"
        record.state = "EU"
        let station = caller("F1ABC", record: record)

        XCTAssertEqual(station.exchange, "JEAN EU")
    }

    func testUSAndCanadianSSTCallersReceiveStateOrProvinceFallback() {
        // Made-up locations follow the call area.
        let expected: [String: Set<String>] = ["K1ABC": ["CT", "MA", "ME", "NH", "RI", "VT"], "VE3ABC": ["ON"]]
        for (call, places) in expected {
            let station = caller(call)
            let exchange = station.exchange.split(separator: " ").map(String.init)
            XCTAssertEqual(exchange.count, 2, call)
            XCTAssertTrue(places.contains(exchange[1]), "\(call) sent \(exchange[1])")
        }
    }
}
