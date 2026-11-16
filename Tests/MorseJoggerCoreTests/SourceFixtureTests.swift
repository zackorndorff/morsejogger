//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import Foundation
import XCTest
@testable import MorseJoggerCore

// SourceFixtures.json was generated once from the CW Field v0.15 web build
// (dist/core.js and rules.js). That build is not in the repository, so the file
// is frozen. MRCE-derived fixtures come from tools/mrce-oracle.

private struct SourceFixture: Decodable {
    var provenance:String
    var entries:[ScoringVector]
}
private struct ScoringVector: Decodable {
    var contest:String, call:String, state:String, section:String, points:Int, multipliers:[String]
}

final class SourceFixtureTests:XCTestCase {
    func testMigratedScoringVectorsAgainstV15BrowserSource() throws {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"SourceFixtures",withExtension:"json"))
        let vectors=try JSONDecoder().decode(SourceFixture.self,from:Data(contentsOf:url))
        XCTAssertEqual(vectors.entries.count,84)
        for item in vectors.entries {
            var settings=ContestSettings();settings.contest=try XCTUnwrap(ContestID(rawValue:item.contest))
            var st=Station(call:item.call,exchange:"599 012",wpm:25,tone:600,volume:1,shift:0)
            st.state=item.state;st.section=item.section;st.jaPref="10";st.jaCity="1002";st.serial=12
            let actual=ContestRules.score(settings,station:st)
            XCTAssertEqual(actual.points,item.points,"\(item.contest) \(item.call) point mismatch")
            // The old browser fixture assigned NY even to foreign SST calls.
            // MRCE uses the actual exchange unless it is DX (Log/ CWSST.pas).
            let expectedMultipliers = settings.contest == .sst && item.state != "DX"
                ? ["S:\(item.state)"] : item.multipliers
            XCTAssertEqual(actual.multipliers,expectedMultipliers,"\(item.contest) \(item.call) multiplier mismatch")
        }
    }
}
