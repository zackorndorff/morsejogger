//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class MorseTimingTests: XCTestCase {
    func testMRCEUnitRoundingAndCharacterWordSpacingAtSeveralSpeedsAndRates() {
        for sampleRate in [11_025.0, 44_100.0] {
            for wpm in [15, 25, 40] {
                let unit=Double(Int((60.0/48*sampleRate/Double(wpm)).rounded()))/sampleRate
                let start=0.0
                let letters=MorseTimeline.marks("EE",wpm:wpm,sampleRate:sampleRate)
                let words=MorseTimeline.marks("E E",wpm:wpm,sampleRate:sampleRate)

                XCTAssertEqual(letters.count,2)
                XCTAssertEqual(words.count,2)
                XCTAssertEqual(letters[0].start,start,accuracy:1/sampleRate)
                XCTAssertEqual(letters[1].start,start+4*unit,accuracy:1/sampleRate)
                XCTAssertEqual(words[0].start,start,accuracy:1/sampleRate)
                XCTAssertEqual(words[1].start,start+6*unit,accuracy:1/sampleRate)
                XCTAssertEqual(MorseTimeline.duration("E E",wpm:wpm,sampleRate:sampleRate),
                               start+11*unit,accuracy:1/sampleRate)
            }
        }
    }

    /// MRCE's keyer treats every space as a token: surrounding whitespace is
    /// trimmed, but each extra space inside a message adds two more units
    /// (for example `QRL?   QRL?` and the CWT `<name>  <number>` exchange).
    func testSurroundingWhitespaceIsIgnoredAndExtraSpacesWidenTheGap() {
        let expected=MorseTimeline.marks("CQ K1ABC",wpm:25)
        for message in [" CQ K1ABC ","CQ\nK1ABC"] {
            XCTAssertEqual(MorseTimeline.marks(message,wpm:25),expected)
            XCTAssertEqual(ContestRules.cwSeconds(message,wpm:25),MorseTimeline.duration("CQ K1ABC",wpm:25))
        }
        let unit=MorseTimeline.marks("E",wpm:25)[0].duration
        XCTAssertEqual(MorseTimeline.duration("CQ   K1ABC",wpm:25),
                       MorseTimeline.duration("CQ K1ABC",wpm:25)+4*unit,accuracy:1e-9)
    }

    func testFarnsworthCharacterAndSpacingUnitsStayOnSampleClock() {
        let rate=11_025.0,sendWpm=15,charWpm=25
        let charUnit=Double(Int((60.0/48*rate/Double(charWpm)).rounded()))/rate
        let rawSpacing=max(charUnit,(60/Double(sendWpm)-31*charUnit)/17)
        let spacingUnit=Double(Int((rawSpacing*rate).rounded()))/rate
        let marks=MorseTimeline.marks("EE",wpm:sendWpm,characterWpm:charWpm,sampleRate:rate)
        XCTAssertEqual(marks.count,2)
        XCTAssertEqual(marks[0].duration,charUnit,accuracy:1/rate)
        XCTAssertEqual(marks[1].start-marks[0].start-marks[0].duration,3*spacingUnit,accuracy:1/rate)
    }
}
