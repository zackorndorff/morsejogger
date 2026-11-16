//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import Foundation
import XCTest
@testable import MorseJoggerCore

/// Element timing from the pinned MRCE keyers (`MorseKey.pas`, `FarnsKeyer.pas`)
/// compiled with FPC by tools/mrce-oracle/generate_keyer.py. Every keyed
/// element's start and length, and the message length, must match to the
/// sample at MRCE's 11,025 Hz rate.
final class MRCEKeyerOracleTests: XCTestCase {
    private struct Document: Decodable {
        let sampleRate: Double
        let cases: [Vector]
    }
    private struct Vector: Decodable {
        let keyer: String, text: String
        let wpmS: Int, wpmC: Int, fastSteps: Int
        let fastStarts: [Int]
        let samples: Int
        let marks: [[Int]]
    }
    private func load() throws -> Document {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "MRCEKeyerFixtures", withExtension: "json"))
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
    }
    private func compare(_ vector: Vector, rate: Double) -> String? {
        let farnsworth = vector.keyer == "farns"
        let fastRate = vector.fastSteps > 0 ? Double(vector.wpmS + vector.fastSteps) / Double(vector.wpmS) : 1
        let starts = vector.fastSteps > 0 ? vector.fastStarts : []
        let marks = MorseTimeline.marks(vector.text, wpm: vector.wpmS,
                                        characterWpm: farnsworth ? vector.wpmC : nil,
                                        fastReportRate: fastRate, fastReportStarts: starts,
                                        sampleRate: rate, farnsworthKeyer: farnsworth)
        let duration = MorseTimeline.duration(vector.text, wpm: vector.wpmS,
                                              characterWpm: farnsworth ? vector.wpmC : nil,
                                              fastReportRate: fastRate, fastReportStarts: starts,
                                              sampleRate: rate, farnsworthKeyer: farnsworth)
        let label = "\(vector.keyer) '\(vector.text)' \(vector.wpmS)/\(vector.wpmC) fast+\(vector.fastSteps)"
        guard marks.count == vector.marks.count else {
            return "\(label): \(marks.count) elements, MRCE \(vector.marks.count)"
        }
        for (index, mark) in marks.enumerated() {
            let start = Int((mark.start * rate).rounded()), length = Int((mark.duration * rate).rounded())
            if start != vector.marks[index][0] || length != vector.marks[index][1] {
                return "\(label): element \(index) at \(start)+\(length), MRCE \(vector.marks[index][0])+\(vector.marks[index][1])"
            }
        }
        let samples = Int((duration * rate).rounded())
        if samples != vector.samples { return "\(label): length \(samples), MRCE \(vector.samples)" }
        return nil
    }
    func testStandardKeyerElementTimingMatchesCompiledPascal() throws {
        let document = try load()
        let failures = document.cases.filter { $0.keyer == "std" && $0.fastSteps == 0 }
            .compactMap { compare($0, rate: document.sampleRate) }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) mismatches, first: \(failures.prefix(6).joined(separator: " | "))")
    }
    func testFasterReportTimingMatchesCompiledPascal() throws {
        let document = try load()
        let failures = document.cases.filter { $0.fastSteps > 0 }
            .compactMap { compare($0, rate: document.sampleRate) }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) mismatches, first: \(failures.prefix(6).joined(separator: " | "))")
    }
    func testFarnsworthKeyerElementTimingMatchesCompiledPascal() throws {
        let document = try load()
        let failures = document.cases.filter { $0.keyer == "farns" }
            .compactMap { compare($0, rate: document.sampleRate) }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) mismatches, first: \(failures.prefix(6).joined(separator: " | "))")
    }
}
