//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import Foundation
import XCTest
@testable import MorseJoggerCore

/// MRCE's own test cases for its Sweepstakes exchange parser
/// (`Test/SSExchParserTest.pas`), extracted by
/// tools/mrce-oracle/extract_ss_parser_vectors.py.
final class MRCESweepstakesParserTests: XCTestCase {
    private struct Document: Decodable { let cases: [Case] }
    private struct Case: Decodable {
        let name, entered, precedence, check, section, call, error: String
        let serial: Int
    }

    func testParserMatchesMRCETestCases() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "MRCESweepstakesParserFixtures", withExtension: "json"))
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(document.cases.count, 250)
        var failures: [String] = []
        for item in document.cases {
            let parsed = SweepstakesParser.parse(call: "", exchange: item.entered)
            // RunTest in the Pascal: '<NR>.<Prec>.<Check>.<Section>[.<Call>]', compared
            // exactly when the exchange validates, and otherwise required to be
            // contained in '<summary>-<error>'.
            var summary = "\(Int(parsed.serial) ?? 0).\(parsed.precedence).\(parsed.check).\(parsed.section)"
            if !parsed.correctedCall.isEmpty { summary += "." + parsed.correctedCall }
            var expected = "\(item.serial).\(item.precedence).\(item.check).\(item.section)"
            if !item.call.isEmpty { expected += "." + item.call }
            if !item.error.isEmpty { expected += "-" + item.error }
            let matches = parsed.errors.isEmpty ? summary == expected
                : (summary + "-" + parsed.errors[0]).contains(expected)
            if !matches { failures.append("\(item.name) [\(item.entered)]: \(summary) \(parsed.errors), MRCE \(expected)") }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) mismatches:\n" + failures.prefix(40).joined(separator: "\n"))
    }
}
