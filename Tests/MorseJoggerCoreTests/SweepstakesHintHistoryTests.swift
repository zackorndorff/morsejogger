//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class SweepstakesHintHistoryTests:XCTestCase {
    func testHintRequiresCompleteImportedRecord() throws {
        let history=try HistoryImport.mrceHistory(
            "!!Order!!,Call,Exch1,Exch2\nK1ABC,A 86,CT\nK2DEF,A 8,CT\nK3GHI,A 86,ZZ\n",
            contest:.sweepstakes
        )
        XCTAssertEqual(HistoryImport.sweepstakesCheckSection(for:"k1abc",in:history),"86 CT")
        XCTAssertNil(HistoryImport.sweepstakesCheckSection(for:"K2DEF",in:history))
        XCTAssertNil(HistoryImport.sweepstakesCheckSection(for:"K3GHI",in:history))
        XCTAssertNil(HistoryImport.sweepstakesCheckSection(for:"W1AW",in:history))
    }
}
