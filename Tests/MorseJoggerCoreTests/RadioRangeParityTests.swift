//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class RadioRangeParityTests: XCTestCase {
    func testSpeedBoundariesAreAcceptedThrough120WPMAndClampOutsideRange() {
        for speed in [80, 81, 100, 120] {
            var settings = ContestSettings()
            settings.wpm = speed
            XCTAssertEqual(settings.effective().wpm, speed)
            XCTAssertGreaterThan(MorseTimeline.duration("E", wpm: speed), 0)
        }

        var tooFast = ContestSettings()
        tooFast.wpm = 121
        XCTAssertEqual(tooFast.effective().wpm, 120)
        var tooSlow = ContestSettings()
        tooSlow.wpm = 4
        XCTAssertEqual(tooSlow.effective().wpm, 5)
    }

    func testSpeedChangesDitDurationAtHighWPM() {
        let at80 = MorseTimeline.marks("E", wpm: 80)[0].duration
        let at81 = MorseTimeline.marks("E", wpm: 81)[0].duration
        let at100 = MorseTimeline.marks("E", wpm: 100)[0].duration
        let at120 = MorseTimeline.marks("E", wpm: 120)[0].duration
        XCTAssertGreaterThan(at80, at81)
        XCTAssertGreaterThan(at81, at100)
        XCTAssertGreaterThan(at100, at120)
        XCTAssertEqual(at120, Double(Int((60.0 / 48 * 44_100 / 120).rounded())) / 44_100,
                       accuracy: 1 / 44_100)
    }

    func testPitchAndBandwidthChoicesAndSettingsRoundTrip() throws {
        XCTAssertEqual(ContestSettings().pitch, 600, "MRCE Ini.Pitch")
        XCTAssertEqual(ContestSettings().bandwidth, 500, "MRCE Ini.BandWidth")

        var settings = ContestSettings()
        settings.wpm = 120
        settings.pitch = 900
        settings.bandwidth = 600
        let reloaded = try JSONDecoder().decode(ContestSettings.self, from: JSONEncoder().encode(settings)).effective()
        XCTAssertEqual(reloaded.wpm, 120)
        XCTAssertEqual(reloaded.pitch, 900)
        XCTAssertEqual(reloaded.bandwidth, 600)

        for pitch in stride(from: 300, through: 900, by: 50) {
            var candidate = ContestSettings()
            candidate.pitch = pitch
            XCTAssertEqual(candidate.effective().pitch, pitch)
        }
        for bandwidth in stride(from: 100, through: 600, by: 50) {
            var candidate = ContestSettings()
            candidate.bandwidth = bandwidth
            XCTAssertEqual(candidate.effective().bandwidth, bandwidth)
        }
    }

    func testOldOffGridRadioValuesNormalizeToNearestSupportedChoice() {
        var settings = ContestSettings()
        settings.pitch = 605
        settings.bandwidth = 525
        let normalized = settings.effective()
        XCTAssertEqual(normalized.pitch, 600)
        XCTAssertEqual(normalized.bandwidth, 500)
    }
}
