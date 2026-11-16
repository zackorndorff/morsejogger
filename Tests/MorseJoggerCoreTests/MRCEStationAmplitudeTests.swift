//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class MRCEStationAmplitudeTests: XCTestCase {
    func testMRCEUShapedDrawUsesSineTransformAndRange() {
        var transformed=ContestRNG(seed:42)
        var uniform=ContestRNG(seed:42)
        for _ in 0..<1_000 {
            let draw=transformed.uShaped()
            let expected=sin(Double.pi*(uniform.random()-0.5))
            XCTAssertEqual(draw,expected,accuracy:1e-15)
            let amplitude=9_000+18_000*(1+draw)
            XCTAssertGreaterThanOrEqual(amplitude,9_000)
            XCTAssertLessThanOrEqual(amplitude,45_000)
        }
    }

    func testStationAmplitudeIsSeededAndPersistsAcrossVoiceMessages() {
        var settings=ContestSettings()
        settings.mode = .single
        settings.seed = 0xA531_09FE
        let first=ContestSimulator(settings:settings)
        first.start()
        first.tick(6.0 * 512.0 / 11025.0)
        let station=try! XCTUnwrap(first.pileup.first)
        let amplitude=try! XCTUnwrap(station.rfAmplitude)
        XCTAssertGreaterThanOrEqual(amplitude,9_000)
        XCTAssertLessThanOrEqual(amplitude,45_000)

        var changedCopy=station
        changedCopy.volume=0.01
        let voiceA=RadioVoice(station:station,message:"K1ABC")
        let voiceB=RadioVoice(station:changedCopy,message:"599 001")
        XCTAssertEqual(voiceA.rfAmplitude,amplitude)
        XCTAssertEqual(voiceB.rfAmplitude,amplitude)

        let second=ContestSimulator(settings:settings)
        second.start()
        second.tick(6.0 * 512.0 / 11025.0)
        XCTAssertEqual(second.pileup.first?.rfAmplitude,amplitude)
    }
}
