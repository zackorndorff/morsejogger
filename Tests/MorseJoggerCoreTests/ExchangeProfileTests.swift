//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class ExchangeProfileTests:XCTestCase {
    func testFreshContestDefaultsAndFormatting() {
        let cases:[(ContestID,String)] = [
            (.wpx,"5NN 007"),(.cwt,"DAVID 123"),(.fieldday,"3A OR"),(.naqp,"ALEX ON"),
            (.hst,"5NN 007"),(.cqww,"5NN 3"),(.sst,"BRUCE MA"),
            (.allja,"5NN 10H"),(.acag,"5NN 1002H"),(.iaru,"5NN 6"),(.sweepstakes,"7 A N0CALL 72 OR"),(.arrl10,"5NN OR")
        ]
        for (contest,expected) in cases {
            var settings=ContestSettings();settings.contest=contest
            XCTAssertEqual(ContestRules.sentExchange(settings,serial:7),expected,"\(contest.rawValue)")
        }
        var dx=ContestSettings();dx.contest = .arrldx;dx.myCall="K1ABC"
        XCTAssertEqual(ContestRules.sentExchange(dx,serial:7),"5NN ON")
        dx.myCall="DL1ABC"
        XCTAssertEqual(ContestRules.sentExchange(dx,serial:7),"5NN KW")
    }

    func testContestProfilesRemainIndependentAcrossSwitchAndCodableReload() throws {
        var settings=ContestSettings()
        var wpx=settings.exchangeProfile(for:.wpx);wpx.firstSerial=40;settings.setExchangeProfile(wpx,for:.wpx)
        var fd=settings.exchangeProfile(for:.fieldday);fd.fdClass="1E";fd.section="AZ";settings.setExchangeProfile(fd,for:.fieldday)
        settings.contest = .fieldday
        XCTAssertEqual(ContestRules.sentExchange(settings,serial:9),"1E AZ")
        settings.contest = .wpx
        XCTAssertEqual(ContestRules.sentExchange(settings,serial:9),"5NN 048")
        let copy=try JSONDecoder().decode(ContestSettings.self,from:JSONEncoder().encode(settings))
        XCTAssertEqual(copy.exchangeProfile(for:.fieldday).fdClass,"1E")
        XCTAssertEqual(copy.exchangeProfile(for:.fieldday).section,"AZ")
        XCTAssertEqual(copy.exchangeProfile(for:.wpx).firstSerial,40)
        var contest=ContestSettings();contest.contest = .cqww
        var profile=contest.exchangeProfile()
        for (text,expected) in [("3","5NN 3"),("03","5NN 03"),("40","5NN 40")] {
            profile.zoneText=text;profile.zone=Int(text) ?? profile.zone;contest.setExchangeProfile(profile)
            XCTAssertEqual(ContestRules.sentExchange(contest,serial:1),expected)
            let restored=try JSONDecoder().decode(ContestSettings.self,from:JSONEncoder().encode(contest))
            XCTAssertEqual(restored.exchangeProfile().zoneText,text)
            XCTAssertEqual(ContestRules.sentExchange(restored,serial:1),expected)
        }
        contest.contest = .iaru;profile=contest.exchangeProfile();profile.ituZone=27;profile.ituZoneText="27"
        profile.ituSociety="arrl";profile.iaruExchangeMode = .zone;contest.setExchangeProfile(profile)
        XCTAssertEqual(ContestRules.sentExchange(contest,serial:1),"5NN 27")
        profile.ituSociety=" ARRL ";profile.iaruExchangeMode = .society;contest.setExchangeProfile(profile)
        XCTAssertEqual(ContestRules.sentExchange(contest,serial:1),"5NN ARRL")
        let restored=try JSONDecoder().decode(ContestSettings.self,from:JSONEncoder().encode(contest))
        XCTAssertEqual(ContestRules.sentExchange(restored,serial:1),"5NN ARRL")
        profile.ituSociety="arrl";contest.setExchangeProfile(profile)
        XCTAssertEqual(ContestRules.sentExchange(contest,serial:1),"5NN ARRL")
        contest.contest = .allja;profile=contest.exchangeProfile();profile.jaPrefecture="13";profile.jaPower="H";contest.setExchangeProfile(profile)
        XCTAssertEqual(ContestRules.sentExchange(contest,serial:1),"5NN 13H")
    }

}
