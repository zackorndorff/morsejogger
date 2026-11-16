//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class CoreTests:XCTestCase {
    func testProfilesAndDefaultSettings() {
        XCTAssertEqual(ContestID.allCases.count,14)
        let s=ContestSettings()
        XCTAssertEqual(s.myCall,"VE3NEA");XCTAssertEqual(s.wpm,25);XCTAssertEqual(s.activity,2)
        XCTAssertEqual(s.duration,30);XCTAssertEqual(s.bandwidth,500);XCTAssertEqual(s.pitch,600)
        XCTAssertFalse(s.effects.qrm)
    }
    func testGenericSCPPoolFollowsUserCallsAndProvidesFallback() {
        var settings=ContestSettings()
        settings.mode = .single
        settings.singleCallStartDelay=1
        settings.seed=123
        settings.customCalls=["K1USER"]
        var generic=ImportedHistory()
        generic.calls=["W2SCP"]
        let simulator=ContestSimulator(settings:settings,genericHistory:generic)
        XCTAssertEqual(simulator.fixtureDrawCallerCalls(1),["K1USER"])
        XCTAssertEqual(simulator.fixtureDrawCallerCalls(1),["K1USER"],
                       "Regular modes may draw a previously worked call again before exhausting a unique-call pool")
    }
    func testSuperCheckPartialTextSkipsHeadersAndDeduplicatesCalls() throws {
        let text = """
        !!Order,1,1
        ; Super Check Partial
        !!Order,1,1
        # generated list
        K1ABC
        W2XYZ, VE3/P
        K1ABC ; W2COMMENT
        MASTER.SCP
        """
        let history=try HistoryImport.superCheckPartial(text)
        XCTAssertEqual(history.sourceName,"Super Check Partial")
        XCTAssertEqual(history.calls,["K1ABC","W2XYZ","VE3/P"])
    }
    func testSuperCheckPartialRejectsHTMLAndSingleCallPayloads() {
        XCTAssertThrowsError(try HistoryImport.superCheckPartial("!!Order,1,1\n<!doctype html><html><body>K1ABC W2XYZ</body></html>"))
        XCTAssertThrowsError(try HistoryImport.superCheckPartial("!!Order,1,1\nK1ABC\n"))
        XCTAssertThrowsError(try HistoryImport.superCheckPartial("K1ABC\nW2XYZ\n"))
    }
    func testCompetitionOverrides() {
        var s=ContestSettings()
        s.mode = .wpxCompetition
        let w=s.effective()
        XCTAssertTrue(w.effects.qrn && w.effects.qrm && w.effects.qsb && w.effects.flutter && w.effects.lids)
        s.mode = .hstCompetition
        let h=s.effective()
        XCTAssertFalse(h.effects.qrn || h.effects.qrm || h.effects.qsb || h.effects.flutter || h.effects.lids)
        XCTAssertEqual(h.bandwidth,600)
        XCTAssertEqual(h.activity,4)
        XCTAssertEqual(h.contest, .wpx, "HST mode must preserve the explicitly selected contest")
        XCTAssertEqual(h.serialRange, .start, "The default Start serial range is preserved")
        s.contest = .cqww
        s.serialRange = .end
        let invalidHST = s.effective()
        XCTAssertEqual(invalidHST.contest, .cqww)
        XCTAssertEqual(invalidHST.serialRange, .end, "Session validation, not normalization, enforces HST requirements")
        s.mode = .pileup
        XCTAssertFalse(s.effective().effects.qrn)
    }
    func testCompetitionEffectiveSettingsDoNotOverwriteSavedPracticePreferences() throws {
        var saved = ContestSettings()
        saved.activity = 8
        saved.bandwidth = 350
        saved.effects = .all(false)
        saved.mode = .wpxCompetition

        let wpx = saved.effective()
        XCTAssertTrue(wpx.effects.qrn && wpx.effects.qrm && wpx.effects.qsb && wpx.effects.flutter && wpx.effects.lids)
        XCTAssertEqual(wpx.activity, 8)
        XCTAssertEqual(wpx.bandwidth, 350)

        saved.effects = .all(true)
        saved.mode = .hstCompetition
        let hst = saved.effective()
        XCTAssertEqual(hst.activity, 4)
        XCTAssertEqual(hst.bandwidth, 600)
        XCTAssertFalse(hst.effects.qrn || hst.effects.qrm || hst.effects.qsb || hst.effects.flutter || hst.effects.lids)

        let relaunched = try JSONDecoder().decode(ContestSettings.self, from: JSONEncoder().encode(saved))
        var practice = relaunched
        practice.mode = .pileup
        XCTAssertEqual(practice.effective().activity, 8)
        XCTAssertEqual(practice.effective().bandwidth, 350)
        XCTAssertTrue(practice.effective().effects.qrn && practice.effective().effects.qrm && practice.effective().effects.qsb && practice.effective().effects.flutter && practice.effective().effects.lids)
    }
    func testScoreVectors() {
        var s=ContestSettings(),st=Station(call:"DL1ABC",exchange:"599 001",wpm:22,tone:600,volume:0.8,shift:0)
        s.contest = .wpx
        XCTAssertEqual(ContestRules.score(s,station:st).multipliers,["P:DL1"])
        s.contest = .cqww
        XCTAssertEqual(ContestRules.score(s,station:st).points,3)
        s.contest = .fieldday
        XCTAssertEqual(ContestRules.score(s,station:st).points,2)
        s.contest = .arrldx
        XCTAssertEqual(ContestRules.score(s,station:st).points,3)
        s.contest = .sst;st.state="DX"
        XCTAssertEqual(ContestRules.score(s,station:st).multipliers,["DX:DL"])
        s.contest = .arrl10
        XCTAssertEqual(ContestRules.score(s,station:st).points,4)
    }
    func testExchangeAndSweepstakes() {
        var s=ContestSettings()
        s.contest = .wpx
        XCTAssertTrue(ContestRules.checkExchange(s,received:"599 1",expected:"599 001").valid)
        XCTAssertFalse(ContestRules.checkExchange(s,received:"599 TT1",expected:"599 001").valid,"MRCE reads a WPX serial with StrToIntDef")
        XCTAssertFalse(ContestRules.checkExchange(s,received:"599 002",expected:"599 001").valid)
        s.contest = .sweepstakes
        XCTAssertTrue(ContestRules.checkExchange(s,received:"023 A 86 CT",expected:"023 A K1ABC 86 CT").valid)
        XCTAssertTrue(SweepstakesParser.parse(call:"K1ABC",exchange:"023 A 86 CT").complete)
        XCTAssertTrue(SweepstakesParser.parse(call:"K1ABC",exchange:"86 CT 023 A").complete)
        // N1MM entry rules: typing a field again corrects it, and the last value wins.
        let corrected=SweepstakesParser.parse(call:"K1ABC",exchange:"023 A 86 CT 87 OR B")
        XCTAssertTrue(corrected.complete)
        XCTAssertEqual([corrected.serial,corrected.precedence,corrected.check,corrected.section],["23","B","87","OR"])
        XCTAssertTrue(SweepstakesParser.parse(call:"K1ABC",exchange:"23A86CT").complete,"fields may be run together")
    }
    func testPoissonAndTimeline() {
        var a=ContestRNG(seed:123),b=ContestRNG(seed:123)
        XCTAssertEqual((0..<200).map{_ in a.poisson(1)},(0..<200).map{_ in b.poisson(1)})
        var settings=ContestSettings();settings.seed=1234;settings.mode = .single
        let game=ContestSimulator(settings:settings)
        game.start()
        game.tick(6.0 * 512.0 / 11025.0)
        XCTAssertEqual(game.pileup.count,1)
        XCTAssertFalse(game.drainEvents().contains(where:{$0.kind == .notice && $0.text.contains("single caller")}))
        let call=game.pileup[0].call
        game.command(.call,call:call)
        game.tick(20)
        XCTAssertEqual(game.target?.call,call)
        XCTAssertTrue([OperatorState.needEnd,.needNr].contains(game.target?.opState ?? .failed))
        if game.target?.opState == .needNr {game.command(.exchange);game.tick(40)}
        if let target=game.target {
            game.tick(65)
            let entry=game.logQSO(call:target.call,exchange:target.exchange)
            XCTAssertNotNil(entry)
        }
    }
    func testHistoryParsing() throws {
        let data="!!Order!!,Call,Name,State,CK,SECT\nK1ABC,BOB,CT,86,CT\n"
        let history=try HistoryImport.mrceHistory(data,contest:.sweepstakes)
        XCTAssertEqual(history.records["K1ABC"]?.check,"86")
        XCTAssertEqual(history.calls,["K1ABC"])
        XCTAssertThrowsError(try HistoryImport.masterDTA([1,2,3]))
    }
}

final class NativeParityCoverageTests:XCTestCase {
    func testAllProfilesHaveRealScoringRules() {
        var settings=ContestSettings()
        let station=Station(call:"DL1ABC",exchange:"599 011",wpm:26,tone:590,volume:0.8,shift:0)
        for contest in ContestID.allCases {
            settings.contest=contest
            let rule=ContestRules.score(settings,station:station)
            XCTAssertGreaterThanOrEqual(rule.points,0,"\(contest.rawValue) returned a negative score")
            XCTAssertFalse(contest.label.isEmpty)
            XCTAssertFalse(contest.exchangeLabel.isEmpty)
        }
    }
    func testFirstSerialStaysPerContest() {
        var settings=ContestSettings()
        var wpx=settings.exchangeProfile(for:.wpx);wpx.firstSerial=123;settings.setExchangeProfile(wpx,for:.wpx)
        settings.contest = .wpx
        XCTAssertEqual(ContestRules.sentExchange(settings,serial:7),"5NN 129")
        settings.contest = .fieldday
        XCTAssertEqual(ContestRules.sentExchange(settings,serial:7),"3A OR")
    }
    func testArrivalSamplerAndCallerPopulation() {
        var settings=ContestSettings();settings.seed=97;settings.activity=9
        let game=ContestSimulator(settings:settings)
        game.start()
        game.command(.cq)
        game.tick(20)
        XCTAssertGreaterThan(game.pending,0)
        XCTAssertTrue(game.pileup.allSatisfy{HistoryImport.isCall($0.call)})
    }
    func testSpeedZeroOffsetAndLegacyBehavior() {
        var settings=ContestSettings();settings.mode = .single;settings.seed=99
        settings.wpm=25;settings.dxMinWpm=0;settings.dxMaxWpm=0
        let exact=ContestSimulator(settings:settings);exact.start();exact.tick(6.0 * 512.0 / 11025.0)
        XCTAssertEqual(exact.pileup[0].wpm,25)
        settings.dxMinWpm = -1
        let legacy=ContestSimulator(settings:settings);legacy.start();legacy.tick(6.0 * 512.0 / 11025.0)
        XCTAssertLessThanOrEqual(legacy.pileup[0].wpm,25)
        XCTAssertGreaterThanOrEqual(legacy.pileup[0].wpm,12)
        settings.dxMinWpm=10;settings.dxMaxWpm=0
        let low=ContestSimulator(settings:settings);low.start();low.tick(6.0 * 512.0 / 11025.0)
        XCTAssertGreaterThanOrEqual(low.pileup[0].wpm,15)
        XCTAssertLessThanOrEqual(low.pileup[0].wpm,25)
    }
    func testWpmAndKeyerTimings() {
        XCTAssertGreaterThan(ContestRules.cwSeconds("CQ K1ABC",wpm:15),ContestRules.cwSeconds("CQ K1ABC",wpm:40))
        XCTAssertTrue(ContestRules.cwSeconds("CQ K1ABC",wpm:25).isFinite)
        XCTAssertEqual(ContestRules.morseSymbols("/"),"-..-.")
        XCTAssertEqual(ContestRules.hstCallScore(""),0)
    }
    func testTransmittedAudioGate() {
        var settings=ContestSettings();settings.mode = .single;settings.seed=122
        let game=ContestSimulator(settings:settings);game.start();game.tick(6.0 * 512.0 / 11025.0)
        let call=game.pileup[0].call
        _ = game.drainEvents()
        game.command(.call,call:call)
        XCTAssertNil(game.target)
        XCTAssertTrue(game.drainEvents().contains(where:{$0.kind == .transmit}))
        game.tick(0.1)
        XCTAssertNil(game.target)
        game.tick(22)
        XCTAssertEqual(game.target?.call,call)
    }
    func testFastFiveNineNinePercentageAndCompetitionLock() {
        var settings=ContestSettings();settings.mode = .single;settings.seed=10
        settings.fast5nn=true;settings.fast5nnOccurrenceRate=100
        let game=ContestSimulator(settings:settings);game.start();game.tick(6.0 * 512.0 / 11025.0);let call=game.pileup[0].call
        _ = game.drainEvents();game.command(.call,call:call)
        let fastTX=game.drainEvents().last(where:{$0.kind == .transmit})
        XCTAssertTrue(fastTX?.text.contains("5NN") == true)
        XCTAssertNotNil(fastTX?.fastReportStart)
        XCTAssertTrue((1.2...1.5).contains(fastTX?.fastReportRate ?? 0))
        settings.mode = .hstCompetition
        let hst=ContestSimulator(settings:settings);hst.start();let hstCall=hst.pileup[0].call
        _ = hst.drainEvents();hst.command(.call,call:hstCall)
        let hstTX=hst.drainEvents().last(where:{$0.kind == .transmit})
        XCTAssertTrue(hstTX?.text.contains("5NN") == true)
        XCTAssertNil(hstTX?.fastReportStart,"HST competition locks Fast 5NN timing")
    }
    func testMasterAndAR10Imports() throws {
        let bytesCount=37*37*4+4
        var raw=[UInt8](repeating:0,count:bytesCount)
        func write(_ value:Int,_ position:Int) {
            for i in 0..<4 {raw[position+i]=UInt8((value>>(i*8))&0xff)}
        }
        for i in 0..<(37*37+1) {write(bytesCount,i*4)}
        raw += Array("K1ABC\0DL1ABC\0".utf8)
        write(raw.count,37*37*4)
        let calls=try HistoryImport.masterDTA(raw)
        XCTAssertEqual(calls.calls,["K1ABC","DL1ABC"])
        let file="cabrillo_id\tyear\tcall\tsection\tdxcc\nARRL-10\t2025\tK1ABC\tEMA\tK\n"
        let imported=try HistoryImport.arrl10TSV(file)
        XCTAssertEqual(imported.records["K1ABC"]?.state,"MA")
    }
    func testPortablePrefixes() {
        XCTAssertEqual(ContestRules.callMeta("EA8/K1ABC").country,"EA")
        XCTAssertEqual(ContestRules.callMeta("K1ABC/P").country,"K")
        XCTAssertEqual(ContestRules.wpxPrefix("K1ABC/7"),"K7")
        XCTAssertEqual(ContestRules.normalizeCall(" k1abc/p "),"K1ABC/P")
    }
    func testSeededStationsReproducible() {
        var settings=ContestSettings();settings.mode = .hstCompetition;settings.seed=77
        let first=ContestSimulator(settings:settings),second=ContestSimulator(settings:settings)
        first.start();second.start()
        XCTAssertEqual(first.pileup,second.pileup)
        XCTAssertEqual(first.pileup.count,first.settings.activity)
        XCTAssertEqual(first.drainEvents().map(\.text),second.drainEvents().map(\.text))
    }
    func testFallbackNamesAreDiverseAndSeeded() {
        var settings=ContestSettings();settings.mode = .hstCompetition;settings.seed=814
        let first=ContestSimulator(settings:settings),second=ContestSimulator(settings:settings)
        first.start();second.start()
        let names=first.pileup.map(\.name)
        XCTAssertEqual(names,second.pileup.map(\.name))
        XCTAssertEqual(Set(names).count,names.count,"Synthetic fallback names should not repeat within the initial station group")
    }
}

final class OperatorTransitionTests: XCTestCase {
    func testHisCallDoesNotFalselyCountAsSentExchange() {
        var options=ContestSettings(); options.seed=42;options.mode = .single
        let game=ContestSimulator(settings:options);game.start();game.tick(6.0 * 512.0 / 11025.0)
        let call=game.pileup[0].call
        game.command(.hiscall,call:call)
        game.tick(18)
        XCTAssertEqual(game.target?.call,call)
        XCTAssertEqual(game.target?.opState,.needNr)
    }
    func testRadioUpdatePreservesCompetitionEffectLocks() {
        var options=ContestSettings();options.mode = .wpxCompetition;options.seed=4
        let game=ContestSimulator(settings:options)
        var edited=options;edited.wpm=35;edited.effects = Effects()
        game.updateRadio(edited)
        XCTAssertEqual(game.settings.wpm,35)
        XCTAssertTrue(game.settings.effects.qrm)
    }
    func testOwnCallAndNilTouchCommandsEmitTxEvents() {
        var options=ContestSettings();options.mode = .single;options.seed=7
        let game=ContestSimulator(settings:options);game.start();game.tick(6.0 * 512.0 / 11025.0)
        _ = game.drainEvents()
        game.command(.mycall)
        XCTAssertTrue(game.drainEvents().contains(where:{$0.kind == .transmit && $0.text.contains("VE3NEA")}))
        game.command(.nil)
        XCTAssertTrue(game.drainEvents().contains(where:{$0.kind == .transmit && $0.text == "NIL"}))
    }
}
