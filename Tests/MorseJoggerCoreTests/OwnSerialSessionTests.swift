//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class OwnSerialSessionTests:XCTestCase {
    private func startSingle(_ game:ContestSimulator) {
        game.start()
        let block=Int((11025.0/512.0*Double(game.settings.singleCallStartDelay)/1000.0).rounded())+5
        game.tick(Double(block+1)*512.0/11025.0)
    }

    func testOwnSerialIsSharedByTXAndLogAndAdvancesOnlyAfterSave() {
        var settings=ContestSettings();settings.contest = .wpx;settings.mode = .single;settings.seed=712
        var profile=settings.exchangeProfile();profile.firstSerial=123;settings.setExchangeProfile(profile)
        let game=ContestSimulator(settings:settings);startSingle(game);_ = game.drainEvents()
        XCTAssertEqual(game.snapshot.serial,123)

        // Repeated exchange requests before a save reuse the same own serial.
        game.command(.exchange);game.command(.exchange)
        let repeats=game.drainEvents().filter{$0.kind == .transmit}.map(\.text)
        XCTAssertEqual(repeats,["5NN123","5NN123"])
        XCTAssertEqual(game.snapshot.serial,123)

        let caller=try! XCTUnwrap(game.pileup.first?.call)
        game.command(.saveOnly,call:caller,exchange:"599 999")
        XCTAssertEqual(game.log.first?.sent,"5NN 123")
        XCTAssertEqual(game.snapshot.serial,124)

        game.command(.exchange)
        XCTAssertEqual(game.drainEvents().first(where:{$0.kind == .transmit})?.text,"5NN124")
    }

    func testSweepstakesUnpaddedSerialIsSharedByRepeatedTXAndSavedLog() {
        var settings=ContestSettings();settings.contest = .sweepstakes;settings.mode = .single;settings.seed=713
        var profile=settings.exchangeProfile();profile.check="86";profile.section="ON";settings.setExchangeProfile(profile)
        let game=ContestSimulator(settings:settings);startSingle(game);_ = game.drainEvents()
        game.command(.exchange);game.command(.exchange)
        let repeats=game.drainEvents().filter{$0.kind == .transmit}.map(\.text)
        XCTAssertEqual(repeats,["1 A VE3NEA 86 ON","1 A VE3NEA 86 ON"])
        let caller=try! XCTUnwrap(game.pileup.first?.call)
        // The embedded call must identify the caller, not our own station.
        game.command(.saveOnly,call:caller,exchange:"1 A \(caller) 72 OR")
        XCTAssertEqual(game.log.first?.sent,"1 A VE3NEA 86 ON")
    }

    func testOwnSerialAdvancesOnlyWhenTheSentExchangeUsesIt() {
        var settings=ContestSettings();settings.contest = .cqww;settings.mode = .single;settings.seed=714
        let game=ContestSimulator(settings:settings);startSingle(game);_ = game.drainEvents()
        let caller=try! XCTUnwrap(game.pileup.first?.call)
        game.command(.saveOnly,call:caller,exchange:"599 5")
        XCTAssertEqual(game.snapshot.serial,1,"CQ zone exchanges do not contain the operator's serial")

    }

    func testMidRangeSeedsGeneratedOwnSerialBeforeFirstQSO() {
        var settings=ContestSettings();settings.contest = .wpx;settings.mode = .single
        settings.serialRange = .mid;settings.seed=991
        var expectedRng=ContestRNG(seed:settings.seed ^ 0x6A09_E667)
        // Main.SetMyExch2: 1 + (random serial div 10) * 10.
        let expected=1+(SerialDistribution.draw(settings,rng:&expectedRng,elapsed:0,skill:1)/10)*10
        let game=ContestSimulator(settings:settings)
        XCTAssertEqual(game.snapshot.serial,expected)
    }

    func testFirstSerialSetsTheOwnCounterAndSurvivesSaving() throws {
        var settings=ContestSettings();settings.contest = .wpx;settings.mode = .single;settings.seed=715
        var profile=settings.exchangeProfile();profile.firstSerial=250;settings.setExchangeProfile(profile)
        XCTAssertEqual(ContestRules.initialOwnSerial(settings),250)
        XCTAssertEqual(ContestSimulator(settings:settings).snapshot.serial,250)

        let restored=try JSONDecoder().decode(ContestSettings.self,from:JSONEncoder().encode(settings))
        XCTAssertEqual(restored.exchangeProfile().firstSerial,250)

        // Without it the serial range decides, as before.
        profile.firstSerial=nil;settings.setExchangeProfile(profile)
        XCTAssertEqual(ContestRules.initialOwnSerial(settings),1)
    }
}
