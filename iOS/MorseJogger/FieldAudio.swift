//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import AVFoundation
import CoreAudio
import Foundation
import UIKit
import MorseJoggerCore

// How audio gets out of the app
// -----------------------------
// `FieldAudio` (main actor) turns each transmission into an `MRCEAudioProgram`,
// a list of key-down marks on the sample clock. Programs are built and
// published on `audioQueue`, in the order they were asked for, and handed to
// the render thread through a lock-free command ring. The render thread owns sixteen playback
// slots and the MRCE receiver DSP; it mixes every active program into one
// stream and returns finished programs through a second ring so their memory
// is released off the render thread.
//
// The render callback is real-time: it must not allocate, lock or call into
// Swift concurrency. Everything it touches is preallocated in
// `MRCEAudioRenderState`.

// MARK: - Constants

private enum AudioConstants {
    /// MRCE's sample rate. All program timing and the receiver DSP run at it;
    /// the engine's mixer converts to the device rate.
    static let sampleRate = 11_025.0
    /// Receiver settings used until the first session configures the radio
    /// (MRCE's defaults: 600 Hz pitch, 500 Hz bandwidth).
    static let defaultPitchHz = 600
    static let defaultBandwidthHz = 500

    /// Programs that can sound at once. Callers: the highest band activity,
    /// which is as many as MRCE keeps on the band in HST and more than a
    /// pile-up reaches. QRM: MRCE rarely has more than one station at a time.
    /// Own: a transmission under way plus the pieces queued behind it (CQ,
    /// his call, exchange, TU and one more).
    static let callerSlots = 9
    static let interferenceSlots = 2
    static let ownTransmissionSlots = 5
    static let slotCount = callerSlots + interferenceSlots + ownTransmissionSlots
    /// Programs that can exist at once: those sounding, plus as many again
    /// waiting for a slot, each of which may have a finished predecessor not
    /// yet released.
    static let programCount = 4 * slotCount
    /// Capacity of each ring between the control side and the render thread:
    /// room for every program to be started and cancelled without a callback
    /// in between. Must be a power of two.
    static let ringCapacity = 2 * programCount

    /// Frames per buffer handed to the recording tap.
    static let recordingTapFrames: AVAudioFrameCount = 4096

    /// Range of the monitor (sidetone) level, in decibels.
    static let monitorRange = -60...0

    /// Seconds added to a caller's keyed length before its duration is
    /// reported, and the further margin added when that duration is
    /// acknowledged to the simulator. Together they keep a caller's reply
    /// timer from running out while its audio is still sounding. Both are
    /// inherited allowances, not MRCE values; see `docs/KNOWN_DIFFERENCES.md`.
    static let receiveTailSeconds = 0.15
    static let receiveAcknowledgementMarginSeconds = 0.18
}

/// Identifiers shared by the control side and the render thread.
private enum AudioID {
    /// An empty slot, or a command that names no program.
    static let none = -1
    /// A program that belongs to no particular station (QRM, unnamed callers).
    static let anonymousStation = -1
    /// "Replaces nothing": station IDs can be negative, so this cannot be -1.
    static let replacesNothing = Int.min
    /// Callers count up from here.
    static let firstCallerStation = 1
    /// Own transmissions count down from here, so they never collide with callers.
    static let firstTransmitStation = -2
}

/// Band-condition switches packed into one atomic word for the render thread.
private struct EffectFlags: OptionSet {
    let rawValue: Int
    static let qrn = EffectFlags(rawValue: 1 << 0)
    static let qsb = EffectFlags(rawValue: 1 << 1)
    static let flutter = EffectFlags(rawValue: 1 << 2)

    init(rawValue: Int) { self.rawValue = rawValue }
    init(_ effects: Effects) {
        var flags: EffectFlags = []
        if effects.qrn { flags.insert(.qrn) }
        if effects.qsb { flags.insert(.qsb) }
        if effects.flutter { flags.insert(.flutter) }
        self = flags
    }
    var effects: Effects {
        var effects = Effects()
        effects.qrn = contains(.qrn)
        effects.qsb = contains(.qsb)
        effects.flutter = contains(.flutter)
        return effects
    }
}

// MARK: - Lock-free primitives

@_silgen_name("cwAtomicInt64Create") private func cwAtomicInt64Create(_ initialValue: Int) -> UnsafeMutableRawPointer?
@_silgen_name("cwAtomicInt64Destroy") private func cwAtomicInt64Destroy(_ storage: UnsafeMutableRawPointer)
@_silgen_name("cwAtomicInt64IsLockFree") private func cwAtomicInt64IsLockFree(_ storage: UnsafeMutableRawPointer) -> Int32
@_silgen_name("cwAtomicInt64LoadRelaxed") private func cwAtomicInt64LoadRelaxed(_ storage: UnsafeMutableRawPointer) -> Int
@_silgen_name("cwAtomicInt64LoadAcquire") private func cwAtomicInt64LoadAcquire(_ storage: UnsafeMutableRawPointer) -> Int
@_silgen_name("cwAtomicInt64StoreRelaxed") private func cwAtomicInt64StoreRelaxed(_ storage: UnsafeMutableRawPointer, _ value: Int)
@_silgen_name("cwAtomicInt64StoreRelease") private func cwAtomicInt64StoreRelease(_ storage: UnsafeMutableRawPointer, _ value: Int)
@_silgen_name("cwAtomicInt64FetchAddAcqRel") private func cwAtomicInt64FetchAddAcqRel(_ storage: UnsafeMutableRawPointer, _ value: Int) -> Int
@_silgen_name("cwAtomicInt64FetchAddRelease") private func cwAtomicInt64FetchAddRelease(_ storage: UnsafeMutableRawPointer, _ value: Int) -> Int

private enum RealtimeOrdering: Equatable { case relaxed, acquiring, releasing, acquiringAndReleasing }

/// A lock-free integer shared with the render thread (C11 atomics, `CWAtomic.c`).
private final class RealtimeAtomicInt: @unchecked Sendable {
    private let storage: UnsafeMutableRawPointer
    init(_ value: Int) {
        guard let storage = cwAtomicInt64Create(value) else { fatalError("Could not allocate audio atomic") }
        guard cwAtomicInt64IsLockFree(storage) != 0 else {
            cwAtomicInt64Destroy(storage)
            fatalError("Audio atomics must be lock free")
        }
        self.storage = storage
    }
    deinit { cwAtomicInt64Destroy(storage) }

    func load(ordering: RealtimeOrdering) -> Int {
        ordering == .relaxed ? cwAtomicInt64LoadRelaxed(storage) : cwAtomicInt64LoadAcquire(storage)
    }
    func store(_ value: Int, ordering: RealtimeOrdering) {
        if ordering == .relaxed { cwAtomicInt64StoreRelaxed(storage, value) }
        else { cwAtomicInt64StoreRelease(storage, value) }
    }
    func wrappingAdd(_ value: Int, ordering: RealtimeOrdering) {
        if ordering == .releasing { _ = cwAtomicInt64FetchAddRelease(storage, value) }
        else { _ = cwAtomicInt64FetchAddAcqRel(storage, value) }
    }
    /// Convenience for the flags stored as 0 or 1.
    var isSet: Bool { load(ordering: .acquiring) != 0 }
    func set(_ value: Bool) { store(value ? 1 : 0, ordering: .releasing) }
}

/// What the control side asks the render thread to do.
private struct AudioProgramCommand {
    /// Index of the program in the registry, or `AudioID.none` for a cancel.
    var identifier: Int = AudioID.none
    /// Playback generation the program was made for. `stopPlayback` bumps the
    /// generation, which discards everything made before it.
    var generation: Int = 0
    /// Render-clock frame the program's sample offsets are measured from.
    var referenceFrame: Int64 = 0
    var stationID: Int = AudioID.anonymousStation
    /// Stop every program of `stationID` instead of starting one.
    var cancel: Bool = false
    /// Station ID of a program this one takes over from, keeping its slot,
    /// playhead and envelope state (a call re-keyed while being sent).
    var replaces: Int = AudioID.replacesNothing
}

/// Single-producer, single-consumer queue of commands for the render thread.
/// The two rings below are deliberately concrete rather than one generic
/// type: unspecialised generic code may consult runtime metadata, which is
/// not safe on the render thread in a debug build.
private final class AudioCommandRing: @unchecked Sendable {
    private let capacity = AudioConstants.ringCapacity
    private let mask = AudioConstants.ringCapacity - 1
    private let values: UnsafeMutablePointer<AudioProgramCommand>
    private let head = RealtimeAtomicInt(0), tail = RealtimeAtomicInt(0)
    init() {
        precondition(capacity & mask == 0, "ring capacity must be a power of two")
        values = .allocate(capacity: capacity)
        values.initialize(repeating: AudioProgramCommand(), count: capacity)
    }
    deinit {
        values.deinitialize(count: capacity)
        values.deallocate()
    }
    /// Control side.
    func tryPush(_ value: AudioProgramCommand) -> Bool {
        let write = head.load(ordering: .relaxed), read = tail.load(ordering: .acquiring)
        guard write - read < capacity else { return false }
        values[write & mask] = value
        head.store(write + 1, ordering: .releasing)
        return true
    }
    /// Render thread.
    func peek() -> AudioProgramCommand? {
        let read = tail.load(ordering: .relaxed)
        guard read < head.load(ordering: .acquiring) else { return nil }
        return values[read & mask]
    }
    /// Render thread.
    func discardNext() {
        let read = tail.load(ordering: .relaxed)
        guard read < head.load(ordering: .acquiring) else { return }
        tail.store(read + 1, ordering: .releasing)
    }
}

/// Single-producer, single-consumer queue of finished program identifiers,
/// from the render thread back to the control side.
private final class AudioRetirementRing: @unchecked Sendable {
    private let capacity = AudioConstants.ringCapacity
    private let mask = AudioConstants.ringCapacity - 1
    private let values: UnsafeMutablePointer<Int>
    private let head = RealtimeAtomicInt(0), tail = RealtimeAtomicInt(0)
    init() {
        values = .allocate(capacity: capacity)
        values.initialize(repeating: AudioID.none, count: capacity)
    }
    deinit {
        values.deinitialize(count: capacity)
        values.deallocate()
    }
    /// Render thread.
    func tryPush(_ value: Int) -> Bool {
        let write = head.load(ordering: .relaxed), read = tail.load(ordering: .acquiring)
        guard write - read < capacity else { return false }
        values[write & mask] = value
        head.store(write + 1, ordering: .releasing)
        return true
    }
    /// Control side.
    func tryPop() -> Int? {
        let read = tail.load(ordering: .relaxed)
        guard read < head.load(ordering: .acquiring) else { return nil }
        let value = values[read & mask]
        tail.store(read + 1, ordering: .releasing)
        return value
    }
}

// MARK: - Render state

/// Everything the render callback reads and writes.
///
/// Ownership is split in two. The render thread owns the slots (`views`,
/// `playheads`, `activeIDs`) and the DSP. The control side (always on
/// `FieldAudio.audioQueue`) owns the registry (`owners`, `registryViews`,
/// `freeProgramIDs`), which keeps each program alive until the render thread
/// has returned its identifier through `retired`.
private final class MRCEAudioRenderState: @unchecked Sendable {
    private static let slotCount = AudioConstants.slotCount
    private static let programCount = AudioConstants.programCount

    // Shared, atomic.
    let commands = AudioCommandRing(), retired = AudioRetirementRing()
    /// Bumped by `stopPlayback`; programs from an older generation are dropped.
    let generation = RealtimeAtomicInt(0)
    /// The render clock: frames rendered since launch.
    let renderedFrames = RealtimeAtomicInt(0)
    /// Frames asked for by the most recent render callback.
    let renderQuantum = RealtimeAtomicInt(0)
    /// Whether the engine is meant to be running (cleared by pause and shutdown).
    let shouldRun = RealtimeAtomicInt(0)
    /// Invalidates graph-queue start requests when pause/shutdown takes
    /// ownership before an earlier asynchronous start reaches the engine.
    let engineRequestGeneration = RealtimeAtomicInt(0)
    private let muted = RealtimeAtomicInt(0), qsk = RealtimeAtomicInt(0)
    private let effectFlags = RealtimeAtomicInt(0)
    /// Receive volume, a `Float` stored as its bit pattern.
    private let receiveGainBits = RealtimeAtomicInt(Int(Float(1).bitPattern))
    private let centerHz: RealtimeAtomicInt, outputPitchHz: RealtimeAtomicInt, bandwidthHz: RealtimeAtomicInt

    // Render thread only.
    private let views: UnsafeMutablePointer<MRCEAudioProgramView?>
    private let playheads: UnsafeMutablePointer<Int64>
    /// Registry identifier of the program in each slot, or `AudioID.none`.
    private let activeIDs: UnsafeMutablePointer<Int>
    private var renderer: MRCEAudioRenderer
    private var renderGeneration = 0
    private var renderCenter: Int, renderPitch: Int, renderBandwidth: Int

    // Control side only (written before a command is pushed, read by the
    // render thread only after it pops that command).
    private let registryViews: UnsafeMutablePointer<MRCEAudioProgramView?>
    private let owners: UnsafeMutablePointer<MRCEAudioProgram?>
    private var freeProgramIDs = Array((0..<programCount).reversed())

    init(sampleRate: Double, center: Int, bandwidth: Int) {
        renderCenter = center; renderPitch = center; renderBandwidth = bandwidth
        centerHz = RealtimeAtomicInt(center)
        outputPitchHz = RealtimeAtomicInt(center)
        bandwidthHz = RealtimeAtomicInt(bandwidth)
        renderer = MRCEAudioRenderer(sampleRate: sampleRate, center: Double(center), bandwidth: bandwidth,
                                     stationCapacity: Self.slotCount)
        views = .allocate(capacity: Self.slotCount)
        views.initialize(repeating: nil, count: Self.slotCount)
        playheads = .allocate(capacity: Self.slotCount)
        playheads.initialize(repeating: 0, count: Self.slotCount)
        activeIDs = .allocate(capacity: Self.slotCount)
        activeIDs.initialize(repeating: AudioID.none, count: Self.slotCount)
        registryViews = .allocate(capacity: Self.programCount)
        registryViews.initialize(repeating: nil, count: Self.programCount)
        owners = .allocate(capacity: Self.programCount)
        owners.initialize(repeating: nil, count: Self.programCount)
    }
    deinit {
        views.deinitialize(count: Self.slotCount); views.deallocate()
        playheads.deinitialize(count: Self.slotCount); playheads.deallocate()
        activeIDs.deinitialize(count: Self.slotCount); activeIDs.deallocate()
        registryViews.deinitialize(count: Self.programCount); registryViews.deallocate()
        owners.deinitialize(count: Self.programCount); owners.deallocate()
    }

    // MARK: Control side

    func setMuted(_ value: Bool) { muted.set(value) }

    func setSettings(_ settings: ContestSettings) {
        effectFlags.store(EffectFlags(settings.effects).rawValue, ordering: .releasing)
        qsk.set(settings.qsk)
        receiveGainBits.store(Int(Float(settings.volume).bitPattern), ordering: .releasing)
        // RIT moves the receiver; the operator's own pitch stays put.
        centerHz.store(settings.pitch + settings.rit, ordering: .releasing)
        outputPitchHz.store(settings.pitch, ordering: .releasing)
        bandwidthHz.store(settings.bandwidth, ordering: .releasing)
    }

    /// Hands a program to the render thread. With `replacing`, it takes over
    /// from the program of that station ID instead of starting afresh.
    /// Returns false when the registry or the command ring is full.
    func publish(_ program: MRCEAudioProgram, generation: Int, referenceFrame: Int64,
                 replacing: Int = AudioID.replacesNothing) -> Bool {
        collectRetired()
        guard let id = freeProgramIDs.popLast() else { return false }
        owners[id] = program
        program.withView { registryViews[id] = $0 }
        let command = AudioProgramCommand(identifier: id, generation: generation, referenceFrame: referenceFrame,
                                          stationID: program.stationID, replaces: replacing)
        guard commands.tryPush(command) else {
            release(id)
            return false
        }
        return true
    }

    func cancel(stationID: Int) {
        _ = commands.tryPush(AudioProgramCommand(stationID: stationID, cancel: true))
    }

    /// Releases the programs the render thread has finished with.
    func collectRetired() {
        while let id = retired.tryPop() {
            guard (0..<Self.programCount).contains(id) else { continue }
            release(id)
        }
    }

    private func release(_ id: Int) {
        registryViews[id] = nil
        owners[id] = nil
        freeProgramIDs.append(id)
    }

    // MARK: Render thread

    func render(_ output: UnsafeMutableBufferPointer<Float>) {
        guard !output.isEmpty else { return }
        applyTuningChanges()
        let currentGeneration = dropProgramsFromOlderGenerations()
        drainCommands(generation: currentGeneration)

        let receiveGain = Float(bitPattern: UInt32(truncatingIfNeeded: receiveGainBits.load(ordering: .acquiring)))
        renderer.process(output,
                         programs: UnsafeBufferPointer(start: views, count: Self.slotCount),
                         playheads: UnsafeMutableBufferPointer(start: playheads, count: Self.slotCount),
                         effects: EffectFlags(rawValue: effectFlags.load(ordering: .acquiring)).effects,
                         qsk: qsk.isSet,
                         receiveGain: receiveGain)
        retireFinishedPrograms()

        // Muting silences the output only; programs keep playing underneath,
        // so unmuting part-way through a message lets the rest be heard.
        if muted.isSet { for index in output.indices { output[index] = 0 } }
        renderQuantum.store(output.count, ordering: .relaxed)
        renderedFrames.wrappingAdd(output.count, ordering: .releasing)
    }

    private func applyTuningChanges() {
        let center = centerHz.load(ordering: .acquiring)
        let pitch = outputPitchHz.load(ordering: .acquiring)
        let bandwidth = bandwidthHz.load(ordering: .acquiring)
        guard center != renderCenter || pitch != renderPitch || bandwidth != renderBandwidth else { return }
        renderer.configure(center: Double(center), bandwidth: bandwidth, outputPitch: Double(pitch))
        renderCenter = center; renderPitch = pitch; renderBandwidth = bandwidth
    }

    private func dropProgramsFromOlderGenerations() -> Int {
        let current = generation.load(ordering: .acquiring)
        if current != renderGeneration {
            for slot in 0..<Self.slotCount { retire(slot) }
            renderGeneration = current
        }
        return current
    }

    /// Takes commands in order until the ring is empty or a start command
    /// finds no free slot (it waits there for the next callback).
    private func drainCommands(generation currentGeneration: Int) {
        for _ in 0..<Self.slotCount {
            guard let command = commands.peek() else { return }
            if command.cancel {
                commands.discardNext()
                for slot in 0..<Self.slotCount where isActive(slot) && views[slot]?.stationID == command.stationID {
                    retire(slot)
                }
                continue
            }
            let freeSlot = firstFreeSlot()
            let replacedSlot = command.replaces == AudioID.replacesNothing ? nil : slot(ofStation: command.replaces)
            guard freeSlot != nil || replacedSlot != nil else { return }
            commands.discardNext()

            guard command.generation == currentGeneration,
                  (0..<Self.programCount).contains(command.identifier),
                  let view = registryViews[command.identifier] else {
                _ = retired.tryPush(command.identifier)
                continue
            }
            let elapsed = Int64(renderedFrames.load(ordering: .relaxed)) - command.referenceFrame
            if command.replaces == AudioID.replacesNothing {
                guard let freeSlot else { continue }   // unreachable: checked above
                start(view, id: command.identifier, in: freeSlot, playhead: view.startPlayhead(elapsed: elapsed))
            } else if let replacedSlot {
                // Take over in place: the playhead and the renderer's envelope
                // state carry on, so the swap is inaudible.
                if retired.tryPush(activeIDs[replacedSlot]) {
                    views[replacedSlot] = view
                    activeIDs[replacedSlot] = command.identifier
                } else {
                    _ = retired.tryPush(command.identifier)
                }
            } else if let freeSlot {
                // The program being replaced has already finished: carry on
                // from where it would be. A playhead of zero would make the
                // renderer restart the envelope, hence at least one.
                start(view, id: command.identifier, in: freeSlot, playhead: max(1, elapsed))
            }
        }
    }

    private func retireFinishedPrograms() {
        for slot in 0..<Self.slotCount {
            guard let view = views[slot], isActive(slot), playheads[slot] >= view.sampleCount else { continue }
            retire(slot)
        }
    }

    private func isActive(_ slot: Int) -> Bool { activeIDs[slot] != AudioID.none }

    private func firstFreeSlot() -> Int? {
        for slot in 0..<Self.slotCount where !isActive(slot) { return slot }
        return nil
    }

    private func slot(ofStation stationID: Int) -> Int? {
        for slot in 0..<Self.slotCount where isActive(slot) && views[slot]?.stationID == stationID { return slot }
        return nil
    }

    private func start(_ view: MRCEAudioProgramView, id: Int, in slot: Int, playhead: Int64) {
        views[slot] = view
        playheads[slot] = playhead
        activeIDs[slot] = id
    }

    /// Empties a slot and returns its program to the control side. If the
    /// retirement ring is full the slot is kept and retried on a later callback.
    private func retire(_ slot: Int) {
        let id = activeIDs[slot]
        guard id != AudioID.none, retired.tryPush(id) else { return }
        views[slot] = nil
        playheads[slot] = 0
        activeIDs[slot] = AudioID.none
    }
}

// MARK: - FieldAudio

/// The app's audio output: an AVAudioEngine source node fed by the portable
/// streaming MRCE receiver DSP.
@MainActor final class FieldAudio {
    typealias StartCompletion = @MainActor @Sendable (Result<Void, SessionDriver.AudioFailure>) -> Void
    typealias PlayCompletion = @MainActor @Sendable (Result<Double, SessionDriver.AudioFailure>) -> Void

    /// The text of one transmission and how it is keyed.
    struct KeyedMessage {
        var text: String
        var wpm: Int
        var characterWpm: Int? = nil
        var fastReportStart: Int? = nil
        var fastReportRate: Double = 1.0
        var fastReportStarts: [Int]? = nil

        /// Keyed length in seconds, before any padding.
        var seconds: Double {
            MorseTimeline.duration(text, wpm: wpm, characterWpm: characterWpm, fastReportStart: fastReportStart,
                                   fastReportRate: fastReportRate, fastReportStarts: fastReportStarts)
        }
    }

    // MARK: Queues

    /// AVAudioSession calls can block while the system coordinates other audio clients.
    /// Keep them ordered, but off the main thread so lifecycle changes cannot stall SwiftUI.
    nonisolated private static let audioSessionQueue = DispatchQueue(label: "MorseJogger.audio-session", qos: .userInitiated)
    /// Everything that reaches the engine or the render thread: engine
    /// operations, building programs and publishing them. One serial queue,
    /// so sounds reach the render thread in the order they were asked for
    /// and a cancel cannot overtake the sound it cancels.
    nonisolated private static let audioQueue = DispatchQueue(label: "MorseJogger.audio-graph", qos: .default)
    nonisolated private static let recordingQueue = DispatchQueue(label: "MorseJogger.audio-recording", qos: .utility)

    /// Keep graph work serialized while allowing a blocking engine stop to run
    /// at default QoS instead of waiting at user-interactive priority.
    nonisolated private static func audioGraphAsync(qos: DispatchQoS = .userInteractive,
                                                    execute work: @escaping @Sendable () -> Void) {
        audioQueue.async(qos: qos, flags: .enforceQoS, execute: work)
    }

    // MARK: State

    private let engine = AVAudioEngine()
    /// Two channels carrying the same samples. A one-channel source is spread
    /// across the mixer's stereo output at -3 dB per channel (equal-power
    /// panning), which would throw away half the available level.
    private let format = AVAudioFormat(standardFormatWithSampleRate: AudioConstants.sampleRate, channels: 2)!
    private let renderState = MRCEAudioRenderState(sampleRate: AudioConstants.sampleRate,
                                                   center: AudioConstants.defaultPitchHz,
                                                   bandwidth: AudioConstants.defaultBandwidthHz)
    private var sourceNode: AVAudioSourceNode!
    private var configuredSettings = ContestSettings()

    /// One audio station ID per caller, so a caller keeps its fading
    /// character from one transmission to the next and can be cancelled.
    private var stationAudioIDs: [String: Int] = [:]
    private var nextStationAudioID = AudioID.firstCallerStation

    /// Own transmissions queued or under way, so a call edited while it is
    /// being keyed can be replaced and what follows it moved.
    private struct QueuedTransmit {
        /// The simulator's name for this transmission (`RadioEvent.pieceID`).
        var pieceID: Int
        var stationID: Int
        var generation: Int
        var referenceFrame: Int64
        var startDelaySamples: Int64
        var durationFrames: Int64
        var message: KeyedMessage
        var pitch: Int
        var level: Float
        var endFrame: Int64 { referenceFrame + startDelaySamples + durationFrames }
    }
    private var transmitQueue: [QueuedTransmit] = []
    private var transmitFrameScheduler = TransmitFrameScheduler()
    private var nextTransmitAudioID = AudioID.firstTransmitStation

    var muted = false { didSet { renderState.setMuted(muted) } }
    var monitorDecibels = 0 {
        didSet {
            monitorDecibels = min(AudioConstants.monitorRange.upperBound,
                                  max(AudioConstants.monitorRange.lowerBound, monitorDecibels))
        }
    }

    // Lifecycle.
    private var sessionActivationPending = false
    private var sessionActive = false
    private var pendingStartCompletions: [StartCompletion] = []
    /// Bumped whenever activation or shutdown starts, so a stale asynchronous
    /// result is ignored.
    private var lifecycleGeneration = 0
    private var suspended = false
    private var audioSystemObservers: [NSObjectProtocol] = []

    // Recording.
    private var recording: AVAudioFile?
    private var recordingGeneration = 0
    private var recordingSetupPending = false
    private var recordingTeardownPending = false
    private var recordingStopCompletions: [@MainActor @Sendable () -> Void] = []

    // MARK: Set-up

    init() {
        observeAudioSystem()
        let engine = engine, format = format, renderState = renderState
        let source = AVAudioSourceNode(format: format) { silence, _, frameCount, audioBufferList in
            let status = Self.render(into: audioBufferList, frameCount: frameCount, format: format, state: renderState)
            if status == noErr { silence.pointee = false }
            return status
        }
        sourceNode = source
        Self.audioGraphAsync {
            engine.attach(source)
            engine.connect(source, to: engine.mainMixerNode, format: format)
        }
    }

    deinit {
        audioSystemObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The source node's render callback. Renders one channel and copies it to
    /// the other. The AudioBufferList and its sample pointers are borrowed for
    /// this call only and must never escape it.
    nonisolated private static func render(
        into audioBufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount,
        format: AVAudioFormat,
        state: MRCEAudioRenderState
    ) -> OSStatus {
        guard format.commonFormat == .pcmFormatFloat32,
              format.channelCount == 2,
              !format.isInterleaved else { return kAudio_ParamError }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let sampleCount = Int(frameCount)
        let byteCount = sampleCount * MemoryLayout<Float>.size
        guard buffers.count == 2,
              buffers[0].mNumberChannels == 1, buffers[1].mNumberChannels == 1,
              let first = buffers[0].mData, let second = buffers[1].mData,
              Int(buffers[0].mDataByteSize) >= byteCount,
              Int(buffers[1].mDataByteSize) >= byteCount else {
            return kAudio_ParamError
        }

        state.render(UnsafeMutableBufferPointer(start: first.assumingMemoryBound(to: Float.self), count: sampleCount))
        second.copyMemory(from: first, byteCount: byteCount)
        return noErr
    }

    /// Restarts the engine after a route or configuration change.
    private func observeAudioSystem() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        let engine = engine, renderState = renderState

        audioSystemObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { _ in
            Self.audioGraphAsync { Self.restartEngineIfNeeded(engine, renderState: renderState) }
        })
        audioSystemObservers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
            Self.audioGraphAsync { Self.restartEngineIfNeeded(engine, renderState: renderState) }
        })
    }

    nonisolated private static func restartEngineIfNeeded(_ engine: AVAudioEngine, renderState: MRCEAudioRenderState) {
        guard renderState.shouldRun.isSet, !engine.isRunning else { return }
        do { try engine.start() }
        catch { NSLog("CW Field audio route restart failed: %@", String(describing: error)) }
    }

    // MARK: Lifecycle

    /// Activates the audio session if needed, then starts the engine.
    func start(completion: @escaping StartCompletion = { _ in }) {
        guard !suspended else { completion(.failure(.suspended)); return }
        if sessionActivationPending { pendingStartCompletions.append(completion); return }
        if sessionActive { startEngine(completion: completion); return }

        sessionActivationPending = true
        pendingStartCompletions.append(completion)
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        Self.audioSessionQueue.async { [weak self] in
            let result: Result<Void, Error>
            do {
                let session = AVAudioSession.sharedInstance()
                // Plain playback: other apps' audio stops while a session runs.
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
                result = .success(())
            } catch { result = .failure(error) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lifecycleGeneration == generation else { return }
                self.sessionActivationPending = false
                let completions = self.pendingStartCompletions
                self.pendingStartCompletions.removeAll(keepingCapacity: true)
                switch result {
                case .success:
                    guard !self.suspended else { completions.forEach { $0(.failure(.suspended)) }; return }
                    self.sessionActive = true
                    self.startEngine { result in completions.forEach { $0(result) } }
                case .failure(let error):
                    NSLog("CW Field audio activation failed: %@", String(describing: error))
                    let failure = SessionDriver.AudioFailure.sessionActivation(String(describing: error))
                    completions.forEach { $0(.failure(failure)) }
                }
            }
        }
    }

    /// Engine operations stay on the graph queue. A request that pause or
    /// shutdown has overtaken is dropped.
    private func startEngine(completion: StartCompletion? = nil) {
        let engine = engine, state = renderState
        state.engineRequestGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)
        let request = state.engineRequestGeneration.load(ordering: .acquiring)
        state.shouldRun.set(true)
        Self.audioGraphAsync {
            guard state.engineRequestGeneration.load(ordering: .acquiring) == request, state.shouldRun.isSet else {
                if let completion { DispatchQueue.main.async { completion(.failure(.suspended)) } }
                return
            }
            let result: Result<Void, SessionDriver.AudioFailure>
            do {
                if !engine.isRunning { try engine.start() }
                result = .success(())
            } catch {
                NSLog("CW Field audio start failed: %@", String(describing: error))
                result = .failure(.engineStart(String(describing: error)))
            }
            if let completion { DispatchQueue.main.async { completion(result) } }
        }
    }

    func resume(completion: @escaping StartCompletion = { _ in }) {
        suspended = false
        start(completion: completion)
    }

    /// Pauses the engine. The render callback stops without a change of
    /// generation, so keyed programs and their playheads stay where they are
    /// and continue from the same frame after `resume`.
    func suspend() {
        suspended = true
        sessionActive = false
        renderState.shouldRun.set(false)
        renderState.engineRequestGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)
        let engine = engine
        Self.audioGraphAsync { engine.pause() }
    }

    /// Ask the system whether this app's playback session can be activated
    /// after returning to the foreground. An active interruption (for example
    /// a call) keeps this from succeeding; this lets lifecycle code recover
    /// from an interruption-ended notification lost while iOS suspended us.
    func reconcileForegroundInterruption(_ completion: @escaping (Bool) -> Void) {
        Self.audioSessionQueue.async { [weak self] in
            let activated: Bool
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                activated = true
            } catch {
                NSLog("CW Field audio foreground reconciliation deferred: %@", String(describing: error))
                activated = false
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if activated { self.sessionActive = true }
                completion(activated)
            }
        }
    }

    /// Stops everything: discards queued audio, ends any recording, stops the
    /// engine and gives up the audio session.
    func shutdown() {
        suspended = false
        sessionActivationPending = false
        pendingStartCompletions.removeAll(keepingCapacity: true)
        sessionActive = false
        renderState.shouldRun.set(false)
        renderState.engineRequestGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)
        renderState.generation.wrappingAdd(1, ordering: .acquiringAndReleasing)
        // A new session starts with no callers; keep the IDs counting up so
        // none is ever reused for a different station.
        stationAudioIDs.removeAll(keepingCapacity: true)
        transmitQueue.removeAll(keepingCapacity: true)
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        let engine = engine
        endRecording { [weak self] in
            guard let self, self.lifecycleGeneration == generation else { return }
            Self.audioGraphAsync(qos: .default) { [weak self] in
                engine.stop()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lifecycleGeneration == generation else { return }
                    Self.audioSessionQueue.async {
                        do { try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation]) }
                        catch { NSLog("CW Field audio deactivation failed: %@", String(describing: error)) }
                    }
                }
            }
        }
    }

    /// Silences everything queued or sounding (Esc, or the end of a session).
    func stopPlayback() {
        renderState.generation.wrappingAdd(1, ordering: .acquiringAndReleasing)
    }

    /// Applies the radio settings for a session and starts the audio.
    func configureReceiver(settings: ContestSettings, completion: @escaping StartCompletion = { _ in }) {
        configuredSettings = settings
        renderState.setSettings(settings)
        start(completion: completion)
    }

    // MARK: Own transmissions

    /// Queues one of the operator's own transmissions behind any already
    /// queued. Returns its on-air length in seconds, which `completion` also
    /// reports once the render thread has accepted it.
    ///
    /// A muted message is still queued (the renderer silences the output), so
    /// unmuting part-way through lets the rest be heard.
    @discardableResult
    func playTransmit(_ message: KeyedMessage, pitch: Int, effects: Effects, qsk: Bool, pieceID: Int?,
                      completion: @escaping PlayCompletion = { _ in }) -> Double {
        // Own transmissions end on MRCE's 512-sample block boundary:
        // callers time their replies from that moment.
        let onAir = MorseTimeline.blockPadded(message.seconds)
        guard !suspended else { completion(.failure(.suspended)); return onAir }
        start()
        var radioSettings = configuredSettings
        radioSettings.pitch = pitch; radioSettings.effects = effects; radioSettings.qsk = qsk
        renderState.setSettings(radioSettings)

        let state = renderState
        let generation = state.generation.load(ordering: .acquiring)
        let currentFrame = Int64(state.renderedFrames.load(ordering: .acquiring))
        let durationFrames = frames(onAir)
        let schedule = transmitFrameScheduler.schedule(currentFrame: currentFrame, generation: generation,
                                                       durationFrames: durationFrames, spacingFrames: 0)
        nextTransmitAudioID -= 1
        let entry = QueuedTransmit(pieceID: pieceID ?? AudioID.none, stationID: nextTransmitAudioID, generation: generation,
                                   referenceFrame: schedule.referenceFrame, startDelaySamples: schedule.startDelaySamples,
                                   durationFrames: durationFrames, message: message, pitch: pitch,
                                   level: MRCEAudioProgram.sourceSidetoneAmplitude(decibels: monitorDecibels))
        forgetFinishedTransmits(generation: generation, currentFrame: currentFrame)
        // Only a transmission the simulator can name can be re-keyed later.
        if pieceID != nil { transmitQueue.append(entry) }

        Self.audioGraphAsync {
            let program = Self.makeTransmitProgram(entry)
            let accepted = state.publish(program, generation: entry.generation, referenceFrame: entry.referenceFrame)
            DispatchQueue.main.async { completion(accepted ? .success(onAir) : .failure(.programRejected)) }
        }
        return onAir
    }

    /// MRCE `SendPos` for one own transmission: the seconds of it already
    /// rendered into the output buffer. Zero or less means it has not
    /// started; infinity means it has gone.
    ///
    /// A replacement is published from another thread and picked up at the
    /// start of a render callback, so the one callback that may run in
    /// between is counted as rendered too.
    func transmitSecondsBuffered(pieceID: Int) -> Double {
        let generation = renderState.generation.load(ordering: .acquiring)
        guard let entry = transmitQueue.first(where: { $0.pieceID == pieceID && $0.generation == generation }) else {
            return .infinity
        }
        let rendered = Int64(renderState.renderedFrames.load(ordering: .acquiring))
            + Int64(renderState.renderQuantum.load(ordering: .relaxed))
        guard rendered < entry.endFrame else { return .infinity }
        return Double(rendered - entry.referenceFrame - entry.startDelaySamples) / format.sampleRate
    }

    /// MRCE `MyStn.UpdateCallInMessage`, audio side: the named transmission
    /// takes the new text from wherever its playhead is, and every
    /// transmission queued behind it moves by the change in length. The
    /// simulator has already checked that what has been keyed so far is the
    /// same in both texts.
    func rekeyTransmit(pieceID: Int, text: String, wpm: Int, characterWpm: Int?) {
        let state = renderState
        let generation = state.generation.load(ordering: .acquiring)
        let currentFrame = Int64(state.renderedFrames.load(ordering: .acquiring))
        forgetFinishedTransmits(generation: generation, currentFrame: currentFrame)
        guard let index = transmitQueue.firstIndex(where: { $0.pieceID == pieceID }) else { return }

        // A call carries no report, so the re-keyed text has no fast section.
        let message = KeyedMessage(text: text, wpm: wpm, characterWpm: characterWpm)
        let newDuration = frames(MorseTimeline.blockPadded(message.seconds))
        let change = newDuration - transmitQueue[index].durationFrames
        transmitQueue[index].message = message
        transmitQueue[index].durationFrames = newDuration
        for later in transmitQueue.indices where later > index { transmitQueue[later].startDelaySamples += change }
        transmitFrameScheduler.shift(by: change)

        // The re-keyed transmission and everything behind it are rebuilt, each
        // taking over from its predecessor under a fresh station ID.
        for position in transmitQueue.indices where position >= index {
            let replaced = transmitQueue[position].stationID
            nextTransmitAudioID -= 1
            transmitQueue[position].stationID = nextTransmitAudioID
            let entry = transmitQueue[position]
            Self.audioGraphAsync {
                let program = Self.makeTransmitProgram(entry)
                _ = state.publish(program, generation: entry.generation, referenceFrame: entry.referenceFrame,
                                  replacing: replaced)
            }
        }
    }

    nonisolated private static func makeTransmitProgram(_ entry: QueuedTransmit) -> MRCEAudioProgram {
        let message = entry.message
        return MRCEAudioProgram(message: message.text, wpm: message.wpm, characterWpm: message.characterWpm,
                                frequency: Double(entry.pitch), level: entry.level,
                                sampleRate: AudioConstants.sampleRate,
                                fastReportStart: message.fastReportStart, fastReportRate: message.fastReportRate,
                                fastReportStarts: message.fastReportStarts,
                                startDelaySamples: entry.startDelaySamples,
                                channel: .transmit, stationID: entry.stationID)
    }

    private func forgetFinishedTransmits(generation: Int, currentFrame: Int64) {
        transmitQueue.removeAll { $0.generation != generation || $0.endFrame <= currentFrame }
    }

    private func frames(_ seconds: Double) -> Int64 { Int64((seconds * format.sampleRate).rounded()) }

    // MARK: Callers and QRM

    /// Starts every voice of one receive or interference event. Returns the
    /// duration to acknowledge to the simulator, which `completion` also
    /// reports once the render thread has accepted the programs.
    @discardableResult
    func playReceive(event: RadioEvent, settings: ContestSettings, simulationNow: Double? = nil,
                     completion: @escaping PlayCompletion = { _ in }) -> Double {
        let voices = event.voices.isEmpty
            ? [RadioVoice(station: Station(call: "", exchange: "", wpm: settings.wpm, tone: settings.pitch, volume: 1, shift: 0),
                          message: event.text)]
            : event.voices
        let longest = voices.map { voice in
            MorseTimeline.duration(voice.message, wpm: voice.wpm, characterWpm: max(voice.wpm, voice.characterWpm),
                                   fastReportStart: voice.fastReportStart, fastReportRate: voice.fastReportRate,
                                   fastReportStarts: voice.effectiveFastReportStarts,
                                   farnsworthKeyer: voice.farnsworthKeyer)
        }.max() ?? 0
        let acknowledged = longest + AudioConstants.receiveTailSeconds + AudioConstants.receiveAcknowledgementMarginSeconds
        guard !suspended else { completion(.failure(.suspended)); return acknowledged }
        start()
        renderState.setSettings(settings)

        let isInterference = event.kind == .interference
        let channel: MRCEAudioChannel = isInterference ? .interference : .receive
        // Callers keep a station ID across transmissions; QRM is anonymous.
        let stationIDs = voices.map { voice in
            isInterference || voice.call.isEmpty ? AudioID.anonymousStation : audioStationID(for: voice.call)
        }
        // QRM is published ahead of its time and starts when that time comes.
        let startDelay = isInterference ? frames(max(0, event.at - (simulationNow ?? event.at))) : 0

        let state = renderState, sampleRate = format.sampleRate
        let referenceFrame = Int64(state.renderedFrames.load(ordering: .acquiring))
        let generation = state.generation.load(ordering: .acquiring)
        Self.audioGraphAsync {
            let programs = zip(voices, stationIDs).map { voice, stationID in
                // The RF amplitude is drawn once when the simulator creates a
                // station and copied into each voice. Receive volume is applied
                // after the receiver and AGC, so source levels stay independent.
                let amplitude = voice.rfAmplitude ?? Double(MRCEAudioProgram.sourceStationAmplitude(uShaped: 0))
                return MRCEAudioProgram(message: voice.message, wpm: voice.wpm,
                                        characterWpm: max(voice.wpm, voice.characterWpm),
                                        frequency: RadioTuning.signalFrequency(voice), level: Float(amplitude),
                                        sampleRate: sampleRate,
                                        fastReportStart: voice.fastReportStart, fastReportRate: voice.fastReportRate,
                                        fastReportStarts: voice.effectiveFastReportStarts,
                                        startDelaySamples: startDelay, channel: channel, stationID: stationID,
                                        farnsworthKeyer: voice.farnsworthKeyer)
            }
            let accepted = programs.allSatisfy { state.publish($0, generation: generation, referenceFrame: referenceFrame) }
            DispatchQueue.main.async { completion(accepted ? .success(acknowledged) : .failure(.programRejected)) }
        }
        return acknowledged
    }

    func cancelReceive(call: String) {
        guard let stationID = stationAudioIDs[call] else { return }
        let state = renderState
        Self.audioGraphAsync { state.cancel(stationID: stationID) }
    }

    private func audioStationID(for call: String) -> Int {
        if let id = stationAudioIDs[call] { return id }
        let id = nextStationAudioID
        nextStationAudioID += 1
        stationAudioIDs[call] = id
        return id
    }

    // MARK: Recording

    /// Records the mixer's output to a WAV file in the temporary directory.
    /// Any recording already running is ended first.
    func beginRecording(completion: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void) {
        endRecording { [weak self] in
            guard let self else { return }
            self.start()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("MorseJogger-\(UUID().uuidString.prefix(8)).wav")
            self.recordingGeneration += 1
            let generation = self.recordingGeneration
            self.recordingSetupPending = true
            let engine = self.engine
            Self.audioGraphAsync { [weak self] in
                let result: Result<AVAudioFile, Error>
                do {
                    let mixer = engine.mainMixerNode
                    let output = mixer.outputFormat(forBus: 0)
                    let file = try AVAudioFile(forWriting: url, settings: output.settings,
                                               commonFormat: output.commonFormat, interleaved: output.isInterleaved)
                    mixer.installTap(onBus: 0, bufferSize: AudioConstants.recordingTapFrames, format: output) { buffer, _ in
                        // Tap buffers belong to the engine and may be reused as
                        // soon as this returns, so copy before the file write.
                        guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
                        Self.recordingQueue.async { try? file.write(from: copy) }
                    }
                    result = .success(file)
                } catch { result = .failure(error) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.recordingSetupPending = false
                    guard self.recordingGeneration == generation else {
                        // Ended, or superseded, while the tap was being installed.
                        if case .success(let file) = result {
                            self.recordingTeardownPending = true
                            self.removeTapAndClose(file) {}
                        } else {
                            self.recordingTeardownPending = false
                            self.finishPendingRecordingStops()
                        }
                        return
                    }
                    switch result {
                    case .success(let file):
                        self.recording = file
                        completion(.success(url))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// Ends the recording, if any. `completion` runs once the file is closed,
    /// including when a recording was still being set up.
    func endRecording(completion: (@MainActor @Sendable () -> Void)? = nil) {
        recordingGeneration += 1
        guard let file = recording else {
            if recordingSetupPending || recordingTeardownPending {
                recordingTeardownPending = true
                if let completion { recordingStopCompletions.append(completion) }
            } else {
                completion?()
            }
            return
        }
        recording = nil
        recordingTeardownPending = true
        removeTapAndClose(file) { completion?() }
    }

    /// Removes the tap, lets writes already queued finish, then releases the
    /// file (which closes it) and runs the waiting completions.
    private func removeTapAndClose(_ file: AVAudioFile, then completion: @escaping @MainActor @Sendable () -> Void) {
        let engine = engine
        Self.audioGraphAsync {
            engine.mainMixerNode.removeTap(onBus: 0)
            Self.recordingQueue.async {
                _ = file
                DispatchQueue.main.async {
                    self.recordingTeardownPending = false
                    completion()
                    self.finishPendingRecordingStops()
                }
            }
        }
    }

    private func finishPendingRecordingStops() {
        let completions = recordingStopCompletions
        recordingStopCompletions.removeAll()
        completions.forEach { $0() }
    }
}
