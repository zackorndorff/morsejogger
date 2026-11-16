//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class TransmitFrameSchedulerTests: XCTestCase {
    func testBackToBackTransmitPiecesStartAfterPriorDurationAndGap() {
        var scheduler=TransmitFrameScheduler()

        let first=scheduler.schedule(currentFrame:1_000,generation:7,
                                     durationFrames:3_000,spacingFrames:100)
        let second=scheduler.schedule(currentFrame:1_000,generation:7,
                                      durationFrames:2_000,spacingFrames:100)

        XCTAssertEqual(first.referenceFrame,1_000)
        XCTAssertEqual(first.startDelaySamples,0)
        XCTAssertEqual(second.referenceFrame,1_000)
        XCTAssertEqual(second.startDelaySamples,3_100,
                       "The next macro must wait for the first macro and the inter-message gap")
    }

    func testTransmitSchedulerAccountsForFramesAlreadyRendered() {
        var scheduler=TransmitFrameScheduler()
        _=scheduler.schedule(currentFrame:1_000,generation:7,
                             durationFrames:3_000,spacingFrames:100)

        let next=scheduler.schedule(currentFrame:2_500,generation:7,
                                    durationFrames:2_000,spacingFrames:100)

        XCTAssertEqual(next.startDelaySamples,1_600,
                       "Only the remaining queued duration should be delayed")
    }

    func testGenerationChangeDropsStaleTransmitTail() {
        var scheduler=TransmitFrameScheduler()
        _=scheduler.schedule(currentFrame:1_000,generation:7,
                             durationFrames:30_000,spacingFrames:100)

        let afterReset=scheduler.schedule(currentFrame:2_000,generation:8,
                                          durationFrames:2_000,spacingFrames:100)

        XCTAssertEqual(afterReset.referenceFrame,2_000)
        XCTAssertEqual(afterReset.startDelaySamples,0,
                       "Stopped playback must not inherit the previous generation's tail")
    }
}
