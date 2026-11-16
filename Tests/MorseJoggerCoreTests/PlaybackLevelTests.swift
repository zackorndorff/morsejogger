//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

/// Where signals sit relative to full scale after the receiver and AGC. These
/// pin the figures behind the loudness discussion in `FABLE_REVIEW.md`.
final class PlaybackLevelTests: XCTestCase {
    /// Steady-state peak of a keyed tone, as a fraction of full scale.
    private func peak(level: Float, channel: MRCEAudioChannel, bandwidth: Int = 500, receiveGain: Float = 1) -> Double {
        let rate = 11_025.0
        let program = MRCEAudioProgram(message: "TTTTTTTT", wpm: 12, frequency: 600, level: level,
                                       sampleRate: rate, channel: channel)
        var output = [Float](repeating: 0, count: 60_000)
        program.withView { view in
            let slots: [MRCEAudioProgramView?] = [view]
            var heads: [Int64] = [0]
            var renderer = MRCEAudioRenderer(sampleRate: rate, center: 600, bandwidth: bandwidth, seed: 5)
            output.withUnsafeMutableBufferPointer { out in
                slots.withUnsafeBufferPointer { s in
                    heads.withUnsafeMutableBufferPointer { h in
                        renderer.process(out, programs: s, playheads: h, receiveGain: receiveGain)
                    }
                }
            }
        }
        return Double(output[20_000...].map(abs).max() ?? 0)
    }

    func testStrongestCallerIsWithinADecibelOfTheSidetone() {
        let sidetone = peak(level: MRCEAudioProgram.sourceSidetoneAmplitude(decibels: 0), channel: .transmit)
        let strongest = peak(level: MRCEAudioProgram.sourceStationAmplitude(uShaped: 1), channel: .receive)
        let weakest = peak(level: MRCEAudioProgram.sourceStationAmplitude(uShaped: -1), channel: .receive)
        XCTAssertEqual(sidetone, 0.95, accuracy: 0.01, "the sidetone saturates the AGC")
        XCTAssertEqual(strongest, 0.845, accuracy: 0.02)
        XCTAssertGreaterThan(20 * log10(strongest / sidetone), -1.2)
        XCTAssertEqual(weakest, 0.41, accuracy: 0.03, "about 6 dB under the strongest")
    }

    func testNarrowerFiltersBringCallersCloserToTheCeiling() {
        // The AGC's knee follows the noise that passes the filter.
        let wide = peak(level: 45_000, channel: .receive, bandwidth: 600)
        let narrow = peak(level: 45_000, channel: .receive, bandwidth: 100)
        XCTAssertGreaterThan(narrow, wide)
        XCTAssertEqual(narrow, 0.94, accuracy: 0.02)
    }

    func testSidetoneMatchesTheStrongestCallerNearMinusTwentyDecibels() {
        let strongest = peak(level: 45_000, channel: .receive)
        let sidetone = peak(level: MRCEAudioProgram.sourceSidetoneAmplitude(decibels: -19), channel: .transmit)
        XCTAssertEqual(sidetone, strongest, accuracy: 0.03)
    }

    func testReceiveVolumeTurnsDownCallersButNotTheSidetone() {
        let caller = peak(level: 45_000, channel: .receive)
        XCTAssertEqual(peak(level: 45_000, channel: .receive, receiveGain: 0.25), 0.25 * caller, accuracy: 0.01)
        let sidetone = MRCEAudioProgram.sourceSidetoneAmplitude(decibels: 0)
        XCTAssertEqual(peak(level: sidetone, channel: .transmit, receiveGain: 0.25), 0.95, accuracy: 0.01)
        XCTAssertEqual(peak(level: sidetone, channel: .transmit, receiveGain: 0), 0.95, accuracy: 0.01)
    }

    /// 600 Hz is rendered at 600 Hz. (MRCE's modulator rounds to a whole
    /// number of samples per cycle and plays 612.5 Hz; not reproduced.)
    func testPitchIsExact() {
        let rate = 11_025.0
        let program = MRCEAudioProgram(message: "TTTT", wpm: 12, frequency: 600,
                                       level: MRCEAudioProgram.sourceSidetoneAmplitude(decibels: 0),
                                       sampleRate: rate, channel: .transmit)
        var output = [Float](repeating: 0, count: 22_050)
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
        // Count upward zero crossings inside the first long dash.
        let window = output[3_000..<8_512]
        var crossings = 0
        for (a, b) in zip(window, window.dropFirst()) where a < 0 && b >= 0 { crossings += 1 }
        XCTAssertEqual(Double(crossings) * rate / Double(window.count), 600, accuracy: 3)
    }
}
