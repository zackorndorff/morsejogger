//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import Foundation

/// Exact weighted maximum with block upper bounds. Attack weights are nonpositive,
/// so a block whose unweighted maximum cannot beat the envelope needs no scan.
/// Storage is allocated at initialization and remains fixed on the audio thread.
struct MRCEAGCEnvelope: Sendable {
    private let blockSize = 16
    private let weights: [Double]
    private var magnitudes: [Double]
    private var maxima: [Double]
    private var head = 0

    init(weights: [Double]) {
        precondition(!weights.isEmpty && weights.allSatisfy { $0 <= 0 })
        self.weights = weights
        magnitudes = [Double](repeating: 0, count: weights.count)
        maxima = [Double](repeating: 0, count: (weights.count + 15) / 16)
    }

    mutating func push(_ magnitude: Double) -> Double {
        let count = magnitudes.count
        magnitudes[head] = magnitude
        let changedBlock = head / blockSize
        let start = changedBlock * blockSize
        var maximum = -Double.infinity
        for i in start..<min(start + blockSize, count) {
            maximum = max(maximum, magnitudes[i])
        }
        maxima[changedBlock] = maximum
        head += 1
        if head == count { head = 0 }

        var envelope = 1e-10
        // Preserve chronological order and the original weight/sample pairing
        // across the ring wrap, including the split block containing the head.
        for pass in 0..<2 {
            let range = pass == 0 ? head..<count : 0..<head
            var index = range.lowerBound
            while index < range.upperBound {
                let block = index / blockSize
                let end = min((block + 1) * blockSize, range.upperBound)
                if maxima[block] > envelope {
                    for i in index..<end {
                        let weightIndex = i >= head ? i - head : i + count - head
                        envelope = max(envelope, magnitudes[i] + weights[weightIndex])
                    }
                }
                index = end
            }
        }
        return envelope
    }
}

struct MRCEAudioQRNSample: Sendable {
    let real: Double, imaginary: Double
    let impulse: Bool, burstStarted: Bool, burstImpulse: Bool
    let burstDuration: Int, burstAmplitude: Double
}

/// Render-owned source of the original QRN events; exposed internally so tests
/// can validate event statistics without the receiver AGC masking amplitudes.
struct MRCEAudioQRNState: Sendable {
    private struct Burst: Sendable {
        var samplesLeft = 0
        var amplitude = 0.0
    }
    private var rng: UInt32
    private let burstBlockSamples: Int
    private var burstBlockPosition = 0
    private var bursts = [Burst](repeating: Burst(), count: 64)
    init(seed: UInt32, sampleRate: Double = 11_025) {
        rng = seed == 0 ? 0x25C0_FFEE : seed
        burstBlockSamples = max(1, Int((512 * sampleRate / 11_025).rounded()))
    }
    private mutating func uniform() -> Double {
        rng = rng &* 1_664_525 &+ 1_013_904_223
        return Double(rng >> 8) / 16_777_216
    }
    mutating func sample(sampleRate: Double, qrnEnabled: Bool = true) -> MRCEAudioQRNSample {
        if !qrnEnabled {
            // Disabling QRN must remove any already-running static stations as
            // well as prevent new ones. The receiver's ordinary noise bed is
            // still generated below.
            for i in bursts.indices { bursts[i] = Burst() }
        }
        var real = 18_000 * (uniform() - 0.5), imaginary = 18_000 * (uniform() - 0.5)
        let impulse = qrnEnabled && uniform() < 0.01
        // Contest.GetAudio replaces the real-channel noise sample when its
        // QRN background draw fires; it does not add the impulse to it.
        if impulse { real = 360_000 * (uniform() - 0.5) }
        var burstReal = 0.0, burstImpulse = false
        for i in bursts.indices where bursts[i].samplesLeft > 0 {
            if uniform() < 0.01 {
                burstReal += (uniform() - 0.5) * bursts[i].amplitude
                burstImpulse = true
            }
            bursts[i].samplesLeft -= 1
        }
        // Contest.GetAudio considers exactly one new burst per 512-sample
        // block, after mixing that block; rate-scale the block for other SRs.
        burstBlockPosition += 1
        var started = false, duration = 0, startedAmplitude = 0.0
        if burstBlockPosition >= burstBlockSamples {
            burstBlockPosition = 0
            if qrnEnabled && uniform() < 0.01,
               let slot = bursts.firstIndex(where: { $0.samplesLeft == 0 }) {
                let blocks = Int((Double(11_025) / 512 * uniform()).rounded())
                duration = blocks * burstBlockSamples
                startedAmplitude = 1e5 * pow(10, 2 * uniform())
                bursts[slot] = Burst(samplesLeft: duration, amplitude: startedAmplitude)
                started = true
            }
        }
        return MRCEAudioQRNSample(real: real + burstReal,
                                  imaginary: imaginary,
                                  impulse: impulse, burstStarted: started, burstImpulse: burstImpulse,
                                  burstDuration: duration, burstAmplitude: startedAmplitude)
    }
}

/// A precompiled key mark on the renderer's sample clock.
public struct MRCEAudioMarkEvent: Sendable, Equatable {
    public let sampleOffset: Int64
    public let duration: Int64
    public let frequency: Double
    public let level: Float
    public init(sampleOffset: Int64, duration: Int64, frequency: Double, level: Float = 1) {
        self.sampleOffset = sampleOffset; self.duration = max(1, duration)
        self.frequency = frequency; self.level = level
    }
}

/// Immutable Morse timeline prepared on a control thread. Event storage can be
/// borrowed through `withUnsafeBufferPointer` by a preallocated audio transport.
public enum MRCEAudioChannel: Sendable { case receive, transmit, interference }
/// Trivial, non-owning descriptor for callback use. Its event pointer remains
/// valid for the lifetime of the originating program, which the host must retain
/// until the render side acknowledges retirement of that slot.
public struct MRCEAudioProgramView: @unchecked Sendable {
    public let events: UnsafeBufferPointer<MRCEAudioMarkEvent>
    public let sampleCount: Int64
    public let channel: MRCEAudioChannel
    public let stationID: Int

    /// Where playback starts when the renderer picks the program up
    /// `elapsed` samples after it was scheduled. Time already owed is skipped
    /// only up to the first keyed element, so a late pick-up delays the
    /// message slightly instead of cutting into its first dit or dah.
    public func startPlayhead(elapsed: Int64) -> Int64 {
        let lead = events.first.map { max(0, $0.sampleOffset) } ?? sampleCount
        return min(max(0, elapsed), lead)
    }
}
private final class MRCEAudioEventStorage: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<MRCEAudioMarkEvent>
    let count: Int
    init(_ events: [MRCEAudioMarkEvent]) {
        count = events.count
        pointer = .allocate(capacity: max(1, events.count))
        if !events.isEmpty { pointer.initialize(from: events, count: events.count) }
    }
    deinit {
        if count > 0 { pointer.deinitialize(count: count) }
        pointer.deallocate()
    }
}
public final class MRCEAudioProgram: @unchecked Sendable {
    public let events: [MRCEAudioMarkEvent]
    public let sampleCount: Int64
    public let channel: MRCEAudioChannel
    public let stationID: Int
    private let storage: MRCEAudioEventStorage
    /// Exact MRCE station level law. `uShaped` is the simulator's deterministic
    /// draw in [-1,1]; the resulting RF amplitude is 9,000...45,000.
    public static func sourceStationAmplitude(uShaped: Float) -> Float {
        let value = min(1, max(-1, uShaped))
        return 9_000 + 18_000 * (1 + value)
    }

    /// MRCE's self-monitor attenuation curve for a slider value in dB.
    /// The ordinary amplitude law is linear in dB, with MRCE's extra linear
    /// taper from -57 dB to exact silence at -60 dB.
    public static func sourceMonitorGain(decibels: Int) -> Float {
        let decibels = min(0, max(-60, decibels))
        guard decibels > -60 else { return 0 }
        let gain = pow(10.0, Double(decibels) / 20.0)
        guard decibels < -57 else { return Float(gain) }
        let sliderValue = Double(decibels + 60) / 60.0
        return Float(gain * sliderValue * 60.0)
    }

    /// Level of the operator's own sidetone ahead of the receiver filter and
    /// AGC. MRCE writes `gain x 300000` into both halves of the complex mix
    /// (`MyStn.Amplitude`, `Contest.GetAudio`), which is root-two times that
    /// on one axis. At 0 dB this drives the AGC to its ceiling, so the
    /// sidetone is louder than any caller (9,000...45,000).
    public static func sourceSidetoneAmplitude(decibels: Int) -> Float {
        Float(300_000 * 2.0.squareRoot()) * sourceMonitorGain(decibels: decibels)
    }

    public func withView<R>(_ body: (MRCEAudioProgramView) throws -> R) rethrows -> R {
        let ptr = UnsafeBufferPointer(start: UnsafePointer(storage.pointer), count: storage.count)
        return try body(MRCEAudioProgramView(events: ptr, sampleCount: sampleCount, channel: channel, stationID: stationID))
    }
    public init(message: String, wpm: Int, characterWpm: Int? = nil,
                frequency: Double, level: Float = 1, sampleRate: Double = 44_100,
                fastReportStart: Int? = nil, fastReportRate: Double = 1, fastReportStarts:[Int]? = nil,
                startDelaySamples: Int64 = 0, channel: MRCEAudioChannel = .receive, stationID: Int = -1,
                farnsworthKeyer: Bool? = nil) {
        let marks = MorseTimeline.marks(message, wpm: wpm, characterWpm: characterWpm,
                                       fastReportStart: fastReportStart, fastReportRate: fastReportRate, fastReportStarts:fastReportStarts,
                                       sampleRate: sampleRate, farnsworthKeyer: farnsworthKeyer)
        events = marks.map { mark in
            MRCEAudioMarkEvent(sampleOffset: startDelaySamples + Int64((mark.start * sampleRate).rounded()),
                               duration: Int64((mark.duration * sampleRate).rounded()),
                               frequency: frequency, level: level)
        }
        storage = MRCEAudioEventStorage(events)
        sampleCount = startDelaySamples + Int64((MorseTimeline.duration(message, wpm: wpm, characterWpm: characterWpm,
                     fastReportStart: fastReportStart, fastReportRate: fastReportRate, fastReportStarts:fastReportStarts,
                     sampleRate: sampleRate, farnsworthKeyer: farnsworthKeyer) * sampleRate).rounded())
        self.channel = channel
        self.stationID = stationID
    }
}

/// One simultaneously transmitting station presented to the streaming RF renderer.
/// `key` is the instantaneous key state (0...1); callers retain mark timing.
public struct MRCEAudioStation: Sendable, Equatable {
    public var frequency: Double
    public var level: Double
    public var key: Float
    public init(frequency: Double, level: Double = 1, key: Float = 1) {
        self.frequency = frequency
        self.level = level
        self.key = min(1, max(0, key))
    }
}

/// Stateful, allocation-free streaming RF model. Construct/configure this off the
/// render thread, then reuse it for successive blocks. Chunk boundaries do not
/// reset oscillator, modulation, receiver, noise, or envelope state.
public struct MRCEAudioRenderer: Sendable {
    private struct StationState: Sendable {
        var phase = 0.0
        var lastKey: Float = 0
        var keyAge = 1.0
        var keyFrom = 0.0
        var keyTo = 0.0
        var keyEnvelope = 0.0
        var markCursor = 0
        var qsb = (0.0, 0.0, 0.0)
        var qsbImag = (0.0, 0.0, 0.0)
        var qsbCutoff = 0.0
        var qsbPoints = 0
        var qsbIndex = 0
        var qsbPrev = 0
        var qsbFrame = 0
        var qsbGain = 1.0
        var qsbNextGain = 1.0
        var flutter = (0.0, 0.0, 0.0)
        var flutterCutoff = 0.0
        var frequency = 0.0
        var channel: MRCEAudioChannel = .receive
        /// Station whose fading character this slot currently carries, and
        /// whether the slot was already running a program on the previous sample.
        var fadeStationID = -1
        var fadeLive = false
        var rng: UInt32
    }
    private let sampleRate: Double
    private var receiver: Double
    private var outputPitch: Double
    private var bandwidth: Double
    private var window: Int
    /// Active point counts can change at runtime, but the ring capacities stay
    /// fixed at the widest supported receiver window to keep retunes allocation-free.
    private var filterPoints: [Int]
    private let riseSamples: Double
    private var rampOn: [Double]
    private var rampOff: [Double]
    private var states: [StationState]
    private var activeSlots: [Int]
    private var rings: [[Double]]
    private var ringHeads: [Int]
    private var sums = [Double](repeating: 0, count: 12)
    /// The two filter banks run in parallel. Both use the selected receiver
    /// bandwidth locally so reference swaps do not create periodic loudness
    /// pumping in the native receiver.
    private var activeFilter = 1
    private var nextFilterSwap: UInt64
    private var agcReal: [Double]
    private var agcEnvelope: MRCEAGCEnvelope
    private var agcHead = 0
    private var agcBeta = 1.0
    private let agcMaxOut = 20_000.0
    /// How much of each recent input sample was the operator's own keying
    /// (0...1), kept for as long as a sample takes to pass the filter and
    /// the AGC, so the receive volume can leave the sidetone alone.
    private var ownShareDelay: [Double]
    private var ownShareHead = 0
    private var ownShareSmoothed = 0.0
    private let ownShareSmoothing: Double
    /// Playback scale for the live render path. MRCE writes the AGC's output
    /// straight to 16-bit samples, so its ceiling of 20,000 sits 4.3 dB below
    /// full scale and that headroom is never used. The AGC cannot exceed its
    /// ceiling, so mapping the ceiling to 0.95 of full scale cannot clip. It
    /// makes everything 3.8 dB louder and changes no level relative to another.
    public static let outputScale = 0.95 / 20_000.0
    private var qsbReal: [Double]
    private var qsbImaginary: [Double]
    private let qsbMaxPoints = 320
    private let qsbFrameSamples: Int
    /// Fixed-size per-station QSB bandwidth cache, so one station keeps a single
    /// draw wherever it lands among the slots. No allocation after init.
    private var qsbStationIDs = [Int](repeating: -1, count: 64)
    private var qsbStationCutoffs = [Double](repeating: 0, count: 64)
    private var qsbStationNext = 0
    /// Fade state parked between one station's transmissions. MRCE keeps one
    /// `TQsb` per station and only advances it while that station sends, so a
    /// station that stopped in a fade resumes there.
    private var qsbSavedValid = [Bool](repeating: false, count: 64)
    private var qsbSavedScalars = [Double](repeating: 0, count: 64 * 6)
    private var qsbSavedReal = [Double](repeating: 0, count: 64 * 4 * 320)
    private var qsbSavedImaginary = [Double](repeating: 0, count: 64 * 4 * 320)
    private var qsbDrawRng: UInt32
    private var qrnState: MRCEAudioQRNState
    private var sampleClock: UInt64 = 0
    private var filterClock: UInt64 = 0
    private var rxGain = 1.0

    /// `stationCapacity` and receiver settings are fixed at initialization so
    /// processing never grows arrays or allocates memory.
    public init(sampleRate: Double = 44_100, center: Double, bandwidth: Int,
                stationCapacity: Int = 16, seed: UInt32 = 0x25C0_FFEE) {
        let sr = max(8_000, sampleRate)
        self.sampleRate = sr
        receiver = min(sr * 0.4, max(1, center))
        outputPitch = min(sr * 0.4, max(1, center))
        self.bandwidth = Double(max(40, bandwidth))
        window = max(2, Int((0.7 * sr / Double(max(40, bandwidth))).rounded()))
        riseSamples = max(1, (2.7 * 0.005 * sr).rounded())
        rampOn = Self.makeRamp(length: Int(riseSamples))
        rampOff = Array(rampOn.reversed())
        states = (0..<max(1, stationCapacity)).map { i in
            StationState(rng: seed &+ UInt32(truncatingIfNeeded: i &* 0x9E37_79B9))
        }
        activeSlots = [Int](repeating: 0, count: max(1, stationCapacity))
        let receiverWindow = max(2, Int((0.7 * sr / Double(max(40, bandwidth))).rounded()))
        // Each independent bank has three passes; they are never cascaded.
        // Sharing the selected point count avoids alternating audio bandwidth
        // when the reference swaps Filt and its default-width Filt2.
        let maximumReceiverWindow = max(2, Int((0.7 * sr / 40).rounded()))
        filterPoints = [Int](repeating: receiverWindow, count: 2)
        rings = (0..<12).map { _ in [Double](repeating: 0, count: maximumReceiverWindow) }
        nextFilterSwap = UInt64(max(1, Int((10 * 512 * sr / 11_025).rounded())))
        ringHeads = [Int](repeating: 0, count: 12)
        let attack = max(1, Int((155 * sr / 11_025).rounded())), hold = attack
        let agcCount = 2 * (attack + hold) + 1
        agcReal = [Double](repeating: 0, count: agcCount)
        var agcAttackShape = [Double](repeating: 0, count: agcCount)
        for i in 0..<attack {
            let weight = log(0.5 - 0.5 * cos(Double(i + 1) * .pi / Double(attack + 1)))
            agcAttackShape[i] = weight; agcAttackShape[agcCount - 1 - i] = weight
        }
        agcEnvelope = MRCEAGCEnvelope(weights: agcAttackShape)
        // Longest path through three moving averages and half the AGC window.
        ownShareDelay = [Double](repeating: 0, count: 3 * maximumReceiverWindow / 2 + agcCount / 2 + 2)
        // About two milliseconds, so the volume never steps.
        ownShareSmoothing = 1 - exp(-1 / (0.002 * sr))
        let noise = pow(10.0, 76.0 / 20.0)
        let noiseOut = min(0.25 * agcMaxOut, noise)
        agcBeta = noise / log(agcMaxOut / (agcMaxOut - noiseOut))
        qsbFrameSamples = max(1, Int((128 * sr / 11_025).rounded()))
        qsbReal = [Double](repeating: 0, count: max(1, stationCapacity) * 4 * qsbMaxPoints)
        qsbImaginary = [Double](repeating: 0, count: max(1, stationCapacity) * 4 * qsbMaxPoints)
        qrnState = MRCEAudioQRNState(seed: seed, sampleRate: sr)
        qsbDrawRng = seed == 0 ? 0x51B_5EED : seed ^ 0x51B_5EED
    }

    /// Retune while streaming. Ring storage is reserved at initialization;
    /// changing the bandwidth only changes the active moving-average window.
    public mutating func configure(center: Double, bandwidth: Int, outputPitch: Double? = nil) {
        receiver = min(sampleRate * 0.4, max(1, center))
        if let outputPitch { self.outputPitch = min(sampleRate * 0.4, max(1, outputPitch)) }
        self.bandwidth = Double(max(40, bandwidth))
        // RIT and pitch do not touch the filter in MRCE; only a new
        // bandwidth (`Filt.Points`) restarts it.
        let newWindow = max(2, Int((0.7 * sampleRate / self.bandwidth).rounded()))
        guard newWindow != window else { return }
        window = newWindow
        filterPoints[0] = window
        filterPoints[1] = window
        resetFilterBank(0); resetFilterBank(1)
        activeFilter = 1
        filterClock = sampleClock
        nextFilterSwap = filterClock + UInt64(max(1, Int((10 * 512 * sampleRate / 11_025).rounded())))
    }

    private mutating func random(_ state: inout UInt32) -> Double {
        Self.nextRandom(&state)
    }
    private static func nextRandom(_ state: inout UInt32) -> Double {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Double(state >> 8) / 16_777_216
    }
    private static func chooseQsbCutoff(_ state: inout UInt32, flutter: Bool) -> Double {
        var cutoff = 0.1 + nextRandom(&state) * 0.5
        if flutter && nextRandom(&state) < 0.3 { cutoff = 3 + nextRandom(&state) * 30 }
        return cutoff
    }
    /// Deterministic control-thread probe used by distribution tests. The
    /// renderer calls the same draw when a station's QSB state is initialized.
    static func qsbCutoffDraw(seed: UInt32, flutter: Bool) -> Double {
        var state = seed == 0 ? 0x25C0_FFEE : seed
        return chooseQsbCutoff(&state, flutter: flutter)
    }
    /// One QSB bandwidth per station for its lifetime (MRCE draws it when the
    /// DX station is created). A station not yet seen gets a fresh draw that
    /// honours the current Flutter setting. Unidentified programs always draw.
    private mutating func stationQsbCutoff(stationID: Int, flutter: Bool) -> Double {
        if stationID >= 0, let hit = qsbStationIDs.firstIndex(of: stationID) { return qsbStationCutoffs[hit] }
        let cutoff = Self.chooseQsbCutoff(&qsbDrawRng, flutter: flutter)
        if stationID >= 0 {
            qsbStationIDs[qsbStationNext] = stationID
            qsbSavedValid[qsbStationNext] = false
            qsbStationCutoffs[qsbStationNext] = cutoff
            qsbStationNext = (qsbStationNext + 1) % qsbStationIDs.count
        }
        return cutoff
    }
    private mutating func parkFade(_ st: StationState, slot: Int) {
        guard st.fadeStationID >= 0, st.qsbPoints > 0,
              let hit = qsbStationIDs.firstIndex(of: st.fadeStationID) else { return }
        let scalars = hit * 6
        qsbSavedScalars[scalars] = Double(st.qsbPoints); qsbSavedScalars[scalars + 1] = Double(st.qsbIndex)
        qsbSavedScalars[scalars + 2] = Double(st.qsbPrev); qsbSavedScalars[scalars + 3] = Double(st.qsbFrame)
        qsbSavedScalars[scalars + 4] = st.qsbGain; qsbSavedScalars[scalars + 5] = st.qsbNextGain
        let from = slot * 4 * qsbMaxPoints, to = hit * 4 * qsbMaxPoints
        for k in 0..<(4 * qsbMaxPoints) {
            qsbSavedReal[to + k] = qsbReal[from + k]; qsbSavedImaginary[to + k] = qsbImaginary[from + k]
        }
        qsbSavedValid[hit] = true
    }
    private mutating func resumeFade(_ st: inout StationState, slot: Int) -> Bool {
        guard st.fadeStationID >= 0, let hit = qsbStationIDs.firstIndex(of: st.fadeStationID),
              qsbSavedValid[hit] else { return false }
        let scalars = hit * 6
        st.qsbCutoff = qsbStationCutoffs[hit]
        st.qsbPoints = Int(qsbSavedScalars[scalars]); st.qsbIndex = Int(qsbSavedScalars[scalars + 1])
        st.qsbPrev = Int(qsbSavedScalars[scalars + 2]); st.qsbFrame = Int(qsbSavedScalars[scalars + 3])
        st.qsbGain = qsbSavedScalars[scalars + 4]; st.qsbNextGain = qsbSavedScalars[scalars + 5]
        let to = slot * 4 * qsbMaxPoints, from = hit * 4 * qsbMaxPoints
        for k in 0..<(4 * qsbMaxPoints) {
            qsbReal[to + k] = qsbSavedReal[from + k]; qsbImaginary[to + k] = qsbSavedImaginary[from + k]
        }
        return true
    }
    /// Control-thread probe: the cutoff the slot's fade state is using, or 0
    /// when it has not started fading yet.
    func qsbCutoffProbe(slot: Int) -> Double { states[slot].qsbCutoff }
    private mutating func smooth(_ state: inout (Double, Double, Double), input: Double, cutoff: Double) -> Double {
        let a = 1 - exp(-2 * Double.pi * cutoff / sampleRate)
        state.0 += a * (input - state.0)
        state.1 += a * (state.0 - state.1)
        state.2 += a * (state.1 - state.2)
        return state.2
    }
    private static func makeRamp(length: Int) -> [Double] {
        let n = max(1, length)
        var ramp = [Double](repeating: 0, count: n), sum = 0.0
        for i in 0..<n {
            let x = Double(i) / Double(n)
            sum += 0.35875 - 0.48829 * cos(2 * .pi * x) + 0.14128 * cos(4 * .pi * x) - 0.01168 * cos(6 * .pi * x)
            ramp[i] = sum
        }
        if sum > 0 { for i in 0..<n { ramp[i] /= sum } }
        ramp[0] = 0; ramp[n - 1] = 1
        return ramp
    }
    private func rampValue(_ progress: Double, rising: Bool = true) -> Double {
        let i = min(rampOn.count - 1, max(0, Int(progress * Double(rampOn.count - 1))))
        return rising ? rampOn[i] : rampOff[i]
    }
    private func envelopeValue(from: Double, to: Double, progress: Double) -> Double {
        if to >= from { return from + (to - from) * rampValue(progress) }
        return to + (from - to) * rampValue(progress, rising: false)
    }
    private mutating func qsbGain(_ st: inout StationState, enabled: Bool) -> Double {
        guard enabled else { return 1 }
        if st.qsbCutoff == 0 { st.qsbCutoff = 0.1 + random(&st.rng) * 0.5 }
        let real = smooth(&st.qsb, input: random(&st.rng) - 0.5, cutoff: st.qsbCutoff)
        let imaginary = smooth(&st.qsbImag, input: random(&st.rng) - 0.5, cutoff: st.qsbCutoff)
        // Equivalent quick-average normalization for the three cascaded stages.
        let points = max(1, sampleRate / (st.qsbCutoff * 2))
        return sqrt((real * real + imaginary * imaginary) * 3 * points)
    }
    private mutating func flutterGain(_ st: inout StationState, enabled: Bool) -> Double {
        guard enabled else { return 1 }
        if st.flutterCutoff == 0 { st.flutterCutoff = 3 + random(&st.rng) * 30 }
        let f = smooth(&st.flutter, input: random(&st.rng) - 0.5, cutoff: st.flutterCutoff)
        return max(0, 1 + 0.3 * f * 3.46)
    }
    private mutating func qsbSample(_ st: inout StationState, slot: Int, enabled: Bool, flutter: Bool = false) -> Double {
        guard enabled else { return 1 }
        if st.qsbPoints == 0 {
            st.qsbCutoff = stationQsbCutoff(stationID: st.fadeStationID, flutter: flutter)
            st.qsbPoints = min(qsbMaxPoints, max(1, Int(ceil(0.37 * 11_025 / (128 * st.qsbCutoff)))))
            st.qsbPrev = st.qsbPoints - 1
            for _ in 0...(st.qsbPoints * 3) {
                st.qsbGain = qsbFilteredGain(re: random(&st.rng) * 2 - 1,
                                           im: random(&st.rng) * 2 - 1, st: &st, slot: slot)
            }
            st.qsbNextGain = st.qsbGain
        }
        if st.qsbFrame == 0 {
            st.qsbNextGain = qsbFilteredGain(re: random(&st.rng) * 2 - 1,
                                            im: random(&st.rng) * 2 - 1, st: &st, slot: slot)
        }
        let gain = st.qsbGain + (st.qsbNextGain - st.qsbGain) * Double(st.qsbFrame) / Double(qsbFrameSamples)
        st.qsbFrame += 1
        if st.qsbFrame >= qsbFrameSamples { st.qsbFrame = 0; st.qsbGain = st.qsbNextGain }
        return gain
    }
    private mutating func qsbFilteredGain(re: Double, im: Double, st: inout StationState, slot: Int) -> Double {
        let p = st.qsbPoints, idx = st.qsbIndex, prev = st.qsbPrev
        var r = re, q = im
        for stage in 1...3 {
            let prevOffset = (slot * 4 + stage) * qsbMaxPoints + prev
            let curOffset = (slot * 4 + stage - 1) * qsbMaxPoints + idx
            let nr = qsbReal[prevOffset] - qsbReal[curOffset] + r
            let ni = qsbImaginary[prevOffset] - qsbImaginary[curOffset] + q
            qsbReal[curOffset] = r; qsbImaginary[curOffset] = q
            r = nr; q = ni
        }
        let end = (slot * 4 + 3) * qsbMaxPoints + idx
        qsbReal[end] = r; qsbImaginary[end] = q
        st.qsbPrev = idx; st.qsbIndex = (idx + 1) % p
        let scale = pow(Double(p), -3), rr = r * scale, ii = q * scale
        return sqrt((rr * rr + ii * ii) * 3 * Double(p))
    }
    /// MRCE always mixes its low-level complex radio-noise bed. QRN only adds
    /// the optional background impulses and burst-station arrivals.
    private mutating func addNoise(real: inout Double, imaginary: inout Double, qrnEnabled: Bool) {
        let noise = qrnState.sample(sampleRate: sampleRate, qrnEnabled: qrnEnabled)
        real += noise.real; imaginary += noise.imaginary
    }
    private mutating func resetFilterBank(_ bank: Int) {
        for stage in 0..<3 {
            let realIndex = bank * 6 + stage * 2
            for i in rings[realIndex].indices { rings[realIndex][i] = 0 }
            for i in rings[realIndex + 1].indices { rings[realIndex + 1][i] = 0 }
            ringHeads[realIndex] = 0; ringHeads[realIndex + 1] = 0
            sums[realIndex] = 0; sums[realIndex + 1] = 0
        }
    }

    /// Advance one independent three pass MRCE moving average. The second
    /// instance is evaluated too, but its returned value is discarded.
    private mutating func filterBank(_ bank: Int, real: Double, imaginary: Double) -> (Double, Double) {
        var r = real, q = imaginary
        let points = filterPoints[bank]
        for stage in 0..<3 {
            let ri = bank * 6 + stage * 2, qi = ri + 1
            let head = ringHeads[ri]
            sums[ri] += r - rings[ri][head]
            sums[qi] += q - rings[qi][head]
            rings[ri][head] = r; rings[qi][head] = q
            r = sums[ri] / Double(points); q = sums[qi] / Double(points)
            ringHeads[ri] = (head + 1) % points; ringHeads[qi] = ringHeads[ri]
        }
        let gain = sqrt(500 / bandwidth)
        return (r * gain, q * gain)
    }

    mutating func filterComplex(_ real: Double, _ imaginary: Double) -> (Double, Double) {
        _ = filterBank(1 - activeFilter, real: real, imaginary: imaginary)
        let result = filterBank(activeFilter, real: real, imaginary: imaginary)
        filterClock &+= 1
        if filterClock >= nextFilterSwap {
            let retired = activeFilter
            activeFilter = 1 - activeFilter
            resetFilterBank(retired)
            nextFilterSwap &+= UInt64(max(1, Int((10 * 512 * sampleRate / 11_025).rounded())))
        }
        return result
    }
    /// The end of MRCE's `GetAudio`: the two moving-average filters, the mix
    /// up to the pitch frequency and the AGC, for one complex sample. Returns
    /// the 16-bit-scale audio sample. The live render path and the
    /// compiled-Pascal comparison in the tests both go through here.
    mutating func receiverTail(real: Double, imaginary: Double) -> Double {
        let (fi, fq) = filterComplex(real, imaginary)
        let phase = 2 * .pi * outputPitch * Double(sampleClock) / sampleRate
        sampleClock &+= 1
        return agcOutput(fi * cos(phase) - fq * sin(phase))
    }
    /// Output gain for one sample. The receive volume applies to what the
    /// receiver hears; the operator's own sidetone has the monitor level for
    /// that and passes at full gain. `ownShare` is how much of the sample
    /// entering the filter is own keying; it is delayed to match the sample
    /// now leaving the AGC.
    private mutating func playbackGain(receiveGain: Double, ownShare: Double) -> Double {
        let count = ownShareDelay.count
        ownShareDelay[ownShareHead] = ownShare
        let delay = min(count - 1, 3 * (window - 1) / 2 + agcReal.count / 2)
        let delayed = ownShareDelay[(ownShareHead + count - delay) % count]
        ownShareHead = (ownShareHead + 1) % count
        ownShareSmoothed += ownShareSmoothing * (delayed - ownShareSmoothed)
        return receiveGain + (1 - receiveGain) * ownShareSmoothed
    }
    private mutating func agcOutput(_ signal: Double) -> Double {
        agcReal[agcHead] = signal
        let envelope = agcEnvelope.push(log(abs(signal + 1e-10)))
        agcHead = (agcHead + 1) % agcReal.count
        let magnitude = exp(envelope)
        let gain = agcMaxOut * (1 - exp(-magnitude / agcBeta)) / magnitude
        let midpoint = (agcHead + agcReal.count / 2) % agcReal.count
        return agcReal[midpoint] * gain
    }

    /// Fill an existing mono buffer. Every input station is mixed as complex RF,
    /// translated to receiver beat frequency, filtered by three moving averages,
    /// and restored to audible receiver pitch. `stations.count` must fit capacity.
    public mutating func process(_ output: UnsafeMutableBufferPointer<Float>,
                                stations: [MRCEAudioStation], effects: Effects = Effects()) {
        let n = min(states.count, stations.count)
        let nSamples = output.count
        guard nSamples > 0 else { return }
        for j in 0..<n { states[j].rng = states[j].rng == 0 ? UInt32(j + 1) : states[j].rng }
        for i in 0..<nSamples {
            var inI = 0.0, inQ = 0.0
            for j in 0..<n {
                let station = stations[j]
                var st = states[j]
                let qsb = qsbGain(&st, enabled: effects.qsb)
                let flutter = flutterGain(&st, enabled: effects.flutter)
                let k = min(1, max(0, station.key))
                if k != st.lastKey {
                    st.keyFrom = st.keyEnvelope; st.keyTo = Double(k)
                    st.keyAge = 0; st.lastKey = k
                }
                st.keyAge += 1
                let edge = min(1, st.keyAge / riseSamples)
                let gate = envelopeValue(from: st.keyFrom, to: st.keyTo, progress: edge)
                st.keyEnvelope = gate
                st.phase += 2 * .pi * (station.frequency - receiver) / sampleRate
                if st.phase > .pi { st.phase -= 2 * .pi } else if st.phase < -.pi { st.phase += 2 * .pi }
                let a = station.level * Double(gate) * qsb * flutter
                inI += a * cos(st.phase); inQ += a * sin(st.phase)
                states[j] = st
            }
            addNoise(real: &inI, imaginary: &inQ, qrnEnabled: effects.qrn)
            let (iPart, qPart) = filterComplex(inI, inQ)
            let angle = 2 * .pi * receiver * Double(sampleClock) / sampleRate
            let signal = iPart * cos(angle) - qPart * sin(angle)
            output[i] = Float(max(-0.98, min(0.98, agcOutput(signal) / 32_768)))
            sampleClock &+= 1
        }
        _ = bandwidth // retained as explicit renderer configuration
    }
    public mutating func process(_ output: inout [Float], stations: [MRCEAudioStation], effects: Effects = Effects()) {
        output.withUnsafeMutableBufferPointer { process($0, stations: stations, effects: effects) }
    }

    /// Pointer form for render callbacks. The station memory is borrowed only
    /// for the duration of this call; keep it in a fixed-capacity owner buffer.
    public mutating func process(_ output: UnsafeMutableBufferPointer<Float>,
                                stations: UnsafeBufferPointer<MRCEAudioStation>,
                                effects: Effects = Effects()) {
        // The descriptor overload is useful for offline rendering; use the same
        // fixed state machine without constructing a temporary descriptor array.
        let n = min(states.count, stations.count)
        guard output.count > 0 else { return }
        for i in 0..<output.count {
            var iPart = 0.0, qPart = 0.0
            for j in 0..<n {
                let station = stations[j]
                var st = states[j]
                let qsb = qsbGain(&st, enabled: effects.qsb)
                let flutter = flutterGain(&st, enabled: effects.flutter)
                let key = min(1, max(0, station.key))
                if key != st.lastKey {
                    st.keyFrom = st.keyEnvelope; st.keyTo = Double(key)
                    st.keyAge = 0; st.lastKey = key
                }
                st.keyAge += 1
                let edge = min(1, st.keyAge / riseSamples)
                let gate = envelopeValue(from: st.keyFrom, to: st.keyTo, progress: edge)
                st.keyEnvelope = gate
                st.phase += 2 * .pi * (station.frequency - receiver) / sampleRate
                if st.phase > .pi { st.phase -= 2 * .pi } else if st.phase < -.pi { st.phase += 2 * .pi }
                let amp = station.level * Double(gate) * qsb * flutter
                iPart += amp * cos(st.phase); qPart += amp * sin(st.phase)
                states[j] = st
            }
            addNoise(real: &iPart, imaginary: &qPart, qrnEnabled: effects.qrn)
            let (filteredI, filteredQ) = filterComplex(iPart, qPart)
            let phase = 2 * .pi * receiver * Double(sampleClock) / sampleRate
            let signal = filteredI * cos(phase) - filteredQ * sin(phase)
            output[i] = Float(max(-0.98, min(0.98, agcOutput(signal) / 32_768)))
            sampleClock &+= 1
        }
    }

    /// Render fixed program slots directly. `programs` and `playheads` must be
    /// stable buffers owned by the audio host. A non-nil program starts at its
    /// supplied playhead; this method advances each active playhead in place.
    /// Programs are immutable and may overlap across slots.
    public mutating func process(_ output: UnsafeMutableBufferPointer<Float>,
                                programs: UnsafeBufferPointer<MRCEAudioProgram?>,
                                playheads: UnsafeMutableBufferPointer<Int64>,
                                effects: Effects = Effects()) {
        let n = min(states.count, min(programs.count, playheads.count))
        guard output.count > 0 else { return }
        for i in 0..<output.count {
            var inI = 0.0, inQ = 0.0
            for j in 0..<n {
                var st = states[j]
                guard let program = programs[j] else {
                    if st.keyTo != 0 { st.keyFrom = st.keyEnvelope; st.keyTo = 0; st.keyAge = 0 }
                    st.keyAge += 1
                    let x = min(1, st.keyAge / riseSamples), shape = rampValue(x, rising: false)
                    let envelope = st.keyFrom * shape
                    st.keyEnvelope = envelope
                    if envelope > 0 { inI += envelope * cos(st.phase); inQ += envelope * sin(st.phase) }
                    else { st.markCursor = 0; st.keyFrom = 0; st.keyEnvelope = 0; st.phase = 0 }
                    states[j] = st
                    continue
                }
                let playhead = playheads[j]
                if playhead == 0 { st.markCursor = 0; st.phase = 0; st.keyFrom = 0; st.keyTo = 0; st.keyEnvelope = 0; st.keyAge = riseSamples }
                while st.markCursor < program.events.count &&
                      program.events[st.markCursor].sampleOffset + program.events[st.markCursor].duration <= playhead {
                    st.markCursor += 1
                }
                var mark: MRCEAudioMarkEvent? = nil
                if st.markCursor < program.events.count {
                    let candidate = program.events[st.markCursor]
                    if playhead >= candidate.sampleOffset && playhead < candidate.sampleOffset + candidate.duration { mark = candidate }
                }
                let target = mark == nil ? 0.0 : Double(mark!.level)
                if target != st.keyTo { st.keyFrom = st.keyEnvelope; st.keyTo = target; st.keyAge = 0 }
                st.keyAge += 1
                let x = min(1, st.keyAge / riseSamples)
                // Integrated, normalized 4-term Blackman-Harris step response
                // from MRCE MorseKey (2.7 * 5 ms at the reference sample rate).
                let envelope = envelopeValue(from: st.keyFrom, to: st.keyTo, progress: x)
                st.keyEnvelope = envelope
                if let mark {
                    st.phase += 2 * .pi * (mark.frequency - receiver) / sampleRate
                    if st.phase > .pi { st.phase -= 2 * .pi } else if st.phase < -.pi { st.phase += 2 * .pi }
                    let qsb = qsbSample(&st, slot: j, enabled: effects.qsb || effects.flutter, flutter: effects.flutter)
                    let amp = envelope * Double(mark.level) * qsb
                    inI += amp * cos(st.phase); inQ += amp * sin(st.phase)
                }
                states[j] = st
                playheads[j] &+= 1
            }
            addNoise(real: &inI, imaginary: &inQ, qrnEnabled: effects.qrn)
            let (fi, fq) = filterComplex(inI, inQ)
            let phase = 2 * .pi * receiver * Double(sampleClock) / sampleRate
            let signal = fi * cos(phase) - fq * sin(phase)
            output[i] = Float(max(-0.98, min(0.98, agcOutput(signal))))
            sampleClock &+= 1
        }
    }

    /// Preferred strict render callback form. Program views are trivial values;
    /// the host keeps their backing programs alive outside the callback.
    public mutating func process(_ output: UnsafeMutableBufferPointer<Float>,
                                programs: UnsafeBufferPointer<MRCEAudioProgramView?>,
                                playheads: UnsafeMutableBufferPointer<Int64>,
                                effects: Effects = Effects(), qsk: Bool = false,
                                receiveGain: Float = 1) {
        let n = min(states.count, min(programs.count, playheads.count))
        guard output.count > 0 else { return }
        // Program pointers remain fixed throughout this callback. Only visit
        // occupied slots and retired slots still carrying a release tail. Keep
        // original slot indices so oscillator and fading state never migrate.
        var activeCount = 0
        for j in 0..<n {
            let st = states[j]
            if programs[j] != nil || st.keyTo != 0 || st.keyFrom != 0 ||
                st.keyEnvelope != 0 || st.phase != 0 || st.markCursor != 0 {
                activeSlots[activeCount] = j
                activeCount += 1
            }
        }
        for i in 0..<output.count {
            var rxI = 0.0, rxQ = 0.0, txI = 0.0, txQ = 0.0
            var txKey = 0.0, txPresent = false
            for slot in 0..<activeCount {
                let j = activeSlots[slot]
                var st = states[j]
                guard let program = programs[j] else {
                    if st.keyTo != 0 { st.keyFrom = st.keyEnvelope; st.keyTo = 0; st.keyAge = 0 }
                    st.keyAge += 1
                    let x = min(1, st.keyAge / riseSamples), shape = rampValue(x, rising: false)
                    let envelope = st.keyFrom * shape
                    st.keyEnvelope = envelope
                    // Own sidetone is mixed at baseband (zero offset) so RIT cannot move it.
                    let offset = st.channel == .transmit ? 0 : st.frequency - receiver
                    st.phase += 2 * .pi * offset / sampleRate
                    if st.phase > .pi { st.phase -= 2 * .pi } else if st.phase < -.pi { st.phase += 2 * .pi }
                    if st.fadeLive { parkFade(st, slot: j) }
                    st.fadeLive = false
                    if envelope > 0 {
                        if st.channel == .transmit {
                            txPresent = true; txKey = max(txKey, envelope)
                            txI += envelope * cos(st.phase); txQ += envelope * sin(st.phase)
                        } else {
                            rxI += envelope * cos(st.phase); rxQ += envelope * sin(st.phase)
                        }
                    }
                    else { st.markCursor = 0; st.keyFrom = 0; st.keyEnvelope = 0; st.phase = 0 }
                    states[j] = st
                    continue
                }
                if program.channel == .transmit { txPresent = true }
                st.channel = program.channel
                let playhead = playheads[j]
                if playhead == 0 { st.markCursor = 0; st.phase = 0; st.keyFrom = 0; st.keyTo = 0; st.keyEnvelope = 0; st.keyAge = riseSamples }
                while st.markCursor < program.events.count && program.events[st.markCursor].sampleOffset + program.events[st.markCursor].duration <= playhead { st.markCursor += 1 }
                var mark: MRCEAudioMarkEvent? = nil
                if st.markCursor < program.events.count {
                    let candidate = program.events[st.markCursor]
                    if playhead >= candidate.sampleOffset && playhead < candidate.sampleOffset + candidate.duration { mark = candidate }
                }
                // Key state is unitless. Keep physical station amplitude out
                // of the ramp so it is applied exactly once below.
                let target = mark == nil ? 0.0 : 1.0
                if target != st.keyTo { st.keyFrom = st.keyEnvelope; st.keyTo = target; st.keyAge = 0 }
                st.keyAge += 1
                let x = min(1, st.keyAge / riseSamples)
                let envelope = envelopeValue(from: st.keyFrom, to: st.keyTo, progress: x)
                st.keyEnvelope = envelope
                // Propagation fading belongs to received stations. MRCE's own
                // station sidetone and QRM stations never fade, and Flutter only
                // changes the bandwidth draw when QSB is on. A slot starting a
                // different station gets that station's fade state.
                if program.channel == .receive,
                   !st.fadeLive || (program.stationID >= 0 && program.stationID != st.fadeStationID) {
                    if st.fadeLive { parkFade(st, slot: j) }
                    st.fadeStationID = program.stationID
                    if !resumeFade(&st, slot: j) {
                        st.qsbPoints = 0; st.qsbCutoff = 0; st.qsbFrame = 0; st.qsbIndex = 0
                        st.qsbGain = 1; st.qsbNextGain = 1
                        let base = j * 4 * qsbMaxPoints
                        for k in base..<(base + 4 * qsbMaxPoints) { qsbReal[k] = 0; qsbImaginary[k] = 0 }
                    }
                }
                st.fadeLive = true
                let fadeGain = program.channel != .receive ? 1 :
                    qsbSample(&st, slot: j, enabled: effects.qsb, flutter: effects.flutter)
                if let mark { st.frequency = mark.frequency }
                // Own sidetone is mixed at baseband (zero offset), whatever RIT is.
                let offset = program.channel == .transmit ? 0 : st.frequency - receiver
                st.phase += 2 * .pi * offset / sampleRate
                if st.phase > .pi { st.phase -= 2 * .pi } else if st.phase < -.pi { st.phase += 2 * .pi }
                if let mark {
                    let amp = envelope * Double(mark.level) * fadeGain
                    if program.channel == .transmit {
                        txKey = max(txKey, abs(envelope))
                        txI += amp * cos(st.phase); txQ += amp * sin(st.phase)
                    } else { rxI += amp * cos(st.phase); rxQ += amp * sin(st.phase) }
                }
                states[j] = st
                playheads[j] &+= 1
            }
            if qsk {
                let wanted = 1 - min(1, txKey * 7)
                if rxGain > wanted { rxGain = wanted }
                else {
                    let recovery = pow(0.997, 11_025 / sampleRate)
                    rxGain = min(1, rxGain * recovery + 1 - recovery)
                }
            } else { rxGain = txPresent ? 0 : 1 }
            // Generate and age ambient noise/QRN every sample. With QSK off,
            // rxGain=0 below replaces the receiver mix, but MRCE's noise and
            // burst clocks still advance during TX before the overwrite.
            addNoise(real: &rxI, imaginary: &rxQ, qrnEnabled: effects.qrn)
            // Filt2 and Filt both see the shared complex input. With QSK off,
            // keying replaces the receiver mix. With QSK on, TX and attenuated
            // RX share filtering, modulation, and AGC in both cases.
            let mixedI = txI + rxI * rxGain
            let mixedQ = txQ + rxQ * rxGain
            // With QSK the receiver is ducked by the key envelope; without it
            // the receiver is off for as long as a transmission is present.
            let ownShare = qsk ? min(1, txKey * 7) : (txPresent ? 1.0 : 0.0)
            let gain = playbackGain(receiveGain: Double(receiveGain), ownShare: ownShare)
            let mixedOutput = receiverTail(real: mixedI, imaginary: mixedQ) * Self.outputScale * gain
            output[i] = Float(max(-0.98, min(0.98, mixedOutput)))
        }
    }
}
