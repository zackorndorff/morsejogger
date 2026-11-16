//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class MRCEHistoryCSVTests: XCTestCase {
    func testMRCEHistoryKeepsQuotedCommasAlignedWithHeader() throws {
        let text = "!!Order!!,Call,Name,Exch1,UserText,\nK1ABC,\"ANN, JR\",1234,\"CLUB, WEST\"\n"
        let history = try HistoryImport.mrceHistory(text, contest: .fieldday)

        XCTAssertEqual(history.calls, ["K1ABC"])
        XCTAssertEqual(history.records["K1ABC"]?.name, "ANN, JR")
        XCTAssertEqual(history.records["K1ABC"]?.fdClass, "1234")
        XCTAssertEqual(history.records["K1ABC"]?.userText, "CLUB, WEST")
    }

    func testMRCEHistoryDecodesDoubledQuotesInsideQuotedField() throws {
        let text = "!!Order!!,Call,Name,Exch1,UserText,\nK1ABC,\"ANN \"\"THE HAM\"\" JR\",1234,\"CLUB, WEST\"\n"
        let history = try HistoryImport.mrceHistory(text, contest: .fieldday)
        XCTAssertEqual(history.records["K1ABC"]?.name, "ANN \"THE HAM\" JR")
        XCTAssertEqual(history.records["K1ABC"]?.userText, "CLUB, WEST")
    }

    func testMRCEHistoryRejectsUnclosedQuotedField() {
        let text = "!!Order!!,Call,Name\nK1ABC,\"ANN, JR\n"
        XCTAssertThrowsError(try HistoryImport.mrceHistory(text, contest: .fieldday))
    }

    func testSSTUsesNameAndExch1InStandardAndReorderedHeaders() throws {
        let standard = try HistoryImport.mrceHistory("!!Order!!,Call,Name,Exch1,UserText\nK1ABC,bob,ny,club west\n", contest: .sst)
        XCTAssertEqual(standard.records["K1ABC"]?.name, "BOB")
        XCTAssertEqual(standard.records["K1ABC"]?.state, "NY")
        XCTAssertEqual(standard.records["K1ABC"]?.userText, "club west")

        let reordered = try HistoryImport.mrceHistory("!!Order!!,Exch1,UserText,Call,Name\nny,club west,K1ABC,bob\n", contest: .sst)
        XCTAssertEqual(reordered.records["K1ABC"]?.name, "BOB")
        XCTAssertEqual(reordered.records["K1ABC"]?.state, "NY")
        XCTAssertEqual(reordered.records["K1ABC"]?.userText, "club west")
    }

    func testSSTQuotedCommaAndInvalidRows() throws {
        let text = "!!Order!!,Call,Name,Exch1,UserText\n# comment,,,,\nK1ABC,\"BOB, JR\",NY,\"CLUB, WEST\"\nK2ABC,,NY,x\nK3ABC,TOOLONGNAME,NY,x\nK4ABC,BOB,TOOLONG,x\n"
        let history = try HistoryImport.mrceHistory(text, contest: .sst)
        XCTAssertEqual(history.records["K1ABC"]?.name, "BOB, JR")
        XCTAssertEqual(history.records["K1ABC"]?.state, "NY")
        XCTAssertEqual(history.records["K1ABC"]?.userText, "CLUB, WEST")
        XCTAssertEqual(history.calls, ["K1ABC"])
    }

    func testSSTRejectsImportWhenEveryExchangeRowIsInvalid() {
        let text = "!!Order!!,Call,Name,Exch1\nK1ABC,,NY\nK2ABC,BOB,TOOLONG\n"
        XCTAssertThrowsError(try HistoryImport.mrceHistory(text, contest: .sst)) { error in
            XCTAssertTrue(String(describing: error).contains("No valid SST history rows"))
        }
    }

    func testImportedSSTNameAndStateReachCallerExchange() throws {
        let history = try HistoryImport.mrceHistory("!!Order!!,Call,Name,Exch1\nK1ABC,BOB,NY\n", contest: .sst)
        var settings = ContestSettings()
        settings.contest = .sst
        settings.mode = .single
        settings.customCalls = ["K1ABC"]
        settings.contestHistories[ContestID.sst.rawValue] = history
        let simulator = ContestSimulator(settings: settings)
        simulator.start()
        simulator.tick(6.0 * 512.0 / 11025.0)
        let station = try XCTUnwrap(simulator.pileup.first)
        XCTAssertEqual(station.name, "BOB")
        XCTAssertEqual(station.exchange, "BOB NY")
    }

    func testSSTPreservesDuplicateRowsAndSelectedRowAssociation() throws {
        let text = "!!Order!!,Call,Name,Exch1\nK1ABC,ALICE,NY\nK1ABC,AMY,CT\nK2ABC,BOB,MA\n"
        let history = try HistoryImport.mrceHistory(text, contest: .sst)
        XCTAssertEqual(history.calls, ["K1ABC", "K2ABC"])
        XCTAssertEqual(history.rows.map(\.name), ["ALICE", "AMY", "BOB"])
        let persisted = try JSONDecoder().decode(ImportedHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(persisted, history)

        var settings = ContestSettings()
        settings.contest = .sst
        settings.mode = .single
        settings.seed = 11
        settings.contestHistories[ContestID.sst.rawValue] = history
        let simulator = ContestSimulator(settings: settings)
        simulator.start()
        simulator.tick(6.0 * 512.0 / 11025.0)
        let station = try XCTUnwrap(simulator.pileup.first)
        let row = try XCTUnwrap(station.importedRecord)
        XCTAssertEqual(row.call, station.call)
        XCTAssertEqual(station.exchange, "\(row.name) \(row.state)")
    }

    func testImportedHistoryDecodesLegacyUniqueCallShape() throws {
        var oldHistory = ImportedHistory()
        oldHistory.calls = ["K1ABC"]
        oldHistory.records["K1ABC"] = HistoryRecord(call: "K1ABC")
        oldHistory.sourceName = "old SST history"
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(oldHistory)) as? [String: Any])
        legacyObject.removeValue(forKey: "rows")
        let legacy = try JSONSerialization.data(withJSONObject: legacyObject)
        let history = try JSONDecoder().decode(ImportedHistory.self, from: legacy)
        XCTAssertEqual(history.calls, ["K1ABC"])
        XCTAssertEqual(history.records["K1ABC"]?.call, "K1ABC")
        XCTAssertEqual(history.sourceName, "old SST history")
        XCTAssertTrue(history.rows.isEmpty)

        var settings = ContestSettings()
        settings.contestHistories[ContestID.sst.rawValue] = history
        let restoredSettings = try JSONDecoder().decode(ContestSettings.self, from: JSONEncoder().encode(settings))
        let restoredHistory = try XCTUnwrap(restoredSettings.contestHistories[ContestID.sst.rawValue])
        XCTAssertEqual(restoredHistory.calls, ["K1ABC"], "Legacy unique-call history remains available")
        XCTAssertEqual(restoredHistory.records["K1ABC"]?.call, "K1ABC", "Legacy records remain available")
        XCTAssertTrue(restoredHistory.rows.isEmpty, "Missing legacy rows are not fabricated during persistence")
    }
}
