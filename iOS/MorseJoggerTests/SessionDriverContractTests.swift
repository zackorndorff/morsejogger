//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import Foundation
import MorseJoggerCore

@MainActor private final class TestClock {
    var now: TimeInterval = 0
}

@main @MainActor private struct SessionDriverContractTests {
    static func main() {
        testPauseUsesMonotonicElapsedTime()
        testStartupFailurePausesUntilRetry()
        testRejectedProgramRetriesTheSameEvent()
        testStaleAudioStartCannotAffectReplacementSession()
        testPauseRetainsTransmitReceiveAndQueuedMacros()
        testPauseBeforeAudioStartsDoesNotFreezeTheClockAfterwards()
        testRepeatedPausesNeitherLoseNorGainTime()
        print("Native SessionDriver contract tests passed (7 cases).")
    }

    private static func testPauseUsesMonotonicElapsedTime() {
        let clock = TestClock()
        let driver = SessionDriver(monotonicClock: { clock.now })
        configureWorkingAudio(driver)
        driver.start(settings: ContestSettings(), genericHistory: nil)

        clock.now = 5
        driver.tick()
        expect(abs((driver.snapshot?.elapsed ?? -1) - 5) < 0.001, "elapsed time advances from injected clock")

        driver.setSessionControlsPresented(true)
        clock.now = 3_605
        driver.tick()
        expect(abs((driver.snapshot?.elapsed ?? -1) - 5) < 0.001, "control-sheet pause freezes elapsed time")

        driver.setSessionControlsPresented(false)
        clock.now = 3_610
        driver.tick()
        expect(abs((driver.snapshot?.elapsed ?? -1) - 10) < 0.001, "resume excludes paused duration")
    }

    private static func testStartupFailurePausesUntilRetry() {
        let clock = TestClock()
        let driver = SessionDriver(monotonicClock: { clock.now })
        var starts = 0
        driver.onAudioStart = { _, completion in
            starts += 1
            completion(starts == 1 ? .failure(.sessionActivation("test")) : .success(()))
        }
        driver.onAudioResume = { completion in completion(.success(())) }
        driver.dispatchAudio = { _, _, _, completion in completion(.transmit(duration: 0.4)) }
        driver.start(settings: ContestSettings(), genericHistory: nil)
        expect(driver.audioFailure == .sessionActivation("test"), "activation failure is reported")
        expect(!driver.audioHasStarted && driver.isPaused, "failed activation pauses the session")
        clock.now = 20
        driver.tick()
        expect((driver.snapshot?.elapsed ?? -1) == 0, "failed audio cannot advance the simulator")

        driver.retryAudio()
        expect(driver.audioFailure == nil && driver.audioHasStarted, "retry restores audio readiness")
        clock.now = 22
        driver.tick()
        expect(abs((driver.snapshot?.elapsed ?? -1) - 2) < 0.001, "clock restarts after successful retry")
    }

    private static func testRejectedProgramRetriesTheSameEvent() {
        let clock = TestClock()
        let driver = SessionDriver(monotonicClock: { clock.now })
        configureWorkingAudio(driver)
        var attempts: [String] = []
        driver.dispatchAudio = { event, _, _, completion in
            attempts.append(event.text)
            if attempts.count == 1 { completion(.failed(.programRejected)) }
            else { completion(.transmit(duration: 0.4)) }
        }
        driver.start(settings: ContestSettings(), genericHistory: nil)
        driver.send(.cq, call: "", exchange: "")
        expect(driver.audioFailure == .programRejected, "publication rejection reaches the driver")
        let failedText = attempts.first
        expect(driver.isPaused, "rejected event pauses the session")
        driver.retryAudio()
        expect(attempts.count >= 2 && attempts[1] == failedText, "retry republishes the same event")
        expect(driver.audioFailure == nil && driver.audioHasStarted, "accepted retry clears the failure")
    }

    private static func testStaleAudioStartCannotAffectReplacementSession() {
        let driver = SessionDriver(monotonicClock: { 0 })
        var starts: [((Result<Void, SessionDriver.AudioFailure>) -> Void)] = []
        driver.onAudioStart = { _, completion in starts.append(completion) }
        driver.dispatchAudio = { _, _, _, completion in completion(.transmit(duration: 0.4)) }
        driver.start(settings: ContestSettings(), genericHistory: nil)
        expect(starts.count == 1, "first session requests audio start")
        driver.reset()
        driver.start(settings: ContestSettings(), genericHistory: nil)
        expect(starts.count == 2, "replacement session requests a new audio start")
        starts[1](.success(()))
        starts[0](.failure(.sessionActivation("stale")))
        expect(driver.audioHasStarted && driver.audioFailure == nil,
               "stale activation result is ignored after reset")
    }

    private static func testPauseRetainsTransmitReceiveAndQueuedMacros() {
        let clock = TestClock()
        let driver = SessionDriver(monotonicClock: { clock.now })
        configureWorkingAudio(driver)
        var activeMessages: [String] = []
        var audioIsPaused = false
        driver.onAudioSuspend = { audioIsPaused = true }
        driver.onAudioResume = { completion in audioIsPaused = false; completion(.success(())) }
        driver.dispatchAudio = { event, _, _, completion in
            if event.kind == .transmit || event.kind == .receive {
                activeMessages.append(event.text)
                if event.kind == .receive { completion(.receive(duration: 0.4)) }
                else { completion(.transmit(duration: 0.4)) }
            } else { completion(.none) }
        }
        var settings = ContestSettings()
        settings.contest = .hst
        settings.mode = .hstCompetition
        settings.activity = 1
        driver.start(settings: settings, genericHistory: nil)
        driver.send(.cq, call: "", exchange: "")
        if let call = driver.target?.call { driver.send(.call, call: call, exchange: "") }
        driver.send(.tu, call: "", exchange: "")

        for step in 1...1000 where !driver.events.contains(where: { $0.kind == .receive }) {
            clock.now = Double(step) * 0.25
            driver.tick()
        }
        expect(driver.events.contains(where: { $0.kind == .transmit }), "CQ and queued macro produce TX audio")
        expect(driver.events.filter { $0.kind == .transmit }.count >= 2,
               "call and TU macros publish more than one TX program")
        expect(driver.events.contains(where: { $0.kind == .receive }), "CQ produces caller RX audio")
        let retainedMessages = activeMessages

        driver.setSessionControlsPresented(true)
        expect(audioIsPaused, "audio host receives pause while programs remain active")
        clock.now += 60
        driver.tick()
        expect(activeMessages == retainedMessages, "pause does not discard active or queued TX/RX programs")
        driver.setSessionControlsPresented(false)
        expect(!audioIsPaused && activeMessages == retainedMessages,
               "resume continues the same TX/RX programs without republishing")
    }

    /// Audio start is asynchronous. A pause that begins and ends before it
    /// completes used to be subtracted from a clock that had not started,
    /// leaving the simulator frozen for the length of that pause.
    private static func testPauseBeforeAudioStartsDoesNotFreezeTheClockAfterwards() {
        let clock = TestClock()
        let driver = SessionDriver(monotonicClock: { clock.now })
        var pendingStarts: [SessionDriver.AudioStartCompletion] = []
        driver.onAudioStart = { _, completion in pendingStarts.append(completion) }
        driver.onAudioResume = { completion in completion(.success(())) }
        driver.dispatchAudio = { _, _, _, completion in completion(.transmit(duration: 0.4)) }
        driver.start(settings: ContestSettings(), genericHistory: nil)

        clock.now = 1
        driver.sceneDidChange(active: false)
        clock.now = 6
        driver.sceneDidChange(active: true)
        clock.now = 6.2
        pendingStarts.forEach { $0(.success(())) }
        expect(driver.audioHasStarted && !driver.isPaused, "audio starts after the early pause")

        clock.now = 8.2
        driver.tick()
        expect(abs((driver.snapshot?.elapsed ?? -1) - 2) < 0.001, "the clock runs from when audio started")
    }

    private static func testRepeatedPausesNeitherLoseNorGainTime() {
        let clock = TestClock()
        let driver = SessionDriver(monotonicClock: { clock.now })
        configureWorkingAudio(driver)
        driver.start(settings: ContestSettings(), genericHistory: nil)
        var running = 0.0
        for cycle in 0..<200 {
            clock.now += 0.37
            running += 0.37
            driver.setSessionControlsPresented(true)
            clock.now += Double(cycle % 7) + 0.13
            driver.setSessionControlsPresented(false)
        }
        driver.tick()
        expect(abs((driver.snapshot?.elapsed ?? -1) - running) < 0.001, "200 pauses leave elapsed time exact")
    }

    private static func configureWorkingAudio(_ driver: SessionDriver) {
        driver.onAudioStart = { _, completion in completion(.success(())) }
        driver.onAudioResume = { completion in completion(.success(())) }
        driver.dispatchAudio = { _, _, _, completion in completion(.transmit(duration: 0.4)) }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("SessionDriver test failed: \(message)") }
    }
}
