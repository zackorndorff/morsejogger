//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import XCTest
@testable import MorseJoggerCore

/// Output levels of MRCE's receiver (moving-average filters, modulator, AGC),
/// compiled from the pinned Pascal by `tools/mrce-oracle/generate_receiver.py`.
/// Both sides get the same noise and the same keyed tones, and must agree on
/// the loudness of every 1024-sample window.
final class MRCEReceiverOracleTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Tone: Decodable { let offset: Double, amplitude: Double, firstBlock: Int, lastBlock: Int }
        struct Case: Decodable { let bandwidth: Int, pitch: Int, rms: [Double] }
        let sampleRate: Double, blockSamples: Int, blocks: Int, windowBlocks: Int
        let seed: UInt32, tones: [Tone], cases: [Case]
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "MRCEReceiverFixtures", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func swiftLevels(_ fixture: Fixture, bandwidth: Int, pitch: Int) -> [Double] {
        let rate = fixture.sampleRate
        // TModulator rounds the carrier to a whole number of samples per cycle.
        let carrier = rate / (rate / Double(pitch)).rounded()
        var renderer = MRCEAudioRenderer(sampleRate: rate, center: carrier, bandwidth: bandwidth)
        renderer.configure(center: carrier, bandwidth: bandwidth, outputPitch: carrier)
        var state = fixture.seed
        func uniform() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state >> 8) / 16_777_216
        }
        var levels: [Double] = [], sum = 0.0, n = 0.0
        for block in 1...fixture.blocks {
            for _ in 0..<fixture.blockSamples {
                var real = 18_000 * (uniform() - 0.5)
                // MRCE stores the conjugate (`Im -= A*Sin`) and its modulator
                // undoes it; the Swift mixer keeps the upright form.
                var imaginary = -18_000 * (uniform() - 0.5)
                for tone in fixture.tones where block >= tone.firstBlock && block <= tone.lastBlock {
                    let phase = 2 * Double.pi * tone.offset * n / rate
                    real += tone.amplitude * cos(phase)
                    imaginary += tone.amplitude * sin(phase)
                }
                n += 1
                let sample = renderer.receiverTail(real: real, imaginary: imaginary)
                sum += sample * sample
            }
            if block % fixture.windowBlocks == 0 {
                levels.append((sum / Double(fixture.windowBlocks * fixture.blockSamples)).squareRoot())
                sum = 0
            }
        }
        return levels
    }

    func testReceiverLevelsMatchCompiledPascal() throws {
        let fixture = try fixture()
        XCTAssertEqual(fixture.cases.count, 6)
        for item in fixture.cases {
            let levels = swiftLevels(fixture, bandwidth: item.bandwidth, pitch: item.pitch)
            XCTAssertEqual(levels.count, item.rms.count)
            for (index, (mine, theirs)) in zip(levels, item.rms).enumerated() {
                // The two carriers are a quarter cycle apart, so samples differ
                // while window loudness does not.
                XCTAssertEqual(mine, theirs, accuracy: 0.03 * theirs + 15,
                               "bandwidth \(item.bandwidth) pitch \(item.pitch) window \(index)")
            }
        }
    }

    /// The fixture itself shows what the operator hears: the full-level
    /// sidetone sits at the AGC ceiling, above the strongest caller.
    func testSidetoneAtFullMonitorLevelIsLouderThanAnyCaller() throws {
        let fixture = try fixture()
        XCTAssertEqual(Double(MRCEAudioProgram.sourceSidetoneAmplitude(decibels: 0)), 424_264, accuracy: 1)
        XCTAssertEqual(Double(MRCEAudioProgram.sourceSidetoneAmplitude(decibels: -20)), 42_426.4, accuracy: 1)
        XCTAssertEqual(MRCEAudioProgram.sourceSidetoneAmplitude(decibels: -60), 0)
        let wide = try XCTUnwrap(fixture.cases.first { $0.bandwidth == 500 })
        let sidetone = wide.rms[50], strongestCaller = wide.rms[17]
        XCTAssertEqual(sidetone, 20_000 / 2.0.squareRoot(), accuracy: 200)
        XCTAssertGreaterThan(sidetone, 1.3 * strongestCaller)
    }

    /// MRCE leaves 4.3 dB between its AGC ceiling and full scale. Playback
    /// uses that headroom, and a saturating sidetone still cannot clip.
    func testPlaybackUsesTheHeadroomAboveTheAGCCeilingWithoutClipping() {
        XCTAssertEqual(MRCEAudioRenderer.outputScale * 20_000, 0.95, accuracy: 1e-12)
        let rate = 11_025.0
        let program = MRCEAudioProgram(message: "K1ABC 5NN TT1", wpm: 30, frequency: 600,
                                       level: MRCEAudioProgram.sourceSidetoneAmplitude(decibels: 0),
                                       sampleRate: rate, channel: .transmit)
        var output = [Float](repeating: 0, count: 30_000)
        program.withView { view in
            let slots: [MRCEAudioProgramView?] = [view]
            var heads: [Int64] = [0]
            var renderer = MRCEAudioRenderer(sampleRate: rate, center: 600, bandwidth: 500, seed: 5)
            output.withUnsafeMutableBufferPointer { out in
                slots.withUnsafeBufferPointer { s in
                    heads.withUnsafeMutableBufferPointer { h in renderer.process(out, programs: s, playheads: h) }
                }
            }
        }
        let peak = Double(output.map(abs).max() ?? 0)
        XCTAssertEqual(peak, 0.95, accuracy: 0.01)
        XCTAssertLessThanOrEqual(peak, 0.95 + 1e-6, "the AGC cannot exceed its ceiling")
    }
}
