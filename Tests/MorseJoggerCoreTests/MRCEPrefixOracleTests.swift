//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import Foundation
import XCTest
@testable import MorseJoggerCore

/// WPX prefixes from the pinned `CallsignUtils.ExtractPrefix`, compiled with
/// FPC by tools/mrce-oracle/generate_prefix.py. The prefix is the WPX
/// multiplier, so a difference changes the score.
final class MRCEPrefixOracleTests: XCTestCase {
    private struct Document: Decodable { let cases: [Vector] }
    private struct Vector: Decodable { let call: String, prefix: String }

    func testWPXPrefixMatchesCompiledPascal() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "MRCEPrefixFixtures", withExtension: "json"))
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(document.cases.count, 100)
        let failures = document.cases.compactMap { vector -> String? in
            let actual = ContestRules.wpxPrefix(vector.call)
            return actual == vector.prefix ? nil : "\(vector.call): \(actual), MRCE \(vector.prefix)"
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) mismatches: \(failures.joined(separator: " | "))")
    }
}

final class CQWWMultiplierTests: XCTestCase {
    /// `CqWW.pas ExtractMultiplier`: Alaska and Hawaii share the United States
    /// country multiplier, while points still follow their own entity.
    func testAlaskaAndHawaiiShareTheUnitedStatesCountryMultiplier() {
        var settings = ContestSettings(); settings.contest = .cqww; settings.myCall = "VE3NEA"
        func score(_ call: String) -> ContestRules.Scoring {
            ContestRules.score(settings, station: Station(call: call, exchange: "", wpm: 25, tone: 600, volume: 1, shift: 0))
        }
        XCTAssertTrue(score("K1ABC").multipliers.contains("C:K"))
        XCTAssertTrue(score("KL7XX").multipliers.contains("C:K"))
        XCTAssertTrue(score("KH6ABC").multipliers.contains("C:K"))
        XCTAssertEqual(score("KL7XX").points, 2, "another North American entity")
        XCTAssertEqual(score("KH6ABC").points, 3, "another continent")
        XCTAssertNotEqual(score("KH6ABC").multipliers.first { $0.hasPrefix("Z:") },
                          score("K1ABC").multipliers.first { $0.hasPrefix("Z:") }, "zones stay separate")
    }
}
