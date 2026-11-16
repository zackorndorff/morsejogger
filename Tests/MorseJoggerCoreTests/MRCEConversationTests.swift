//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import Foundation
import XCTest
import MorseJoggerCore

/// User-visible seeded transcripts captured from compiled upstream Pascal.
/// The assertions compare complete on-air text, not internal operator flags.
final class MRCEConversationTests: XCTestCase {
    private struct Fixture: Decodable {
        let provenance: Provenance
        let scenarios: [Scenario]
    }
    private struct Provenance: Decodable {
        let upstream: String
        let sourceSHA256: [String: String]
    }
    private struct Scenario: Decodable {
        let name: String
        let settings: Settings
        let steps: [Step]
    }
    private struct Settings: Decodable {
        let contest: String
        let mode: String
        let seed: UInt32
        let caller: String
        let styleBand: Double
        let ownExchange: String
        let callerExchange: String
    }
    private struct Step: Decodable {
        let label: String
        let input: Input
        let oracle: Oracle
    }
    private struct Input: Decodable {
        let command: String
        let call: String
        let exchange1: String
        let exchange2: String
    }
    private struct Oracle: Decodable {
        let tx: String
        let rx: String
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "MRCEConversationFixtures", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testSeededConversationsMatchCompiledPascalOnAirTranscript() throws {
        let document = try fixture()
        XCTAssertEqual(document.provenance.upstream, "304e51aece5a17f4cba548527816a385a8f6f814")
        XCTAssertEqual(document.scenarios.count, 3)

        for scenario in document.scenarios {
            var settings = ContestSettings()
            settings.contest = try XCTUnwrap(ContestID(rawValue: scenario.settings.contest))
            settings.mode = try XCTUnwrap(SessionMode(rawValue: scenario.settings.mode))
            settings.seed = scenario.settings.seed
            settings.customCalls = [scenario.settings.caller]
            // Every scenario uses the stock WPX exchange with the serial at 1.
            XCTAssertEqual(scenario.settings.ownExchange, "5NN 001")

            let game = ContestSimulator(settings: settings)
            XCTAssertTrue(game.start(), "\(scenario.name): start")
            var now = 0.0
            var transcript: [String] = []
            XCTAssertFalse(scenario.steps.isEmpty, "\(scenario.name) has no transcript steps")

            for step in scenario.steps {
                let command = try XCTUnwrap(step.input.command == "CQ" ? Command.cq :
                                            step.input.command == "Enter" ? Command.esm : nil,
                                            "Unknown oracle command \(step.input.command)")
                game.command(command, call: step.input.call,
                             exchange: [step.input.exchange1, step.input.exchange2]
                                .filter { !$0.isEmpty }.joined(separator: " "))
                let keyed = game.drainEvents().filter { $0.kind == .transmit }.map(\.text)
                let actualTX = keyed.joined(separator: " ")
                transcript.append("\(step.label) TX=\(actualTX)")
                // The oracle was given the exchange as a literal; decode the
                // operator's NrAsText form (`5NNTT1`) back to it.
                XCTAssertEqual(CallerExchangeTextTests.ownCanonical(actualTX), step.oracle.tx,
                               "\(scenario.name) transcript so far: \(transcript.joined(separator: " | "))")

                var received: [RadioEvent] = []
                for text in keyed {
                    let duration = ContestRules.cwSeconds(text, wpm: settings.wpm)
                    game.acknowledgeTransmit(duration: duration + 0.05)
                    now += duration + 0.06
                    game.tick(now)
                    received += game.drainEvents().filter { $0.kind == .receive }
                }
                if !step.oracle.rx.isEmpty {
                    let deadline = now + 20
                    while received.isEmpty && now < deadline {
                        now += 0.1
                        game.tick(now)
                        received += game.drainEvents().filter { $0.kind == .receive }
                    }
                    if let voice = received.first {
                        let rxDuration = voice.voices.map { ContestRules.cwSeconds($0.message, wpm: $0.wpm) }.max() ?? 0
                        game.acknowledgeReceive(duration: rxDuration + 0.05)
                        now += rxDuration + 0.06
                        game.tick(now)
                        received += game.drainEvents().filter { $0.kind == .receive }
                        // Finish the voice and collect any duplicate/spurious reply in this short tail.
                        now += 0.7
                        game.tick(now)
                        received += game.drainEvents().filter { $0.kind == .receive }
                    }
                } else {
                    now += 0.7
                    game.tick(now)
                    received += game.drainEvents().filter { $0.kind == .receive }
                }
                // The compiled-Pascal oracle predates NrAsText: decode 5NN/cut numbers in caller text.
                let actualRX = received.map { CallerExchangeTextTests.decodeCuts($0.text) }.joined(separator: " · ")
                transcript.append("\(step.label) RX=\(actualRX)")
                XCTAssertEqual(actualRX, step.oracle.rx,
                               "\(scenario.name) transcript so far: \(transcript.joined(separator: " | "))")
            }
        }
    }
}
