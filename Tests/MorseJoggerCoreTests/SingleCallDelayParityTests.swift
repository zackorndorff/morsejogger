//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class SingleCallDelayParityTests:XCTestCase {
    private let secondsPerBlock=512.0/11025.0

    func testInitialCallerUsesStrictMRCEBlockThreshold() {
        for (delay, threshold) in [(0,5),(1_000,27),(2_500,59)] {
            var settings=ContestSettings()
            settings.mode = .single
            settings.singleCallStartDelay=delay
            settings.seed=123
            let game=ContestSimulator(settings:settings)
            game.start()
            XCTAssertTrue(game.pileup.isEmpty,"delay=\(delay): startup waits for the block threshold")

            game.tick(Double(threshold)*secondsPerBlock)
            XCTAssertTrue(game.pileup.isEmpty,"delay=\(delay): BlockNumber equal to threshold still waits")

            game.tick(Double(threshold+1)*secondsPerBlock)
            XCTAssertEqual(game.pileup.count,1,"delay=\(delay): first caller arrives at threshold + 1")
        }
    }

    func testDelayDoesNotRestartAfterNILRemovesCaller() {
        var settings=ContestSettings()
        settings.mode = .single
        settings.singleCallStartDelay=2_500
        settings.nilInstant=true
        settings.seed=123
        let game=ContestSimulator(settings:settings)
        game.start()
        game.tick(60*secondsPerBlock)
        XCTAssertEqual(game.pileup.count,1)
        let first=game.pileup[0].call

        _ = game.fixtureDropInstantNIL([game.pileup[0]])
        XCTAssertFalse(game.pileup.contains(where:{$0.call==first}))
        XCTAssertEqual(game.pileup.count,1,"Replacement arrives without restarting the startup delay")
    }
}
