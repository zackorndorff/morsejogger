//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class MRCEAudioDSPTests: XCTestCase {
    func testSparseSlotsPreserveReleaseTailsAndReuseAcrossCallbackSizes() {
        for channel in [MRCEAudioChannel.receive, .transmit] {
            let program = MRCEAudioProgram(message: "TEST", wpm: 25, frequency: 700,
                                           level: 27_000, sampleRate: 11_025, channel: channel)
            program.withView { view in
                func render(chunkSize: Int) -> [Float] {
                    var renderer = MRCEAudioRenderer(sampleRate: 11_025, center: 650,
                                                     bandwidth: 250, stationCapacity: 32, seed: 71)
                    var slots = [MRCEAudioProgramView?](repeating: nil, count: 32)
                    var heads = [Int64](repeating: 0, count: 32)
                    var result: [Float] = []
                    // Start after idle, cancel during a mark, let the tail settle,
                    // then reuse the same sparse slot with late and fresh starts.
                    for (active, start, length) in [(false, 0, 400), (true, 0, 200),
                                                    (false, 0, 800), (true, 100, 200),
                                                    (false, 0, 800), (true, 0, 900)] {
                        slots[31] = active ? view : nil
                        heads[31] = Int64(start)
                        var remaining = length
                        while remaining > 0 {
                            let size = min(chunkSize, remaining)
                            var output = [Float](repeating: 0, count: size)
                            output.withUnsafeMutableBufferPointer { buffer in
                                slots.withUnsafeBufferPointer { programs in
                                    heads.withUnsafeMutableBufferPointer { playheads in
                                        renderer.process(buffer, programs: programs, playheads: playheads, qsk: true)
                                    }
                                }
                            }
                            result += output
                            remaining -= size
                        }
                        XCTAssertEqual(heads[31], Int64(active ? start + length : start))
                    }
                    return result
                }
                let reference = render(chunkSize: 2_000)
                XCTAssertEqual(render(chunkSize: 1), reference)
                XCTAssertEqual(render(chunkSize: 17), reference)
            }
        }
    }

    func testBlockedAGCMatchesOriginalScanExactly() {
        // Exercise both native and portable rates, startup, silence, impulses,
        // ring wraps and partial final blocks against the original algorithm.
        for attack in [1, 112, 155, 620] {
            let count = 4 * attack + 1
            var weights = [Double](repeating: 0, count: count)
            for i in 0..<attack {
                let weight = log(0.5 - 0.5 * cos(Double(i + 1) * .pi / Double(attack + 1)))
                weights[i] = weight
                weights[count - 1 - i] = weight
            }
            var optimized = MRCEAGCEnvelope(weights: weights)
            var history = [Double](repeating: 0, count: count)
            var head = 0
            var rng: UInt32 = 71
            for sample in 0..<(count * 4) {
                rng = rng &* 1_664_525 &+ 1_013_904_223
                let signal = sample < count ? 0.0 :
                    sample % 97 == 0 ? 100_000.0 : Double(Int32(bitPattern: rng)) / 100_000
                let magnitude = log(abs(signal + 1e-10))
                history[head] = magnitude
                head = (head + 1) % count
                var expected = 1e-10
                for i in 0..<count {
                    expected = max(expected, history[(head + i) % count] + weights[i])
                }
                XCTAssertEqual(optimized.push(magnitude), expected)
            }
        }
    }

    func testProgramViewsRetainStationIdentityAcrossOverlappingRXAndTX() {
        let a=MRCEAudioProgram(message:"A",wpm:20,frequency:600,sampleRate:11_025,channel:.receive,stationID:17)
        let b=MRCEAudioProgram(message:"B",wpm:20,frequency:700,sampleRate:11_025,channel:.receive,stationID:18)
        let tx=MRCEAudioProgram(message:"T",wpm:20,frequency:600,sampleRate:11_025,channel:.transmit)
        XCTAssertEqual(a.withView{$0.stationID},17)
        XCTAssertEqual(b.withView{$0.stationID},18)
        XCTAssertEqual(tx.withView{$0.stationID},-1,"TX stays outside caller-specific cancellation")
    }

    private func render(chunks: [Int], effects: Effects = Effects(), receiveGain: Float = 1) -> [Float] {
        let rate = 11_025.0
        let program = MRCEAudioProgram(message: "CQ K1ABC", wpm: 25, frequency: 700,
                                       level: 27_000,
                                       sampleRate: rate, channel: .receive)
        return program.withView { view in
            let slots: [MRCEAudioProgramView?] = [view]
            var heads: [Int64] = [0]
            var renderer = MRCEAudioRenderer(sampleRate: rate, center: 650, bandwidth: 250, seed: 71)
            var output = [Float](repeating: 0, count: chunks.reduce(0, +))
            var offset = 0
            for size in chunks {
                output.withUnsafeMutableBufferPointer { whole in
                    let part = UnsafeMutableBufferPointer(start: whole.baseAddress!.advanced(by: offset), count: size)
                    slots.withUnsafeBufferPointer { slotBuffer in
                        heads.withUnsafeMutableBufferPointer { headBuffer in
                            renderer.process(part, programs: slotBuffer, playheads: headBuffer,
                                             effects: effects, receiveGain: receiveGain)
                        }
                    }
                }
                offset += size
            }
            return output
        }
    }

    func testStreamingOutputDoesNotDependOnCallbackChunking() {
        let oneBlock = render(chunks: [12_000])
        let partitioned = render(chunks: [1, 17, 512, 2048, 4096, 5326])
        XCTAssertEqual(oneBlock, partitioned)
    }

    func testRetuningDuringPlaybackIsChunkInvariant() {
        func render(chunks: [Int]) -> [Float] {
            var renderer = MRCEAudioRenderer(sampleRate: 11_025, center: 600, bandwidth: 1_000, seed: 0x1234)
            var output = [Float](repeating: 0, count: chunks.reduce(0, +))
            var offset = 0
            for size in chunks {
                if offset == 1_000 {
                    renderer.configure(center: 900, bandwidth: 250, outputPitch: 700)
                }
                output.withUnsafeMutableBufferPointer { whole in
                    let part = UnsafeMutableBufferPointer(start: whole.baseAddress!.advanced(by: offset), count: size)
                    renderer.process(part, stations: [])
                }
                offset += size
            }
            return output
        }

        let singleBoundary = render(chunks: [1_000, 5_000])
        let partitionedAtBoundary = render(chunks: [127, 373, 500, 1, 17, 511, 2_048, 2_423])
        XCTAssertEqual(singleBoundary, partitionedAtBoundary,
                       "a live receiver retune must reset filter history at the same sample regardless of callback chunking")
    }

    func testReceiveGainIsAppliedToReceiverOutput() {
        let normal = render(chunks: [12_000])
        let half = render(chunks: [12_000], receiveGain: 0.5)
        for (full, reduced) in zip(normal, half) {
            XCTAssertEqual(reduced, full * 0.5, accuracy: 0.000001)
        }
    }

    func testSSTReceiveTimingUsesEachStationsEffectiveAndCharacterSpeed() {
        // SST QRS reduces the effective character rate for low and medium
        // skill callers while high skill callers retain the master rate.
        // The app's receive scheduler and program must both use the immutable
        // speeds copied into each RadioVoice.
        let cases: [(String, Int, Int)] = [
            ("ordinary low", 30, 35), ("ordinary medium", 30, 35),
            ("ordinary high", 30, 35),
            ("QRS low", 24, 32), ("QRS medium", 25, 32), ("QRS high", 26, 35)
        ]
        var settings = ContestSettings()
        settings.contest = .sst
        settings.farnsworthCharRate = 35

        for (label, effectiveWpm, characterWpm) in cases {
            XCTAssertGreaterThanOrEqual(characterWpm, effectiveWpm, "\(label) character rate")
            let duration = MorseTimeline.duration("CQ SST K1ABC", wpm: effectiveWpm,
                                                  characterWpm: characterWpm, sampleRate: 11_025)
            let program = MRCEAudioProgram(message: "CQ SST K1ABC", wpm: effectiveWpm,
                                           characterWpm: characterWpm, frequency: 700,
                                           sampleRate: 11_025, channel: .receive)
            XCTAssertEqual(Double(program.sampleCount) / 11_025, duration, accuracy: 1.0 / 11_025,
                           "\(label) audio duration must honor the station's captured character rate")
        }

        // Home keying remains at its configured sending speed and is not
        // affected by caller-side SST settings.
        let transmitDuration = MorseTimeline.duration("CQ SST K1ABC", wpm: 20, sampleRate: 11_025)
        let transmitProgram = MRCEAudioProgram(message: "CQ SST K1ABC", wpm: 20,
                                               frequency: 700, sampleRate: 11_025,
                                               channel: .transmit)
        XCTAssertEqual(Double(transmitProgram.sampleCount) / 11_025, transmitDuration,
                       accuracy: 1.0 / 11_025)
        XCTAssertGreaterThan(settings.farnsworthCharRate, 20)
    }

    func testTransmitProgramKeepsPhysicalMarkLevel() {
        let rate = 11_025.0
        let program = MRCEAudioProgram(message: "E", wpm: 20, frequency: 700,
                                       level: 16_384, sampleRate: rate, channel: .transmit)
        program.withView { view in
            XCTAssertEqual(view.events.first?.level, 16_384)
            let slots: [MRCEAudioProgramView?] = [view]
            var heads: [Int64] = [0]
            var renderer = MRCEAudioRenderer(sampleRate: rate, center: 700, bandwidth: 500, seed: 2)
            var output = [Float](repeating: 0, count: 2_000)
            output.withUnsafeMutableBufferPointer { out in
                slots.withUnsafeBufferPointer { s in
                    heads.withUnsafeMutableBufferPointer { h in
                        renderer.process(out, programs: s, playheads: h)
                    }
                }
            }
            XCTAssertLessThan(abs(output[0]), 0.001, "AGC lookahead should preserve the zero end of the mark ramp")
            XCTAssertGreaterThan(abs(output[600]), 0.2, "the mark should be clearly present after the rise")
            let peak = output.map(abs).max() ?? 0
            // 16,384 in gives 20,000 x (1 - exp(-16,384 / 21,934)) = 10,526 out of the AGC.
            XCTAssertEqual(Double(peak), 10_526 * MRCEAudioRenderer.outputScale, accuracy: 0.05,
                           "TX should follow MRCE's 20,000 maximum output and 76 dB AGC mapping before playback scaling")

            let chunkedSlots: [MRCEAudioProgramView?] = [view]
            var chunkedHeads: [Int64] = [0]
            var chunkedRenderer = MRCEAudioRenderer(sampleRate: rate, center: 700, bandwidth: 500, seed: 2)
            var chunked = [Float](repeating: 0, count: 2_000)
            let chunks = [17, 512, 1_471]
            var offset = 0
            for count in chunks {
                chunked.withUnsafeMutableBufferPointer { whole in
                    let part = UnsafeMutableBufferPointer(start: whole.baseAddress!.advanced(by: offset), count: count)
                    chunkedSlots.withUnsafeBufferPointer { s in
                        chunkedHeads.withUnsafeMutableBufferPointer { h in
                            chunkedRenderer.process(part, programs: s, playheads: h)
                        }
                    }
                }
                offset += count
            }
            XCTAssertEqual(output, chunked)
        }
    }

    func testSelfMonitorGainMatchesMRCECurveAtBoundariesAndRepresentativeLevels() {
        let expected: [(Int, Float)] = [
            (-60, 0),
            (-59, Float(pow(10.0, -59.0 / 20.0))),
            (-58, Float(pow(10.0, -58.0 / 20.0) * 2)),
            (-57, Float(pow(10.0, -57.0 / 20.0))),
            (-20, 0.1),
            (0, 1)
        ]
        for (decibels, gain) in expected {
            XCTAssertEqual(MRCEAudioProgram.sourceMonitorGain(decibels: decibels), gain, accuracy: 0.000_000_1,
                           "Unexpected self-monitor gain at \(decibels) dB")
        }
        XCTAssertEqual(MRCEAudioProgram.sourceMonitorGain(decibels: -80), 0,
                       "Values below the supported range clamp to exact silence")
        XCTAssertEqual(MRCEAudioProgram.sourceMonitorGain(decibels: 10), 1,
                       "Values above the supported range clamp to unity")
    }

    func testMinimumMonitorGainKeepsScheduledTXAndQSKReceiveSemantics() {
        let rate = 11_025.0
        let delay: Int64 = 1_200
        let tx = MRCEAudioProgram(message: "E", wpm: 20, frequency: 700,
                                  level: MRCEAudioProgram.sourceStationAmplitude(uShaped: 0)
                                      * MRCEAudioProgram.sourceMonitorGain(decibels: -60),
                                  sampleRate: rate, startDelaySamples: delay, channel: .transmit)
        let rx = MRCEAudioProgram(message: "T T T T", wpm: 20, frequency: 650,
                                  level: 27_000, sampleRate: rate, channel: .receive)

        func render(includeTX: Bool, includeRX: Bool, qsk: Bool) -> [Float] {
            let count = 5_000
            let programs = (includeTX ? [tx] : []) + (includeRX ? [rx] : [])
            let slots = programs.map { program in program.withView { Optional($0) } }
            var heads = Array(repeating: Int64(0), count: slots.count)
            var output = [Float](repeating: 0, count: count)
            var renderer = MRCEAudioRenderer(sampleRate: rate, center: 650, bandwidth: 500, seed: 23)
            output.withUnsafeMutableBufferPointer { out in
                slots.withUnsafeBufferPointer { programs in
                    heads.withUnsafeMutableBufferPointer { playheads in
                        renderer.process(out, programs: programs, playheads: playheads, qsk: qsk)
                    }
                }
            }
            return output
        }

        XCTAssertEqual(tx.events.first?.level, 0, "The scheduled self-monitor program must carry exact zero gain")
        let scheduledTXOnly = render(includeTX: true, includeRX: false, qsk: true)
        let qskWithScheduledTX = render(includeTX: true, includeRX: true, qsk: true)
        XCTAssertNotEqual(qskWithScheduledTX, scheduledTXOnly,
                      "QSK must keep receive audio audible alongside the silent scheduled TX")
        XCTAssertEqual(render(includeTX: true, includeRX: true, qsk: false),
                       render(includeTX: true, includeRX: false, qsk: false),
                       "A scheduled zero-monitor TX must still mask RX when QSK is disabled")
    }

    func testQSBAndQRNAreSeededAndChunkInvariant() {
        var effects = Effects(); effects.qsb = true; effects.flutter = true; effects.qrn = true
        let a = render(chunks: [12_000], effects: effects)
        let b = render(chunks: [333, 2048, 512, 4096, 5011], effects: effects)
        let repeatSeed = render(chunks: [12_000], effects: effects)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, repeatSeed)
        XCTAssertTrue(a.contains(where: { $0 != 0 }))
    }

    func testQSBAndFlutterFadeReceivedStationsButNotOwnTransmitSidetone() {
        func render(channel: MRCEAudioChannel, effects: Effects) -> [Float] {
            let rate = 11_025.0
            let program = MRCEAudioProgram(message: "EEEE EEEE EEEE EEEE EEEE", wpm: 25,
                                           frequency: 700, level: 27_000,
                                           sampleRate: rate, channel: channel)
            return program.withView { view in
                let slots: [MRCEAudioProgramView?] = [view]
                var heads: [Int64] = [0]
                var renderer = MRCEAudioRenderer(sampleRate: rate, center: 650,
                                                 bandwidth: 250, seed: 0x51DB)
                var output = [Float](repeating: 0, count: 12_000)
                output.withUnsafeMutableBufferPointer { out in
                    slots.withUnsafeBufferPointer { slotBuffer in
                        heads.withUnsafeMutableBufferPointer { headBuffer in
                            renderer.process(out, programs: slotBuffer, playheads: headBuffer,
                                             effects: effects)
                        }
                    }
                }
                return output
            }
        }

        let clean = Effects()
        var fading = Effects()
        fading.qsb = true
        fading.flutter = true

        let txWithoutFading = render(channel: .transmit, effects: clean)
        let txWithFadingEnabled = render(channel: .transmit, effects: fading)
        XCTAssertEqual(txWithFadingEnabled, txWithoutFading,
                       "own sidetone should bypass propagation fading; equal seed also holds filter and AGC history constant")

        let rxWithoutFading = render(channel: .receive, effects: clean)
        let rxWithFadingEnabled = render(channel: .receive, effects: fading)
        XCTAssertNotEqual(rxWithFadingEnabled, rxWithoutFading,
                          "received stations should retain QSB/flutter propagation fading")
    }

    func testSidetoneStaysAtSelectedPitchAndLevelWhateverRITAndBandwidth() {
        let rate = 11_025.0, pitch = 450.0
        var levels: [Int: [Double]] = [:]
        for bandwidth in [550, 300, 150] {
            for rit in [0.0, 100, 200, -200] {
                let program = MRCEAudioProgram(message: "T", wpm: 5, frequency: pitch,
                                               level: 27_000, sampleRate: rate, channel: .transmit)
                program.withView { view in
                    let slots: [MRCEAudioProgramView?] = [view]
                    var heads: [Int64] = [0]
                    var renderer = MRCEAudioRenderer(sampleRate: rate, center: pitch + rit,
                                                     bandwidth: bandwidth, seed: 9)
                    renderer.configure(center: pitch + rit, bandwidth: bandwidth, outputPitch: pitch)
                    var output = [Float](repeating: 0, count: 9_000)
                    output.withUnsafeMutableBufferPointer { out in
                        slots.withUnsafeBufferPointer { s in
                            heads.withUnsafeMutableBufferPointer { h in
                                renderer.process(out, programs: s, playheads: h)
                            }
                        }
                    }
                    let dash = output[3_000..<6_000]
                    var crossings = 0, previous: Float = 0
                    for x in dash { if previous < 0 && x >= 0 { crossings += 1 }; previous = x }
                    let frequency = Double(crossings) * rate / Double(dash.count)
                    let rms = sqrt(dash.reduce(0.0) { $0 + Double($1 * $1) } / Double(dash.count))
                    XCTAssertEqual(frequency, pitch, accuracy: 12, "bandwidth \(bandwidth) rit \(rit)")
                    XCTAssertGreaterThan(rms, 0.1, "bandwidth \(bandwidth) rit \(rit)")
                    levels[bandwidth, default: []].append(rms)
                }
            }
        }
        for (bandwidth, values) in levels {
            XCTAssertLessThan((values.max() ?? 0) - (values.min() ?? 0), 0.01 * (values.max() ?? 1),
                              "sidetone level must not depend on RIT at bandwidth \(bandwidth)")
        }
    }

    /// Renders consecutive programs through one slot of one renderer and returns
    /// the slot's QSB cutoff after each program.
    private func qsbCutoffs(ids: [Int], channel: MRCEAudioChannel = .receive, effects: Effects) -> [Double] {
        let rate = 11_025.0
        var renderer = MRCEAudioRenderer(sampleRate: rate, center: 650, bandwidth: 250,
                                         stationCapacity: 1, seed: 0x77)
        var result: [Double] = []
        for id in ids {
            let program = MRCEAudioProgram(message: "EE", wpm: 25, frequency: 650, level: 27_000,
                                           sampleRate: rate, channel: channel, stationID: id)
            program.withView { view in
                let slots: [MRCEAudioProgramView?] = [view]
                var heads: [Int64] = [0]
                var output = [Float](repeating: 0, count: 2_000)
                output.withUnsafeMutableBufferPointer { out in
                    slots.withUnsafeBufferPointer { s in
                        heads.withUnsafeMutableBufferPointer { h in
                            renderer.process(out, programs: s, playheads: h, effects: effects)
                        }
                    }
                }
                // An idle block lets the slot see the program end.
                var idle = [Float](repeating: 0, count: 64)
                let none: [MRCEAudioProgramView?] = [nil]
                var zero: [Int64] = [0]
                idle.withUnsafeMutableBufferPointer { out in
                    none.withUnsafeBufferPointer { s in
                        zero.withUnsafeMutableBufferPointer { h in
                            renderer.process(out, programs: s, playheads: h, effects: effects)
                        }
                    }
                }
            }
            result.append(renderer.qsbCutoffProbe(slot: 0))
        }
        return result
    }

    func testQSBCutoffBelongsToStationNotAudioSlot() {
        var qsb = Effects(); qsb.qsb = true
        let cutoffs = qsbCutoffs(ids: [5, 5, 6, 5, 7, 8, 9, 10], effects: qsb)
        XCTAssertEqual(cutoffs[0], cutoffs[1])
        XCTAssertNotEqual(cutoffs[1], cutoffs[2])
        XCTAssertEqual(cutoffs[0], cutoffs[3], "station 5 keeps one cutoff for its lifetime")
        XCTAssertGreaterThan(Set(cutoffs).count, 4, "new stations get fresh draws")
        XCTAssertTrue(cutoffs.allSatisfy { $0 >= 0.1 })
    }

    func testFlutterAloneDoesNotFadeAndNewStationsHonourCurrentFlutter() {
        var flutterOnly = Effects(); flutterOnly.flutter = true
        XCTAssertTrue(qsbCutoffs(ids: [1, 2], effects: flutterOnly).allSatisfy { $0 == 0 },
                      "Flutter without QSB must not start fading")
        var both = Effects(); both.qsb = true; both.flutter = true
        XCTAssertTrue(qsbCutoffs(ids: Array(1...60), effects: both).contains { $0 > 3 },
                      "Flutter should let some stations draw 3-33 Hz")
        var qsbOnly = Effects(); qsbOnly.qsb = true
        XCTAssertTrue(qsbCutoffs(ids: Array(1...60), effects: qsbOnly).allSatisfy { $0 <= 0.6 })
    }

    func testInterferenceAndTransmitChannelsDoNotFade() {
        var both = Effects(); both.qsb = true; both.flutter = true
        XCTAssertEqual(qsbCutoffs(ids: [1, 2], channel: .interference, effects: both), [0, 0])
        XCTAssertEqual(qsbCutoffs(ids: [1, 2], channel: .transmit, effects: both), [0, 0])
    }

    func testShortStationEndsWhileLongStationContinues() {
        let rate = 11_025.0
        let first = MRCEAudioProgram(message: "E", wpm: 20, frequency: 650, level: 27_000, sampleRate: rate)
        let second = MRCEAudioProgram(message: "T", wpm: 20, frequency: 900, level: 27_000, sampleRate: rate)
        first.withView { a in second.withView { b in
            var slots: [MRCEAudioProgramView?] = [a, b]
            var heads: [Int64] = [0, 0]
            var renderer = MRCEAudioRenderer(sampleRate: rate, center: 700, bandwidth: 500, seed: 91)
            // Advance past the short dit and into the longer dash.
            var before = [Float](repeating: 0, count: 1_000)
            before.withUnsafeMutableBufferPointer { out in
                slots.withUnsafeBufferPointer { s in heads.withUnsafeMutableBufferPointer { h in renderer.process(out, programs: s, playheads: h) } }
            }
            slots[0] = nil
            var after = [Float](repeating: 0, count: 512)
            after.withUnsafeMutableBufferPointer { out in
                slots.withUnsafeBufferPointer { s in heads.withUnsafeMutableBufferPointer { h in renderer.process(out, programs: s, playheads: h) } }
            }
            XCTAssertTrue(after.contains(where: { abs($0) > 0.000001 }), "the second station should remain keyed after the first station ends")
        } }
    }

    func testSourceStationAmplitudeUsesMRCEUnits() {
        XCTAssertEqual(MRCEAudioProgram.sourceStationAmplitude(uShaped: -1), 9_000)
        XCTAssertEqual(MRCEAudioProgram.sourceStationAmplitude(uShaped: 0), 27_000)
        XCTAssertEqual(MRCEAudioProgram.sourceStationAmplitude(uShaped: 1), 45_000)
        XCTAssertEqual(MRCEAudioProgram.sourceStationAmplitude(uShaped: 2), 45_000)
    }

    func testQSBChoosesNormalAndFlutterBandwidthsAtExpectedRates() {
        var normal = 0, flutter = 0
        for seed in 1...10_000 {
            let cutoff = MRCEAudioRenderer.qsbCutoffDraw(seed: UInt32(seed), flutter: true)
            if cutoff >= 3 { flutter += 1 }
            else { normal += 1; XCTAssertTrue((0.1...0.6).contains(cutoff)) }
        }
        XCTAssertEqual(normal + flutter, 10_000)
        XCTAssertTrue((2_800...3_200).contains(flutter), "flutter selection should be about 30%")
        let normalOnly = (1...10_000).map { MRCEAudioRenderer.qsbCutoffDraw(seed: UInt32($0), flutter: false) }
        XCTAssertTrue(normalOnly.allSatisfy { (0.1...0.6).contains($0) })
    }

    func testQRNEventCadenceDurationsAndAmplitudeRanges() {
        let rate = 11_025.0, samples = 1_000_000
        var source = MRCEAudioQRNState(seed: 0x5120_1102, sampleRate: rate)
        var impulses = 0, bursts = 0, burstImpulses = 0, durationTotal = 0
        var minimumAmplitude = Double.infinity, maximumAmplitude = 0.0, logAmplitudeTotal = 0.0
        for _ in 0..<samples {
            let event = source.sample(sampleRate: rate)
            if event.impulse { impulses += 1 }
            if event.burstImpulse { burstImpulses += 1 }
            if event.burstStarted {
                bursts += 1
                XCTAssertTrue((0...11_264).contains(event.burstDuration))
                XCTAssertEqual(event.burstDuration % 512, 0,
                               "QrnStn envelopes are rounded to the source 512-sample block")
                XCTAssertTrue((100_000...10_000_000).contains(event.burstAmplitude))
                durationTotal += event.burstDuration
                minimumAmplitude = min(minimumAmplitude, event.burstAmplitude)
                maximumAmplitude = max(maximumAmplitude, event.burstAmplitude)
                logAmplitudeTotal += log10(event.burstAmplitude)
            }
        }
        XCTAssertTrue((9_500...10_500).contains(impulses), "per-sample impulse probability should be 0.01")
        XCTAssertTrue((8...32).contains(bursts), "burst arrival probability should be 0.01 per 512 reference samples")
        let averageDuration = Double(durationTotal) / Double(bursts)
        XCTAssertTrue((4_000...7_000).contains(Int(averageDuration)), "burst duration should be uniform over about one second")
        XCTAssertLessThan(minimumAmplitude, 1_000_000)
        XCTAssertGreaterThan(maximumAmplitude, 1_000_000)
        let geometricMeanAmplitude = pow(10, logAmplitudeTotal / Double(bursts))
        // Only about 20 bursts are expected in this deterministic million-
        // sample run, so use a broad range around the 1e6 geometric mean.
        XCTAssertTrue((500_000...1_500_000).contains(Int(geometricMeanAmplitude)))
        XCTAssertTrue((700...1_500).contains(burstImpulses),
                      "QrnStn envelopes are sparse: only about 1% of active burst samples are nonzero")
    }

    func testQRNBackgroundImpulseReplacesBaselineRealNoise() {
        var rng: UInt32 = 47
        func draw() -> Double {
            rng = rng &* 1_664_525 &+ 1_013_904_223
            return Double(rng >> 8) / 16_777_216
        }
        let baselineReal = 18_000 * (draw() - 0.5)
        let baselineImaginary = 18_000 * (draw() - 0.5)
        let isImpulse = draw() < 0.01
        let impulseReal = 360_000 * (draw() - 0.5)
        let burstStart = draw() < (1 - pow(1 - 0.01 / 512, 1))
        XCTAssertTrue(isImpulse)
        XCTAssertFalse(burstStart)

        var source = MRCEAudioQRNState(seed: 47, sampleRate: 11_025)
        let sample = source.sample(sampleRate: 11_025)
        XCTAssertTrue(sample.impulse)
        XCTAssertEqual(sample.real, impulseReal, accuracy: 0.000_001)
        XCTAssertEqual(sample.imaginary, baselineImaginary, accuracy: 0.000_001)
        XCTAssertNotEqual(sample.real, baselineReal + impulseReal,
                          "the QRN background spark replaces Re instead of adding to it")
    }

    func testDisablingQRNClearsActiveBurstStationsImmediately() {
        var source = MRCEAudioQRNState(seed: 47, sampleRate: 11_025)
        var started = false
        for _ in 0..<1_000_000 where !started {
            started = source.sample(sampleRate: 11_025, qrnEnabled: true).burstStarted
        }
        XCTAssertTrue(started, "fixture seed should start at least one burst")
        for _ in 0..<2_000 {
            let sample = source.sample(sampleRate: 11_025, qrnEnabled: false)
            XCTAssertFalse(sample.burstImpulse, "QRN-off must immediately suppress active burst impulses")
            XCTAssertLessThanOrEqual(abs(sample.real), 9_000,
                                     "QRN-off retains the baseline noise bed without transient energy")
            XCTAssertLessThanOrEqual(abs(sample.imaginary), 9_000)
        }
    }

    func testQRNOutputStaysBoundedWithoutSustainedClipping() {
        let rate = 11_025.0, count = 120_000
        let slots: [MRCEAudioProgramView?] = [nil]
        var heads: [Int64] = [0]
        var renderer = MRCEAudioRenderer(sampleRate: rate, center: 700, bandwidth: 250, seed: 47)
        var effects = Effects(); effects.qrn = true
        var output = [Float](repeating: 0, count: count)
        output.withUnsafeMutableBufferPointer { out in
            slots.withUnsafeBufferPointer { s in
                heads.withUnsafeMutableBufferPointer { h in
                    renderer.process(out, programs: s, playheads: h, effects: effects)
                }
            }
        }
        let clipped = output.filter { abs($0) >= 0.98 }.count
        let rms = sqrt(output.reduce(0.0) { $0 + Double($1 * $1) } / Double(count))
        XCTAssertLessThanOrEqual(output.map(abs).max() ?? 0, 0.98)
        XCTAssertLessThan(clipped, count / 100, "QRN should not hold the receiver at its output clamp")
        XCTAssertGreaterThan(rms, 0.01)
    }

    func testBasebandNoiseIsPresentWithoutQRNAndTransientsStayOptional() {
        let rate = 11_025.0, count = 120_000
        func render(qrn: Bool) -> [Float] {
            var effects = Effects(); effects.qrn = qrn
            let slots: [MRCEAudioProgramView?] = [nil]
            var heads: [Int64] = [0]
            var renderer = MRCEAudioRenderer(sampleRate: rate, center: 700, bandwidth: 250, seed: 47)
            var output = [Float](repeating: 0, count: count)
            output.withUnsafeMutableBufferPointer { out in
                slots.withUnsafeBufferPointer { s in
                    heads.withUnsafeMutableBufferPointer { h in
                        renderer.process(out, programs: s, playheads: h, effects: effects)
                    }
                }
            }
            return output
        }
        let base = render(qrn: false), withQRN = render(qrn: true)
        func rms(_ samples: [Float]) -> Double {
            sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        }
        XCTAssertGreaterThan(rms(base), 0.01, "MRCE's ±9,000 complex receiver noise is present with every optional effect off")
        XCTAssertGreaterThan(rms(withQRN), rms(base), "QRN impulses and bursts add to the radio-noise bed")

        var baseline = MRCEAudioQRNState(seed: 221, sampleRate: rate)
        var baselineSamples = [MRCEAudioQRNSample]()
        for _ in 0..<20_000 { baselineSamples.append(baseline.sample(sampleRate: rate, qrnEnabled: false)) }
        XCTAssertTrue(baselineSamples.allSatisfy { !$0.impulse && !$0.burstStarted })
        XCTAssertTrue(baselineSamples.allSatisfy { abs($0.real) <= 9_000 && abs($0.imaginary) <= 9_000 })
        let sourceRMS = sqrt(baselineSamples.reduce(0.0) { $0 + $1.real * $1.real } / Double(baselineSamples.count))
        XCTAssertTrue((5_000...5_500).contains(Int(sourceRMS)))
    }

    func testOrdinaryStationKeyUpReleasesSmoothlyAndIsChunkInvariant() {
        func render(releaseChunks: [Int]) -> [Float] {
            var renderer = MRCEAudioRenderer(sampleRate: 11_025, center: 700, bandwidth: 500, seed: 123)
            var station = MRCEAudioStation(frequency: 700, level: 16_384, key: 1)
            var output = [Float](repeating: 0, count: 1_000 + releaseChunks.reduce(0, +))
            var offset = 0
            output.withUnsafeMutableBufferPointer { whole in
                let keyed = UnsafeMutableBufferPointer(start: whole.baseAddress!, count: 1_000)
                renderer.process(keyed, stations: [station])
                offset = 1_000
                station.key = 0
                for size in releaseChunks {
                    let part = UnsafeMutableBufferPointer(start: whole.baseAddress!.advanced(by: offset), count: size)
                    renderer.process(part, stations: [station])
                    offset += size
                }
            }
            return output
        }
        let oneChunk = render(releaseChunks: [1_000])
        let partitioned = render(releaseChunks: [1, 17, 512, 470])
        XCTAssertEqual(oneChunk, partitioned)
        let release = Array(oneChunk.dropFirst(1_000))
        let firstRMS = sqrt(release.prefix(100).reduce(0.0) { $0 + Double($1 * $1) } / 100)
        let lastRMS = sqrt(release.suffix(100).reduce(0.0) { $0 + Double($1 * $1) } / 100)
        XCTAssertTrue(release.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(firstRMS, lastRMS * 2, "key-up should follow the ordinary 13.5 ms envelope instead of cutting the carrier")
    }

    func testTXQSKModesUseTheSameFilteredAGCTransmitPath() {
        let rate = 11_025.0, count = 6_000
        let tx = MRCEAudioProgram(message: "E", wpm: 20, frequency: 700, level: 16_384,
                                  sampleRate: rate, channel: .transmit)
        let rx = MRCEAudioProgram(message: "T", wpm: 20, frequency: 650, level: 27_000,
                                  sampleRate: rate, channel: .receive)
        func render(includeRX: Bool, qsk: Bool) -> [Float] {
            var output = [Float](repeating: 0, count: count)
            func run(_ txView: MRCEAudioProgramView, _ rxView: MRCEAudioProgramView?) {
                let slots: [MRCEAudioProgramView?] = rxView.map { [txView, $0] } ?? [txView]
                var heads = [Int64](repeating: 0, count: slots.count)
                var renderer = MRCEAudioRenderer(sampleRate: rate, center: 650, bandwidth: 500, stationCapacity: 2, seed: 2)
                output.withUnsafeMutableBufferPointer { out in
                    slots.withUnsafeBufferPointer { s in
                        heads.withUnsafeMutableBufferPointer { h in
                            renderer.process(out, programs: s, playheads: h, qsk: qsk)
                        }
                    }
                }
            }
            if includeRX {
                tx.withView { txView in rx.withView { rxView in run(txView, rxView) } }
            } else { tx.withView { run($0, nil) } }
            return output
        }
        let txOnly = render(includeRX: false, qsk: false)
        XCTAssertEqual(txOnly, render(includeRX: true, qsk: false),
                       "with QSK disabled, active TX replaces the RX mix")
        XCTAssertNotEqual(txOnly, render(includeRX: true, qsk: true),
                          "QSK keeps the attenuated RX mix on the shared TX filter/modulator/AGC path")
    }

    func testQRNSchedulerAdvancesWhileNonQSKTransmitMasksReceiver() {
        let rate = 11_025.0
        let tx = MRCEAudioProgram(message: "E", wpm: 20, frequency: 700, level: 16_384,
                                  sampleRate: rate, channel: .transmit)
        tx.withView { view in
            let txSlots: [MRCEAudioProgramView?] = [view]
            let silenceSlots: [MRCEAudioProgramView?] = [nil]
            var txHeads: [Int64] = [0], silenceHeads: [Int64] = [0]
            var transmitting = MRCEAudioRenderer(sampleRate: rate, center: 700, bandwidth: 250, seed: 47)
            var receivingSilence = MRCEAudioRenderer(sampleRate: rate, center: 700, bandwidth: 250, seed: 47)
            var effects = Effects(); effects.qrn = true
            var masked = [Float](repeating: 0, count: Int(view.sampleCount))
            var reference = [Float](repeating: 0, count: Int(view.sampleCount))
            masked.withUnsafeMutableBufferPointer { out in
                txSlots.withUnsafeBufferPointer { slots in
                    txHeads.withUnsafeMutableBufferPointer { heads in
                        transmitting.process(out, programs: slots, playheads: heads, effects: effects, qsk: false)
                    }
                }
            }
            reference.withUnsafeMutableBufferPointer { out in
                silenceSlots.withUnsafeBufferPointer { slots in
                    silenceHeads.withUnsafeMutableBufferPointer { heads in
                        receivingSilence.process(out, programs: slots, playheads: heads, effects: effects, qsk: false)
                    }
                }
            }
            let flushCount = 1_200, captureCount = 2_048
            var afterTX = [Float](repeating: 0, count: flushCount + captureCount)
            var afterSilence = [Float](repeating: 0, count: flushCount + captureCount)
            afterTX.withUnsafeMutableBufferPointer { out in
                silenceSlots.withUnsafeBufferPointer { slots in
                    silenceHeads.withUnsafeMutableBufferPointer { heads in
                        transmitting.process(out, programs: slots, playheads: heads, effects: effects, qsk: false)
                    }
                }
            }
            afterSilence.withUnsafeMutableBufferPointer { out in
                silenceSlots.withUnsafeBufferPointer { slots in
                    silenceHeads.withUnsafeMutableBufferPointer { heads in
                        receivingSilence.process(out, programs: slots, playheads: heads, effects: effects, qsk: false)
                    }
                }
            }
            XCTAssertEqual(Array(afterTX.dropFirst(flushCount)), Array(afterSilence.dropFirst(flushCount)),
                           "after filter and AGC history flush, QRN samples must align across masked non-QSK TX")
        }
    }

    func testMRCEParallelFilterDCImpulseAndBandwidthResponse() {
        let rate = 11_025.0
        for bandwidth in [250, 500, 1_000] {
            var dc = MRCEAudioRenderer(sampleRate: rate, center: 700, bandwidth: bandwidth)
            var result = (0.0, 0.0)
            for _ in 0..<600 { result = dc.filterComplex(100, -50) }
            let gain = sqrt(500 / Double(bandwidth))
            XCTAssertEqual(result.0, 100 * gain, accuracy: 0.000_001)
            XCTAssertEqual(result.1, -50 * gain, accuracy: 0.000_001)

            var impulse = MRCEAudioRenderer(sampleRate: rate, center: 700, bandwidth: bandwidth)
            var area = 0.0, last = (0.0, 0.0)
            for sample in 0..<512 {
                last = impulse.filterComplex(sample == 0 ? 100 : 0, 0)
                area += last.0
            }
            XCTAssertEqual(area, 100 * gain, accuracy: 0.000_01,
                           "three normalized moving averages preserve impulse area")
            XCTAssertEqual(last.0, 0, accuracy: 0.000_001)
        }

        func response(bandwidth: Int, frequency: Double) -> Double {
            var renderer = MRCEAudioRenderer(sampleRate: rate, center: 700, bandwidth: bandwidth)
            var recent = [Double]()
            for sample in 0..<1_000 {
                let phase = 2 * .pi * frequency * Double(sample) / rate
                let out = renderer.filterComplex(cos(phase), sin(phase))
                if sample >= 900 { recent.append(hypot(out.0, out.1)) }
            }
            return recent.reduce(0, +) / Double(recent.count)
        }
        XCTAssertGreaterThan(response(bandwidth: 500, frequency: 450),
                             response(bandwidth: 250, frequency: 450) * 10,
                             "the selected bandwidth controls Filt's three pass low-pass response")
    }

    func testFilterBankSwapsDoNotChangeSelectedBandwidth() {
        let rate = 11_025.0, bandwidth = 500
        var renderer = MRCEAudioRenderer(sampleRate: rate, center: 700, bandwidth: bandwidth)
        let period = 10 * 512
        func input(_ sample: Int) -> (Double, Double) {
            let phase = 2 * .pi * 450 * Double(sample) / rate
            return (cos(phase), sin(phase))
        }
        var beforeFirst = 0.0, afterFirst = 0.0, beforeSecond = 0.0, afterSecond = 0.0
        for sample in 0..<(2 * period + 1) {
            let pair = input(sample)
            let output = renderer.filterComplex(pair.0, pair.1)
            let magnitude = hypot(output.0, output.1)
            if sample == period - 1 { beforeFirst = magnitude }
            if sample == period { afterFirst = magnitude }
            if sample == 2 * period - 1 { beforeSecond = magnitude }
            if sample == 2 * period { afterSecond = magnitude }
        }
        XCTAssertGreaterThan(beforeFirst, 0.05)
        XCTAssertEqual(afterFirst / beforeFirst, 1, accuracy: 0.08,
                       "the reference's 10-block state swap must not alternate the audible receiver bandwidth")
        XCTAssertEqual(afterSecond / beforeSecond, 1, accuracy: 0.08)
    }

    func testColdQRNOffNoiseDoesNotPumpAtFilterSwapBoundaries() {
        let blockSize = 512, blockCount = 32
        let slots: [MRCEAudioProgramView?] = [nil]
        var heads: [Int64] = [0]
        var renderer = MRCEAudioRenderer(sampleRate: 11_025, center: 600, bandwidth: 500, seed: 47)
        var output = [Float](repeating: 0, count: blockSize * blockCount)
        output.withUnsafeMutableBufferPointer { out in
            slots.withUnsafeBufferPointer { s in
                heads.withUnsafeMutableBufferPointer { h in
                    for block in 0..<blockCount {
                        let start = block * blockSize
                        let part = UnsafeMutableBufferPointer(start: out.baseAddress!.advanced(by: start), count: blockSize)
                        renderer.process(part, programs: s, playheads: h, effects: Effects())
                    }
                }
            }
        }
        func rms(_ block: Int) -> Double {
            let samples = output[(block * blockSize)..<((block + 1) * blockSize)]
            return sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(blockSize))
        }
        for boundary in [10, 20, 30] {
            let before = rms(boundary - 1), after = rms(boundary)
            XCTAssertTrue((0.65...1.55).contains(after / before),
                          "QRN-off baseline hiss should stay stationary across the 10-block swap at block \(boundary)")
        }
    }
}

final class AudioProgramStartTests: XCTestCase {
    /// A program picked up one render quantum late must not lose the start of
    /// its first element; lead-in silence is still skipped to stay on time.
    func testLatePickUpNeverCutsIntoTheFirstElement() {
        let immediate = MRCEAudioProgram(message: "E", wpm: 30, frequency: 600, sampleRate: 11_025)
        immediate.withView { view in
            XCTAssertEqual(view.startPlayhead(elapsed: 0), 0)
            XCTAssertEqual(view.startPlayhead(elapsed: 235), 0)
            XCTAssertEqual(view.startPlayhead(elapsed: -5), 0)
        }
        let delayed = MRCEAudioProgram(message: "E", wpm: 30, frequency: 600, sampleRate: 11_025, startDelaySamples: 1000)
        delayed.withView { view in
            XCTAssertEqual(view.startPlayhead(elapsed: 235), 235)
            XCTAssertEqual(view.startPlayhead(elapsed: 5000), 1000)
        }
    }
}
