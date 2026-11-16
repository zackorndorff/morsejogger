//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import Foundation
import MorseJoggerCore

/// Owns the live simulator loop and the boundary between simulator events and
/// the app's audio renderer. Presentation stays in FieldViewModel.
@MainActor final class SessionDriver {
    enum AudioFailure: Error, Equatable, Sendable {
        case sessionActivation(String)
        case engineStart(String)
        case programRejected
        case suspended

        var userMessage: String {
            switch self {
            case .sessionActivation, .engineStart:
                return "Audio could not start. Check the audio route, then retry."
            case .programRejected:
                return "Audio could not queue this message. Retry to continue the exchange."
            case .suspended:
                return "Audio is paused. Return to the session and retry."
            }
        }
    }

    enum AudioAcknowledgement {
        case transmit(duration: Double)
        case receive(duration: Double)
        case failed(AudioFailure)
        case none
    }

    typealias AudioCompletion = @MainActor (AudioAcknowledgement) -> Void
    typealias AudioStartCompletion = @MainActor @Sendable (Result<Void, AudioFailure>) -> Void
    typealias MonotonicClock = @MainActor () -> TimeInterval

    private var simulator: ContestSimulator?
    private(set) var events: [RadioEvent] = []
    private(set) var snapshot: SessionSnapshot?
    private(set) var log: [QSOEntry] = []
    private(set) var isPaused = false
    private(set) var audioHasStarted = false
    private(set) var audioFailure: AudioFailure?

    var dispatchAudio: ((RadioEvent, ContestSettings, Double, @escaping AudioCompletion) -> Void)?
    var onEvent: ((RadioEvent) -> Void)?
    var onStopAudio: (() -> Void)?
    var onAudioStart: ((ContestSettings, @escaping AudioStartCompletion) -> Void)?
    var onAudioSuspend: (() -> Void)?
    var onAudioResume: ((@escaping (Result<Void, AudioFailure>) -> Void) -> Void)?
    var onAudioFailure: ((AudioFailure) -> Void)?
    var onFinished: (() -> Void)?
    var onChange: (() -> Void)?

    private let monotonicClock: MonotonicClock
    /// The simulator's clock is a stopwatch: it runs only while audio is
    /// started and nothing has paused the session. Time already run is kept
    /// in `accumulatedSeconds`; `runningSince` is when it was last started.
    /// Stopping and starting it therefore cannot lose, repeat or skip time,
    /// however pauses and audio start-up interleave.
    private var accumulatedSeconds: TimeInterval = 0
    private var runningSince: TimeInterval?
    /// When the current pause began; also identifies it to a pending resume.
    private var pauseStarted: TimeInterval?
    private var sceneActive = true
    private var audioInterrupted = false
    private var sessionControlsPresented = false
    private var failedAudioRetry: (() -> Void)?
    private var pendingAudioDispatches: [() -> Void] = []
    private var audioResumePending = false
    private var sessionGeneration: UInt64 = 0
    var isSceneActive: Bool { sceneActive }
    var isAudioInterrupted: Bool { audioInterrupted }
    var areSessionControlsPresented: Bool { sessionControlsPresented }

    init(monotonicClock: @escaping MonotonicClock = { ProcessInfo.processInfo.systemUptime }) {
        self.monotonicClock = monotonicClock
    }

    private var simulationTime: TimeInterval {
        accumulatedSeconds + (runningSince.map { monotonicClock() - $0 } ?? 0)
    }
    private func startClock() {
        if runningSince == nil { runningSince = monotonicClock() }
    }
    private func stopClock() {
        guard let since = runningSince else { return }
        accumulatedSeconds += monotonicClock() - since
        runningSince = nil
    }

    var settings: ContestSettings? { simulator?.settings }
    var target: Station? { simulator?.target }
    var pileup: [Station] { simulator?.pileup ?? [] }
    var running: Bool { simulator?.running == true }

    func start(settings: ContestSettings, genericHistory: ImportedHistory?) {
        sessionGeneration &+= 1
        audioResumePending = false
        let game = ContestSimulator(settings: settings, genericHistory: genericHistory)
        simulator = game
        game.start()
        snapshot = game.snapshot
        events = []
        log = []
        accumulatedSeconds = 0
        runningSince = nil
        pauseStarted = nil
        isPaused = false
        audioFailure = nil
        failedAudioRetry = nil
        pendingAudioDispatches = []
        sessionControlsPresented = false
        audioHasStarted = false
        synchronizeLifecycle()
        publish()
        startAudioIfReady()
        drainEvents()
    }

    func updateRadio(_ settings: ContestSettings) { simulator?.updateRadio(settings); publish() }

    /// Returns whether the command added a log entry, so the view model can
    /// clear its input fields without inspecting simulator state.
    @discardableResult
    func send(_ command: Command, call: String, exchange: String,
              exchangeFirst: String? = nil, exchangeSecond: String? = nil) -> Bool {
        guard let game = simulator else { return false }
        guard pauseStarted == nil || command == .stop else { return false }
        // Bring the simulator clock up to now so the command is not stamped
        // up to one timer interval early.
        if audioHasStarted { game.tick(simulationTime) }
        let before = game.log.count
        game.command(command, call: call, exchange: exchange, exchangeFirst: exchangeFirst, exchangeSecond: exchangeSecond)
        if command == .stop { onStopAudio?() }
        drainEvents()
        snapshot = game.snapshot
        log = game.log
        publish()
        return game.log.count > before
    }

    /// MRCE `Edit1Change`: every edit of the call box reaches the simulator,
    /// which re-keys a call still being sent or marks it as owed again.
    /// `sentSeconds` reports how much of an own transmission the audio host
    /// has already handed to its output buffer.
    func callEdited(_ call: String, sentSeconds: @escaping (Int) -> Double) {
        guard let game = simulator, pauseStarted == nil else { return }
        if audioHasStarted { game.tick(simulationTime) }
        game.callEdited(call, sentSeconds: sentSeconds)
        drainEvents()
    }
    func cancelEntryAdvance() { simulator?.cancelEntryAdvance() }

    func stop() {
        sessionGeneration &+= 1
        audioResumePending = false
        simulator?.stopSession()
        drainEvents()
        finish()
    }

    func reset() {
        sessionGeneration &+= 1
        audioResumePending = false
        simulator = nil
        snapshot = nil
        events = []
        log = []
        pauseStarted = nil
        accumulatedSeconds = 0
        runningSince = nil
        isPaused = false
        audioHasStarted = false
        audioFailure = nil
        failedAudioRetry = nil
        pendingAudioDispatches = []
        publish()
    }

    func sceneDidChange(active: Bool) {
        sceneActive = active
        synchronizeLifecycle()
    }

    func audioInterruption(began: Bool) {
        audioInterrupted = began
        synchronizeLifecycle()
    }

    func setSessionControlsPresented(_ presented: Bool) {
        sessionControlsPresented = presented
        synchronizeLifecycle()
    }

    func clearStaleInterruption() {
        audioInterrupted = false
        synchronizeLifecycle()
    }

    /// Retry the exact event whose audio could not be started or queued.
    func retryAudio() {
        guard audioFailure != nil else { return }
        let retry = failedAudioRetry
        audioFailure = nil
        failedAudioRetry = nil
        audioHasStarted = false
        stopClock()
        let shouldPause = !sceneActive || audioInterrupted || sessionControlsPresented
        if shouldPause { failedAudioRetry = retry; synchronizeLifecycle(); return }
        if let began = pauseStarted {
            resumeAudio(from: began) {
                retry?()
                self.flushPendingAudio()
            }
            return
        }
        startAudioIfReady {
            retry?()
            self.flushPendingAudio()
        }
        publish()
    }

    func tick() {
        guard let game = simulator, pauseStarted == nil, audioHasStarted else { return }
        game.tick(simulationTime)
        drainEvents()
        snapshot = game.snapshot
        log = game.log
        publish()
        if !game.running { finish() }
    }

    private func drainEvents() {
        guard let game = simulator else { return }
        for event in game.drainEvents() {
            events.insert(event, at: 0)
            if events.count > 100 { events.removeLast() }
            onEvent?(event)
            switch event.kind {
            case .transmit, .receive:
                let settings = game.settings
                let simulationNow = game.elapsed
                pendingAudioDispatches.append { [weak self, weak game] in
                    guard let self, let game else { return }
                    self.dispatch(event, game: game, settings: settings, simulationNow: simulationNow)
                }
            case .rekey:
                // Queued behind the transmit event it amends.
                let settings = game.settings
                let simulationNow = game.elapsed
                pendingAudioDispatches.append { [weak self] in
                    self?.dispatchAudio?(event, settings, simulationNow) { _ in }
                }
            case .advanceEntry: break
            case .interference, .cancelReceive:
                dispatchAudio?(event, game.settings, game.elapsed) { _ in }
            case .stopAudio: onStopAudio?()
            case .finished: break
            case .notice: break
            }
        }
        flushPendingAudio()
        publish()
    }

    private func dispatch(_ event: RadioEvent, game: ContestSimulator,
                          settings: ContestSettings, simulationNow: Double) {
        guard let dispatchAudio else { return }
        let generation = sessionGeneration
        let retry = { [weak self, weak game] in
            guard let self, let game, self.sessionGeneration == generation else { return }
            self.dispatch(event, game: game, settings: settings, simulationNow: simulationNow)
        }
        dispatchAudio(event, settings, simulationNow) { [weak self, weak game] acknowledgement in
            guard let self, let game, self.sessionGeneration == generation else { return }
            self.apply(acknowledgement, to: game, event: event, retry: retry)
        }
    }

    private func apply(_ acknowledgement: AudioAcknowledgement, to game: ContestSimulator,
                       event: RadioEvent, retry: @escaping () -> Void) {
        guard simulator === game else { return }
        switch acknowledgement {
        case .transmit(let duration):
            audioFailure = nil
            failedAudioRetry = nil
            game.acknowledgeTransmit(duration: duration, startedAt: event.at)
        case .receive(let duration):
            audioFailure = nil
            failedAudioRetry = nil
            game.acknowledgeReceive(duration: duration, calls: event.stationCalls)
        case .failed(let failure):
            audioFailure = failure
            failedAudioRetry = retry
            if audioHasStarted { onAudioSuspend?() }
            audioHasStarted = false
            stopClock()
            synchronizeLifecycle()
            onAudioFailure?(failure)
        case .none:
            break
        }
        snapshot = game.snapshot
        publish()
    }

    private func startAudioIfReady(then ready: (() -> Void)? = nil) {
        guard !audioHasStarted, running, pauseStarted == nil, let settings else { return }
        let generation = sessionGeneration
        onAudioStart?(settings) { [weak self] result in
            guard let self, self.sessionGeneration == generation else { return }
            switch result {
            case .success:
                self.audioHasStarted = true
                if self.pauseStarted == nil { self.startClock() }
                else { self.onAudioSuspend?() }
                if let ready { ready() }
                if self.pauseStarted == nil { self.flushPendingAudio() }
            case .failure(let failure):
                self.audioFailure = failure
                self.failedAudioRetry = ready
                self.audioHasStarted = false
                self.synchronizeLifecycle()
                self.onAudioFailure?(failure)
            }
            self.publish()
        }
    }

    private func flushPendingAudio() {
        guard audioHasStarted, pauseStarted == nil, !pendingAudioDispatches.isEmpty else { return }
        let dispatches = pendingAudioDispatches
        pendingAudioDispatches.removeAll(keepingCapacity: true)
        dispatches.forEach { $0() }
    }

    private func synchronizeLifecycle() {
        guard running else { return }
        let shouldPause = !sceneActive || audioInterrupted || sessionControlsPresented || audioFailure != nil
        if shouldPause, pauseStarted == nil {
            stopClock()
            pauseStarted = monotonicClock()
            isPaused = true
            if audioHasStarted { onAudioSuspend?() }
            publish()
        } else if !shouldPause, let began = pauseStarted, !audioResumePending {
            if audioHasStarted { resumeAudio(from: began) }
            else {
                // Audio has not started yet; the clock starts when it does.
                pauseStarted = nil
                isPaused = false
                publish()
                startAudioIfReady { [weak self] in
                    guard let self else { return }
                    let retry = self.failedAudioRetry
                    self.failedAudioRetry = nil
                    retry?()
                }
                flushPendingAudio()
            }
        }
    }

    private func resumeAudio(from began: TimeInterval, then ready: (() -> Void)? = nil) {
        audioResumePending = true
        let generation = sessionGeneration
        let completion: (Result<Void, AudioFailure>) -> Void = { [weak self] result in
            guard let self else { return }
            guard self.sessionGeneration == generation else { return }
            self.audioResumePending = false
            guard self.pauseStarted == began else { return }
            switch result {
            case .success:
                guard self.sceneActive && !self.audioInterrupted && !self.sessionControlsPresented && self.audioFailure == nil else { return }
                self.audioHasStarted = true
                self.pauseStarted = nil
                self.startClock()
                self.isPaused = false
                self.publish()
                ready?()
                self.flushPendingAudio()
            case .failure(let failure):
                self.audioFailure = failure
                self.failedAudioRetry = ready
                self.audioHasStarted = false
                self.onAudioFailure?(failure)
            }
            self.publish()
        }
        if let onAudioResume { onAudioResume(completion) }
        else { completion(.success(())) }
    }

    private func finish() {
        snapshot = simulator?.snapshot
        log = simulator?.log ?? []
        onFinished?()
        publish()
    }

    private func publish() { onChange?() }
}
