//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

// ConfidenceFixtures, OperatorTransitions, CallFixtures, OperatorFixtures and
// SerialFixtures were generated once from an earlier JavaScript web build of this app (v0.15)
// (dist/core.js and rules.js). That build is not in the repository, so these
// files are frozen. MRCE-derived fixtures come from tools/mrce-oracle.

final class ParityExpansionTests: XCTestCase {
    func testContestSpecificSerialFormattingAndStableCustomCallerBranch() {
        var settings=ContestSettings()
        settings.contest = .sweepstakes
        XCTAssertEqual(ContestRules.sentExchange(settings,serial:1),"1 A VE3NEA 72 OR")
        settings.contest = .arrl10
        settings.myCall="DL1ABC"
        XCTAssertEqual(ContestRules.sentExchange(settings,serial:1),"5NN 1")

        settings.contest = .wpx
        XCTAssertEqual(ContestRules.ownSerialText(settings,serial:1),"001")
        XCTAssertEqual(ContestRules.callerSerialText(settings,serial:1),"001")
        settings.serialRange = .custom
        let minimum=ContestRules.callerSerialText(settings,serial:1,customMinimumWidth:2,naturalWidth:1,useMinimumWidth:true)
        let natural=ContestRules.callerSerialText(settings,serial:1,customMinimumWidth:2,naturalWidth:1,useMinimumWidth:false)
        XCTAssertEqual(minimum,"01")
        XCTAssertEqual(natural,"1")

        var first=ContestRNG(seed:0x1234),repeatBranch=ContestRNG(seed:0x1234)
        let branch=ContestRules.callerSerialUsesMinimumWidth(rng:&first)
        XCTAssertEqual(ContestRules.callerSerialUsesMinimumWidth(rng:&repeatBranch),branch,
                       "A caller's seeded width choice is stable when its exchange repeats")
    }
    private struct Sample:Decodable {
        var range:String,seed:UInt32,draws:[Int]
    }
    func testMRCESerialHistogramAgainst384ReferenceDraws() throws {
        let fixture=try XCTUnwrap(Bundle.module.url(forResource:"SerialFixtures",withExtension:"json"))
        let samples=try JSONDecoder().decode([Sample].self,from:Data(contentsOf:fixture))
        XCTAssertEqual(samples.count,12)
        for sample in samples {
            let range=try XCTUnwrap(SerialRange(rawValue:sample.range))
            var s=ContestSettings();s.contest = (range == .mid || range == .end) ? .wpx : .cqww
            s.serialRange=range;s.serialMin=45;s.serialMax=72
            var rng=ContestRNG(seed:sample.seed)
            let result=sample.draws.map{_ in SerialDistribution.draw(s,rng:&rng,elapsed:300,skill:2)}
            if sample.range == "custom" {
                XCTAssertTrue(result.allSatisfy{$0 >= 45 && $0 < 72},"Custom serial upper endpoint is exclusive")
                continue
            }
            if sample.range == "start" {
                // The stored Start draws came from the earlier web engine's hourly
                // estimate. Pinned MRCE uses Ini.SerialNRSettings[snStartContest].GetNR
                // outside WPX/HST: 1 + Random(175).
                var expected=ContestRNG(seed:sample.seed)
                XCTAssertEqual(result,sample.draws.map{_ in 1+Int(expected.random()*175)})
                continue
            }
            XCTAssertEqual(result,sample.draws,"Source serial draw mismatch: \(sample.range), seed \(sample.seed)")
        }
    }
    func testNonWPXMidAndEndSerialsUseUniformConfiguredSegment() {
        for (range,low,high) in [(SerialRange.mid,50,500),(.end,500,5000)] {
            var settings=ContestSettings();settings.contest = .cqww;settings.serialRange=range
            var actual=ContestRNG(seed:0xA10),expected=ContestRNG(seed:0xA10)
            let uniformDraw=low+Int(expected.random()*Double(high-low))
            XCTAssertEqual(SerialDistribution.draw(settings,rng:&actual,elapsed:0,skill:1),uniformDraw,
                           "\(range.rawValue) serials in non-WPX contests use Ini.GetNR's uniform draw")
        }
    }
    func testWPXAndHSTStartSerialsUseElapsedMinuteSkillEstimate() {
        var wpx=ContestSettings();wpx.contest = .wpx;wpx.serialRange = .start;wpx.serialMin=41;wpx.serialMax=57
        var atStart=ContestRNG(seed:44)
        XCTAssertEqual(SerialDistribution.draw(wpx,rng:&atStart,elapsed:0,skill:3),1)

        var actual=ContestRNG(seed:44), expected=ContestRNG(seed:44)
        let span=10_000.0/60*3
        let expectedWPX=1+Int((expected.random()*span).rounded(.toNearestOrEven))
        XCTAssertEqual(SerialDistribution.draw(wpx,rng:&actual,elapsed:10_000,skill:3),expectedWPX)

        var hst=wpx;hst.mode = .hstCompetition;hst.serialMin=41;hst.serialMax=57
        var hstActual=ContestRNG(seed:44),hstExpected=ContestRNG(seed:44)
        let expectedHST=1+Int((hstExpected.random()*span).rounded(.toNearestOrEven))
        XCTAssertEqual(SerialDistribution.draw(hst,rng:&hstActual,elapsed:10_000,skill:3),expectedHST)
    }
    func testCustomSerialRangeUsesExclusiveUpperBoundAndSupportsFourDigits() {
        var custom=ContestSettings();custom.serialRange = .custom;custom.serialMin=5001;custom.serialMax=9999
        var actual=ContestRNG(seed:922),expected=ContestRNG(seed:922)
        let expectedValue=5001+Int(expected.random()*Double(9999-5001))
        let value=SerialDistribution.draw(custom,rng:&actual,elapsed:0,skill:1)
        XCTAssertEqual(value,expectedValue)
        XCTAssertGreaterThanOrEqual(value,5001)
        XCTAssertLessThan(value,9999)

        custom.serialMin=17;custom.serialMax=17
        var equalRange=ContestRNG(seed:31)
        XCTAssertEqual(SerialDistribution.draw(custom,rng:&equalRange,elapsed:0,skill:1),17,
                       "Accepted equal endpoints must not invoke Random(0)")

        custom.serialMin=1;custom.serialMax=2
        var onlyOne=ContestRNG(seed:73)
        XCTAssertEqual(SerialDistribution.draw(custom,rng:&onlyOne,elapsed:0,skill:1),1)
    }
    func testOtherContestStartSerialUsesTheDefaultRangeWhateverTheClock() {
        var settings=ContestSettings();settings.contest = .sweepstakes;settings.serialRange = .start
        for elapsed in [0.0,10_000] {
            var actual=ContestRNG(seed:44),expected=ContestRNG(seed:44)
            XCTAssertEqual(SerialDistribution.draw(settings,rng:&actual,elapsed:elapsed,skill:2),
                           1+Int(expected.random()*175),"MinVal 1, MaxVal 176, Random(MaxVal-MinVal)")
        }
    }
    func testFastReportRateMatchesMRCEOwnAndDXSelection() {
        XCTAssertEqual(FastReportTiming.rate(randomValue:0.81234,occurrenceRate:1,isHomeStation:true) ?? 0,1.3,accuracy:1e-9)
        XCTAssertEqual(FastReportTiming.rate(randomValue:0.81234,occurrenceRate:24,isHomeStation:false) ?? 0,1.3,accuracy:1e-9)
        XCTAssertNil(FastReportTiming.rate(randomValue:0.81234,occurrenceRate:23,isHomeStation:false))
        XCTAssertNil(FastReportTiming.rate(randomValue:0.81234,occurrenceRate:0,isHomeStation:true))
    }
    func testFastReportSpeedsOnlyTheMarkedReportCharactersWithoutChangingText() {
        let plain=MorseTimeline.marks("R 599 001",wpm:25)
        let fast=MorseTimeline.marks("R 599 001",wpm:25,fastReportStart:2,fastReportRate:1.5)
        XCTAssertEqual(plain.count,fast.count)
        XCTAssertLessThan(MorseTimeline.duration("R 599 001",wpm:25,fastReportStart:2,fastReportRate:1.5),MorseTimeline.duration("R 599 001",wpm:25))
        XCTAssertEqual(MorseTimeline.marks("R 599 001",wpm:25,fastReportStart:2,fastReportRate:1.5).last?.duration,plain.last?.duration,"Serial characters following the report retain normal speed")
    }
    func testFarnsworthLeavesCharacterShapeAndIncreasesSpacing() {
        let plain=MorseTimeline.marks("PARIS PARIS",wpm:15)
        let spaced=MorseTimeline.marks("PARIS PARIS",wpm:15,characterWpm:25)
        XCTAssertEqual(plain.count,spaced.count)
        XCTAssertLessThan(spaced[0].duration,plain[0].duration)
        let plainGap=plain[1].start-plain[0].start-plain[0].duration
        let spedGap=spaced[1].start-spaced[0].start-spaced[0].duration
        XCTAssertGreaterThan(spaced.last!.start,plain.last!.start-1)
        XCTAssertLessThan(spedGap,plainGap)
    }
    func testSessionTimeoutStopsWithoutArbitraryActionDrain() {
        var s=ContestSettings();s.seed=400;s.duration=1
        let game=ContestSimulator(settings:s);game.start();game.tick(61)
        XCTAssertFalse(game.running)
        XCTAssertEqual(game.snapshot.phase,.finished)
        XCTAssertTrue(game.drainEvents().contains(where:{$0.kind == .finished}))
    }
    func testCallerArrivalsRespectARRLDXRegions() {
        var s=ContestSettings();s.seed=987;s.mode = .single;s.contest = .arrldx
        let game=ContestSimulator(settings:s);game.start()
        game.tick(6.0 * 512.0 / 11025.0)
        XCTAssertEqual(game.pileup.count,1)
        for station in game.pileup {XCTAssertFalse(ContestRules.callMeta(station.call).usve)}
    }
    func testMRCELogAttemptDoesNotWaitForReceiveAudioPlayback() {
        var s=ContestSettings();s.seed=2134;s.mode = .single
        let game=ContestSimulator(settings:s);game.start()
        game.tick(6.0 * 512.0 / 11025.0)
        let call=game.pileup[0].call,ex=game.pileup[0].exchange
        game.command(.call,call:call);game.tick(10)
        XCTAssertNotNil(game.logQSO(call:call,exchange:ex),"MRCE SaveQso validates the entry fields; it has no receive-audio busy gate")
        XCTAssertEqual(game.contacts,1)
    }
}

final class GeographyImportTests: XCTestCase {
    func testUserPrefixMapOverridesBuiltInAndExactHistoryWins() throws {
        var settings=ContestSettings();settings.contest = .cqww
        settings.countryPrefixes=try HistoryImport.prefixCSV("PREFIX,COUNTRY,CONTINENT,CQ_ZONE,ITU_ZONE\nEA8,EA8,AF,33,36\nK,K,NA,5,8\n")
        let canary=ContestRules.callMeta("EA8ABC",settings:settings)
        XCTAssertEqual(canary.country,"EA8")
        XCTAssertEqual(canary.continent,"AF")
        XCTAssertEqual(canary.cq,33)
        var record=HistoryRecord(call:"EA8ABC");record.cq=31
        settings.customRecords["EA8ABC"]=record
        XCTAssertEqual(ContestRules.callMeta("EA8ABC",settings:settings).cq,31)
    }
    func testMalformedPrefixCsvRejected() {
        XCTAssertThrowsError(try HistoryImport.prefixCSV("PREFIX,COUNTRY,CONTINENT,CQ_ZONE,ITU_ZONE\nDL,DL,EU,0,28\n"))
        XCTAssertThrowsError(try HistoryImport.prefixCSV("PREFIX,COUNTRY,CONTINENT,CQ_ZONE,ITU_ZONE\nDL,DL,XX,14,28\n"))
    }
}

final class OperatorSourceFixtureTests: XCTestCase {
    struct Fixture:Decodable {
        var state:String,style:Double,cause:String,text:String,nrCount:Int,corrected:Bool
    }
    func test112OriginalOperatorReplyVariants() throws {
        let path=try XCTUnwrap(Bundle.module.url(forResource:"OperatorFixtures",withExtension:"json"))
        let items=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:path))
        XCTAssertEqual(items.count,112)
        for fixture in items {
            var settings=ContestSettings();settings.mode = .single;settings.seed=81234;settings.effects.lids=true
            let simulator=ContestSimulator(settings:settings)
            var st=Station(call:"K1ABC",exchange:"599 123",wpm:25,tone:600,volume:0.8,shift:0)
            let names:[String:OperatorState]=["need-prev-end":.needPrevEnd,"need-qso":.needQso,"need-nr":.needNr,"need-call":.needCall,"need-callnr":.needCallNr,"need-end":.needEnd,"done":.done,"failed":.failed]
            st.opState=try XCTUnwrap(names[fixture.state])
            st.replyStyle=fixture.style;st.patience=4;st.transmittedExchange="599 124"
            let (text,result)=simulator.fixtureOperatorReply(st,corrected:fixture.cause == "corrected")
            XCTAssertEqual(text,fixture.text,"\(fixture.state) / \(fixture.style) / \(fixture.cause)")
            XCTAssertEqual(result.sendNrQuestionCount,fixture.nrCount)
            XCTAssertEqual(result.correctedCallAndExchSent,fixture.corrected)
        }
    }
}

final class FieldDayHistoryTests: XCTestCase {
    func testRepresentativeOfClubBeatsOtherTransmitterCounts() {
        var history=ImportedHistory()
        history.calls=["K1AAA","K1BBB","K1CCC","K1DDD"]
        for (call,className,club) in [
            ("K1AAA","1A","ALPHA"),("K1BBB","5A","ALPHA"),
            ("K1CCC","2D","ALPHA"),("K1DDD","3A","BETA")
        ] {
            var record=HistoryRecord(call:call);record.fdClass=className;record.userText=club
            history.records[call]=record
        }
        var rng=ContestRNG(seed:4)
        let eligible=HistoryImport.fieldDayEligibleCalls(history,rng:&rng)
        XCTAssertEqual(eligible,["K1BBB","K1DDD"])
    }
    func testHistoryParserPreservesClubMetadata() throws {
        let history=try HistoryImport.mrceHistory("!!Order!!,Call,Class,UserText\nK1AAA,4A,CW CLUB\n",contest:.fieldday)
        XCTAssertEqual(history.records["K1AAA"]?.userText,"CW CLUB")
    }
}

final class CallsignConfidenceSourceTests: XCTestCase {
    private struct Fixture:Decodable {var call:String,typed:String,confidence:Int}
    func test440OriginalPartialCallMatches() throws {
        let path=try XCTUnwrap(Bundle.module.url(forResource:"ConfidenceFixtures",withExtension:"json"))
        let samples=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:path))
        XCTAssertEqual(samples.count,440)
        let sim=ContestSimulator(settings:ContestSettings())
        for sample in samples {
            XCTAssertEqual(sim.fixtureConfidence(typed:sample.typed,correct:sample.call),sample.confidence,
                           "Source callsign matching: \(sample.typed) vs \(sample.call)")
        }
    }
}

final class OperatorStateTransitionSourceTests: XCTestCase {
    private struct Fixture:Decodable {
        var state:String,kind:String,confidence:Int,next:String,patience:Int,ghosting:Bool,incomplete:Int
    }
    func test192OriginalOperatorStateTransitions() throws {
        let path=try XCTUnwrap(Bundle.module.url(forResource:"OperatorTransitions",withExtension:"json"))
        let samples=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:path))
        XCTAssertEqual(samples.count,192)
        let names:[String:OperatorState]=["need-prev-end":.needPrevEnd,"need-qso":.needQso,
            "need-nr":.needNr,"need-call":.needCall,"need-callnr":.needCallNr,"need-end":.needEnd,
            "done":.done,"failed":.failed]
        for fixture in samples {
            // OperatorTransitions.json preserves the older v0.15 source table.
            // Apply the MRCE 1.86 source deltas here: F7/TU/B4 restart from
            // needPrevEnd; a no-match HIS CALL abandons needQso to needPrevEnd;
            // inactive TU resets needCallNr; B4 decrements patience in
            // needCall/needCallNr; and no-match HIS CALL ends a needEnd
            // exchange. F7/B4 behavior is also covered below.
            var expectedNext=fixture.next
            var expectedPatience=fixture.patience
            if fixture.state == "need-prev-end" && fixture.kind == "question" {
                expectedNext="need-qso";expectedPatience=4
            }
            if fixture.state == "need-prev-end" && ["tu","b4"].contains(fixture.kind) {
                expectedPatience=4
            }
            if fixture.state == "need-qso" && ["call","call-exchange"].contains(fixture.kind) && fixture.confidence == 0 {
                expectedNext="need-prev-end"
            }
            if fixture.state == "need-qso" && fixture.kind == "exchange" {expectedNext="need-prev-end";expectedPatience=5}
            if fixture.state == "need-qso" && fixture.kind == "tu" {expectedPatience=4}
            if fixture.state == "need-call" && fixture.kind == "b4" {expectedPatience=4}
            if fixture.state == "need-callnr" && fixture.kind == "b4" {expectedPatience=4}
            if fixture.state == "need-callnr" && fixture.kind == "tu" {
                expectedNext="need-qso";expectedPatience=4
            }
            if fixture.state == "need-end" && ["call","call-exchange"].contains(fixture.kind) && fixture.confidence == 0 {
                expectedNext="done"
            }
            var settings=ContestSettings();settings.seed=61234;settings.mode = .single
            settings.callerStays=true;settings.callerQrs=true
            let simulator=ContestSimulator(settings:settings)
            var st=Station(call:"K1ABC",exchange:"599 123",wpm:25,tone:600,volume:0.8,shift:0)
            st.opState=try XCTUnwrap(names[fixture.state]);st.patience=5
            st.baseWpm=25;st.characterWpm=25;st.skill=2;st.nextAction=40
            let after=simulator.fixtureOperatorTransition(st,input:OperatorInput(rawValue:fixture.kind)!,confidence:fixture.confidence,
                                                           active:!(fixture.state == "need-callnr" && fixture.kind == "tu"))
            let context="\(fixture.state) -> \(fixture.kind) c=\(fixture.confidence)"
            XCTAssertEqual(after.opState,try XCTUnwrap(names[expectedNext]),context)
            XCTAssertEqual(after.patience,expectedPatience,context)
            XCTAssertEqual(after.ghosting,fixture.ghosting,context)
            XCTAssertEqual(after.incomplete,fixture.incomplete,context)
        }
    }
    func testCurrentMRCEQuestionAndB4SpecialTransitions() {
        var s=ContestSettings();s.mode = .single;s.seed=61234
        let sim=ContestSimulator(settings:s)
        var station=Station(call:"K1ABC",exchange:"599 123",wpm:25,tone:600,volume:0.8,shift:0)
        station.opState = .needPrevEnd;station.patience=3
        XCTAssertEqual(sim.fixtureOperatorTransition(station,input:.question,confidence:0).opState,.needQso,
                       "MRCE F7 starts a new caller when waiting for the prior QSO to end and the call field is blank")

        station.opState = .needQso;station.patience=1;station.incomplete=2
        let afterB4=sim.fixtureOperatorTransition(station,input:.b4,confidence:0)
        XCTAssertEqual(afterB4.opState,.needQso)
        XCTAssertGreaterThan(afterB4.patience,1,"MRCE B4 restarts the QSO state instead of merely decrementing patience")
    }
    func testCompoundCallExchangeReportsEffectsInProtocolOrder() {
        var settings=ContestSettings();settings.mode = .single;settings.seed=61234
        let simulator=ContestSimulator(settings:settings)
        var station=Station(call:"K1ABC",exchange:"599 123",wpm:25,tone:600,volume:0.8,shift:0)
        station.opState = .needQso;station.patience=5
        let (_,effects)=simulator.fixtureOperatorTransitionTrace(station,input:.callAndExchange,confidence:100)
        XCTAssertEqual(effects,[.reset(.needNr),.reset(.needEnd),.decrementPatience])
    }
    func testMyCallInputDoesNotRunCallMatchingTransition() {
        var settings=ContestSettings();settings.mode = .single;settings.seed=61234
        let simulator=ContestSimulator(settings:settings)
        var station=Station(call:"K1ABC",exchange:"599 123",wpm:25,tone:600,volume:0.8,shift:0)
        station.opState = .needCall;station.patience=4
        let (after,effects)=simulator.fixtureOperatorTransitionTrace(station,input:.myCall,confidence:0)
        XCTAssertEqual(after.opState,.needCall,"MY CALL does not match the caller's callsign")
        XCTAssertEqual(after.patience,3,"MY CALL follows the generic reply/patience path")
        XCTAssertEqual(effects,[.decrementPatience])
    }
}

final class CallsignGeneratorSourceTests: XCTestCase {
    private struct Fixture:Decodable {var region:String,seed:UInt32,calls:[String]}
    func test256V15GeneratedCallsigns() throws {
        let path=try XCTUnwrap(Bundle.module.url(forResource:"CallFixtures",withExtension:"json"))
        let samples=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:path))
        XCTAssertEqual(samples.count,64)
        for sample in samples {
            var rng=ContestRNG(seed:sample.seed)
            let region=try XCTUnwrap(CallerRegion(rawValue:sample.region))
            let calls=(0..<4).map{_ in CallsignGenerator.makeCall(&rng,region:region)}
            XCTAssertEqual(calls,sample.calls,"Reference call pool \(sample.region), seed \(sample.seed)")
            if region == .ja {XCTAssertTrue(calls.allSatisfy{ContestRules.callMeta($0).country == "JA"})}
        }
    }
    func testJapanOnlyContestUsesJapaneseSyntheticCallers() {
        var s=ContestSettings();s.mode = .single;s.contest = .allja;s.seed=1234
        let game=ContestSimulator(settings:s);game.start()
        game.tick(6.0 * 512.0 / 11025.0)
        XCTAssertEqual(game.pending,1)
        XCTAssertTrue(game.pileup.allSatisfy{ContestRules.callMeta($0.call).country=="JA"})
    }
}
