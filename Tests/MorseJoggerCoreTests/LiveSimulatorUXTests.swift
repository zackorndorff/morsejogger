//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class LiveSimulatorUXTests: XCTestCase {
    private func startAndAdvanceSingle(_ game: ContestSimulator) {
        game.start()
        guard game.settings.mode == .single else { return }
        let threshold = Int((11025.0 / 512.0 * Double(game.settings.singleCallStartDelay) / 1000.0).rounded()) + 5
        game.tick(Double(threshold + 1) * 512.0 / 11025.0)
    }

    func testQSOEntryDecodesLegacyJSONWithoutStatusAsCompleted() throws {
        let legacy = #"{"id":7,"at":300,"call":"K2PEND","copiedCall":"K2PEND","sent":"599 007","received":"599 083","expected":"599 083","correct":false,"points":0,"multipliers":[],"note":"Pending TU confirmation","dupe":false,"callError":false,"exchangeErrors":[],"wpm":23}"#
        let entry = try JSONDecoder().decode(QSOEntry.self, from: Data(legacy.utf8))
        XCTAssertEqual(entry.status, .completed)
        XCTAssertNotEqual(entry.diagnosis.code, "PENDING")
    }

    func testMRCEFunctionKeyAssignmentsAndWipeSlot() {
        XCTAssertEqual(Command.cq.functionKey,1)
        XCTAssertEqual(Command.exchange.functionKey,2)
        XCTAssertEqual(Command.tu.functionKey,3)
        XCTAssertEqual(Command.mycall.functionKey,4)
        XCTAssertEqual(Command.hiscall.functionKey,5)
        XCTAssertEqual(Command.b4.functionKey,6)
        XCTAssertEqual(Command.repeatMessage.functionKey,7)
        XCTAssertEqual(Command.nil.functionKey,8)
        XCTAssertEqual(Command.wipe.functionKey,11)
        XCTAssertEqual(Command.numberAgain.functionKey,12)
    }

    func testEnterLogsWrongButNonemptyExchangeForPostQSODiagnosis() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call
        let actualExchange=game.pileup[0].exchange
        game.command(.call,call:call)
        game.tick(20);_ = game.drainEvents()
        if game.target?.opState == .needNr { game.command(.exchange);game.tick(30);_ = game.drainEvents() }
        XCTAssertEqual(game.target?.opState,.needEnd)

        game.command(.esm,call:call,exchange:"599 999")
        XCTAssertEqual(game.log.count,1)
        XCTAssertFalse(game.log[0].correct)
        XCTAssertFalse(game.log[0].exchangeErrors.isEmpty)
        XCTAssertEqual(game.log[0].diagnosis.code,"PENDING")
        XCTAssertEqual(game.log[0].status,.pendingTUConfirmation)
        XCTAssertTrue(game.log[0].diagnosis.explanation.contains("Copied call \(call) matches"))
        XCTAssertTrue(game.log[0].diagnosis.explanation.contains("copied 599 999"))
        XCTAssertEqual(game.log[0].call,call,"Log stores the station's actual callsign")
        XCTAssertEqual(game.log[0].expected,actualExchange,"Expected exchange comes from the generated station")
        XCTAssertEqual(game.log[0].received,"599 999","Copied exchange comes from submitted input")
        XCTAssertTrue(game.drainEvents().contains(where:{$0.kind == .transmit && $0.text.hasPrefix("TU")}))
        game.tick(50)
        XCTAssertFalse(game.log[0].correct,"The caller accepts TU but the copied exchange remains wrong")
        XCTAssertFalse(game.log[0].exchangeErrors.isEmpty)
    }
    func testCopiedCallMismatchRemainsVisibleInCompletedLogDiagnosis() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let actual=game.pileup[0].call,exchange=game.pileup[0].exchange
        game.command(.call,call:actual)
        game.tick(20);_ = game.drainEvents()
        if game.target?.opState == .needNr {
            game.command(.exchange);game.tick(40);_ = game.drainEvents()
        }
        XCTAssertEqual(game.target?.opState,.needEnd)
        game.command(.tu);game.tick(60);_ = game.drainEvents()
        XCTAssertEqual(game.target?.opState,.done)

        let wrongCopy=String(actual.dropLast())+(actual.last == "X" ? "Y" : "X")
        game.command(.hiscall,call:wrongCopy);game.tick(80);_ = game.drainEvents()
        XCTAssertEqual(game.target?.opState,.done,"The fuzzy copied call establishes the mcAlmost confidence threshold")
        game.command(.saveOnly,call:wrongCopy,exchange:exchange)

        let entry=try! XCTUnwrap(game.log.first)
        XCTAssertEqual(entry.call,actual)
        XCTAssertEqual(entry.copiedCall,wrongCopy)
        XCTAssertTrue(entry.callError)
        XCTAssertFalse(entry.correct)
        XCTAssertEqual(entry.diagnosis.code,"CALL")
        XCTAssertTrue(entry.diagnosis.explanation.contains(wrongCopy))
        XCTAssertTrue(entry.diagnosis.explanation.contains(actual))
    }
    func testSaveOnlyStripsWildcardAndFuzzyAssociationStillDiagnosesBustedCall() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let actual=game.pileup[0].call,exchange=game.pileup[0].exchange
        let fuzzy=String(actual.dropLast())+(actual.last == "X" ? "Y" : "X")
        game.command(.call,call:fuzzy);game.tick(20);_ = game.drainEvents()
        if game.target?.opState == .needNr {game.command(.exchange);game.tick(30);_ = game.drainEvents()}
        game.command(.tu);game.tick(60);_ = game.drainEvents()
        XCTAssertEqual(game.target?.opState,.done)

        game.command(.saveOnly,call:fuzzy+"?",exchange:exchange)

        XCTAssertEqual(game.log.count,1)
        XCTAssertEqual(game.log[0].call,actual)
        XCTAssertEqual(game.log[0].copiedCall,fuzzy,"Save removes wildcard punctuation from the copied callsign")
        XCTAssertTrue(game.log[0].callError,"Fuzzy matching associates a station but does not verify the copied call")
        XCTAssertEqual(game.log[0].diagnosis.code,"CALL")
        XCTAssertTrue(game.log[0].diagnosis.explanation.contains("Correct the call to \(actual)"))
    }
    func testSaveOnlyRejectsInvalidCallWithoutCreatingRow() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call,exchange=game.pileup[0].exchange
        game.command(.call,call:call);game.tick(20);_ = game.drainEvents()
        let invalid=call+"-"
        XCTAssertNil(game.logQSO(call:invalid,exchange:exchange),"Normal log validation must inspect raw input before normalization")
        game.command(.saveOnly,call:invalid,exchange:exchange)
        XCTAssertTrue(game.log.isEmpty)
        XCTAssertEqual(game.selectedCall,call,"Rejected Save Only leaves the entry available for correction")
        XCTAssertTrue(game.drainEvents().allSatisfy{$0.kind != .transmit})

        game.command(.saveOnly,call:" \n\(call)\t",exchange:exchange)
        XCTAssertEqual(game.log.count,1,"Outer whitespace is permitted around an otherwise valid exact callsign")
        XCTAssertEqual(game.log[0].copiedCall,call)
    }
    func testExplicitEmptyLogReportsInputErrorWithoutRevealingCallerState() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        game.command(.log,call:" \n",exchange:"")
        let notice=game.drainEvents().first(where:{$0.kind == .notice})
        XCTAssertEqual(notice?.noticeCode,.callInvalid)
        XCTAssertEqual(notice?.text,RadioNoticeCode.callInvalid.safeDisplayText)
        XCTAssertEqual(notice.map(RadioActivityText.visible),RadioNoticeCode.callInvalid.safeDisplayText)
        game.command(.saveOnly,call:"",exchange:"")
        XCTAssertTrue(game.drainEvents().contains(where:{$0.kind == .notice && $0.noticeCode == .callInvalid}))
    }
    func testEmptyEnterStillSendsCQInsteadOfReportingEntryError() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        game.command(.esm,call:"",exchange:"")
        let events=game.drainEvents()
        XCTAssertTrue(events.contains(where:{$0.kind == .transmit && $0.text.contains("CQ")}))
        XCTAssertFalse(events.contains(where:{$0.kind == .notice && $0.noticeCode != nil}))
    }
    func testSaveOnlyQuestionMarkIsRemovedButOtherPunctuationIsRejected() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call,exchange=game.pileup[0].exchange
        game.command(.call,call:call);game.tick(20);_ = game.drainEvents()
        game.command(.saveOnly,call:call+"?",exchange:exchange)
        XCTAssertEqual(game.log.count,1)
        XCTAssertEqual(game.log[0].copiedCall,call,"Save Only strips question marks before validating")

        game.command(.saveOnly,call:call+"-",exchange:exchange)
        XCTAssertEqual(game.log.count,1,"Invalid punctuation must not create another row")
        XCTAssertEqual(game.selectedCall,call,"A rejected punctuation edit stays available for correction")
        XCTAssertTrue(game.drainEvents().contains(where:{$0.kind == .notice && $0.text.contains("valid callsign")}))
    }
    func testSweepstakesEmbeddedCallCorrectionSurvivesSaveOnly() {
        var s=ContestSettings();s.contest = .sweepstakes;s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let actual=game.pileup[0].call,exchange=game.pileup[0].exchange
        let copied=String(actual.dropLast())+(actual.last == "X" ? "Y" : "X")
        game.command(.call,call:copied);game.tick(20);_ = game.drainEvents()
        if [.needNr,.needCallNr].contains(game.target?.opState) {game.command(.exchange);game.tick(30);_ = game.drainEvents()}
        if game.target?.opState == .needCall {game.command(.hiscall,call:actual);game.tick(40);_ = game.drainEvents()}
        XCTAssertEqual(game.target?.opState,.needEnd)
        game.command(.tu);game.tick(60);_ = game.drainEvents()
        XCTAssertEqual(game.target?.opState,.done)

        game.command(.saveOnly,call:copied,exchange:exchange)
        XCTAssertEqual(game.log.count,1)
        XCTAssertEqual(game.log[0].copiedCall,actual,"The SS exchange's embedded corrected call replaces the copied call")
        XCTAssertFalse(game.log[0].callError)
        XCTAssertTrue(game.log[0].correct)
    }
    func testSweepstakesEmbeddedCallCorrectionSurvivesDeferredLogReconciliation() {
        var s=ContestSettings();s.contest = .sweepstakes;s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let actual=game.pileup[0].call,exchange=game.pileup[0].exchange
        let copied=String(actual.dropLast())+(actual.last == "X" ? "Y" : "X")
        game.command(.call,call:copied);game.tick(20);_ = game.drainEvents()
        if [.needNr,.needCallNr].contains(game.target?.opState) {game.command(.exchange);game.tick(30);_ = game.drainEvents()}
        if game.target?.opState == .needCall {game.command(.hiscall,call:actual);game.tick(40);_ = game.drainEvents()}
        XCTAssertEqual(game.target?.opState,.needEnd)

        let provisional=try! XCTUnwrap(game.logQSO(call:copied,exchange:exchange))
        XCTAssertEqual(provisional.copiedCall,actual,"The pending row parses the SS correction immediately")
        game.tick(70)

        XCTAssertEqual(game.log.count,1)
        XCTAssertEqual(game.log[0].id,provisional.id)
        XCTAssertEqual(game.log[0].copiedCall,actual,"Deferred SaveQso reconciliation retains the parsed corrected call")
        XCTAssertFalse(game.log[0].callError)
        XCTAssertTrue(game.log[0].correct)
        XCTAssertEqual(game.verified,1)
    }

    func testEnterWithBlankExchangeRequestsRepeatWithoutLoggingOrTU() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call
        game.command(.call,call:call)
        game.tick(20);_ = game.drainEvents()
        if game.target?.opState == .needNr { game.command(.exchange);game.tick(30);_ = game.drainEvents() }

        game.command(.esm,call:call,exchange:" \n ")
        XCTAssertEqual(game.log.count,0)
        let transmitted=game.drainEvents().filter{$0.kind == .transmit}.map(\.text)
        XCTAssertFalse(transmitted.contains(where:{$0.hasPrefix("TU")}))
        XCTAssertTrue(transmitted.contains("?"),"An empty exchange should request a repeat")
    }

    func testEnterWithMalformedExchangeDoesNotSendTUOrLog() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call
        game.command(.call,call:call)
        game.tick(20);_ = game.drainEvents()
        if game.target?.opState == .needNr { game.command(.exchange);game.tick(30);_ = game.drainEvents() }

        game.command(.esm,call:call,exchange:"59 999")
        XCTAssertEqual(game.log.count,0)
        let events=game.drainEvents()
        XCTAssertFalse(events.contains(where:{$0.kind == .transmit && $0.text.hasPrefix("TU")}))
        XCTAssertTrue(events.contains(where:{$0.kind == .notice && $0.text.contains("incomplete or invalid")}))
    }

    func testExchangeStructureMatchesContestFieldMinimums() {
        var settings=ContestSettings();settings.contest = .naqp
        XCTAssertTrue(ContestRules.isExchangeStructurallyValid(settings,received:"JO",expected:"MIKE"),
                      "NAQP DX callers send a name without a second field")
        XCTAssertTrue(ContestRules.isExchangeStructurallyValid(settings,received:"JO X",expected:"MIKE OR"),
                      "NAQP's second field only needs to be nonempty")

        settings.contest = .cwt
        XCTAssertTrue(ContestRules.isExchangeStructurallyValid(settings,received:"JO 1",expected:"MIKE 1234"),
                      "CWT's serial field accepts a one-character value")

        settings.contest = .sweepstakes
        XCTAssertTrue(ContestRules.isExchangeStructurallyValid(settings,received:"A 72 XX",expected:"001 A K1ABC 86 ON"),
                      "Sweepstakes accepts an omitted serial with a syntactically formed exchange")
        XCTAssertFalse(ContestRules.isExchangeStructurallyValid(settings,received:"A 7 XX",expected:"001 A K1ABC 86 ON"),
                       "Sweepstakes requires a two-digit check")
    }

    func testMRCEQuestionMacroTransmitsQuestionMark() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        game.command(.repeatMessage)
        XCTAssertEqual(game.drainEvents().filter{$0.kind == .transmit}.map(\.text),["?"])
    }
    func testF7AndF12TransmitDifferentMacrosButUseTheCallersCurrentReplyState() {
        for (command,expectedTX) in [(Command.repeatMessage,"?"),(.numberAgain,"NR?")] {
            var s=ContestSettings();s.mode = .single;s.seed=172
            let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
            let station=game.pileup[0]
            game.command(command)
            XCTAssertEqual(game.drainEvents().filter{$0.kind == .transmit}.map(\.text),[expectedTX])
            game.tick(20)
            game.tick(30)
            let reply=game.drainEvents().first(where:{$0.kind == .receive && $0.reason == "repeat"})
            XCTAssertEqual(reply?.voices.map(\.message),[station.sentCall],
                           "(expectedTX) uses the waiting caller's normal need-QSO reply")
        }
    }
    func testEnterAfterF12ExchangeRepeatSendsTUAndCompletesContact() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call,exchange=game.pileup[0].exchange
        game.command(.hiscall,call:call)
        game.tick(20);_ = game.drainEvents()
        XCTAssertEqual(game.targetCall,call)
        XCTAssertEqual(game.target?.opState,.needNr)

        game.command(.numberAgain)
        game.tick(40);_ = game.drainEvents()
        game.tick(50);_ = game.drainEvents()

        game.command(.esm,call:call,exchange:exchange)
        let tx=game.drainEvents().filter{$0.kind == .transmit}.map{CallerExchangeTextTests.ownCanonical($0.text)}
        XCTAssertTrue(tx.contains(ContestRules.sentExchange(s,serial:1)),"Enter must finish the exchange response after F12 requested it again")
        XCTAssertTrue(tx.contains(where:{$0.hasPrefix("TU")}),"Enter must send TU once the copied exchange is present")
        XCTAssertEqual(game.log.count,1)
        XCTAssertEqual(game.log[0].note,"Pending TU confirmation")

        game.tick(70)
        XCTAssertTrue(game.log[0].correct)
        XCTAssertEqual(game.log[0].status,.completed)
        XCTAssertEqual(game.verified,1)
        XCTAssertNil(game.targetCall,"The caller must stop calling after accepting TU")
    }
    func testEnterAfterF7OrF12RepeatSavesWhenCallAndExchangeWereAlreadySent() {
        for repeatCommand in [Command.repeatMessage,.numberAgain] {
            var s=ContestSettings();s.mode = .single;s.seed=1234
            let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
            let call=game.pileup[0].call,exchange=game.pileup[0].exchange
            game.command(.call,call:call)
            game.tick(20);_ = game.drainEvents()
            game.tick(30);_ = game.drainEvents()
            XCTAssertEqual(game.target?.opState,.needEnd)
            XCTAssertEqual(game.fixtureSentFlags().call,true)
            XCTAssertEqual(game.fixtureSentFlags().exchange,true)

            game.command(repeatCommand)
            game.tick(50);_ = game.drainEvents()
            game.tick(60);_ = game.drainEvents()

            game.command(.esm,call:call,exchange:exchange)
            let tx=game.drainEvents().filter{$0.kind == .transmit}.map(\.text)
            XCTAssertEqual(tx.first,"TU","After either repeat request, Enter must finish the already-sent exchange with TU")
            XCTAssertEqual(game.log.count,1)
            XCTAssertEqual(game.log[0].note,"Pending TU confirmation")
            game.tick(80)
            XCTAssertTrue(game.log[0].correct)
            XCTAssertEqual(game.verified,1)
            XCTAssertNil(game.targetCall)
        }
    }
    func testEnterThenF7RepeatThenEnterSendsTUAndLogs() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call,exchange=game.pileup[0].exchange

        game.command(.esm,call:call)
        let firstTX=game.drainEvents().filter{$0.kind == .transmit}.map(\.text)
        XCTAssertEqual(firstTX.count,2,"Initial Enter keys HIS CALL, then the exchange")
        XCTAssertEqual(firstTX[0],call)
        XCTAssertEqual(CallerExchangeTextTests.ownCanonical(firstTX[1]),ContestRules.sentExchange(s,serial:1))
        XCTAssertEqual(game.fixtureSentFlags().call,true)
        XCTAssertEqual(game.fixtureSentFlags().exchange,true)
        game.tick(20);_ = game.drainEvents()
        game.tick(50);_ = game.drainEvents()

        XCTAssertEqual(game.target?.opState,.needEnd,"The caller has sent the exchange")
        game.command(.repeatMessage)
        game.command(.repeatMessage)
        game.tick(50);_ = game.drainEvents()
        game.tick(60);_ = game.drainEvents()
        game.tick(70);_ = game.drainEvents()

        game.command(.esm,call:call,exchange:exchange)
        let finalTX=game.drainEvents().filter{$0.kind == .transmit}.map(\.text)
        XCTAssertEqual(finalTX, ["TU"],"After F7 repeats and a complete RX exchange, Enter should TU directly")
        XCTAssertEqual(game.log.count,1)
        XCTAssertEqual(game.log[0].note,"Pending TU confirmation")
        game.tick(90)
        XCTAssertTrue(game.log[0].correct)
        XCTAssertEqual(game.verified,1)
        XCTAssertNil(game.targetCall,"The caller accepts TU and stops calling")
    }
    func testEnterTUWhileCallerIsOnAirWithRepeatedExchange() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call,exchange=game.pileup[0].exchange

        game.command(.esm,call:call)
        let initialTX=game.drainEvents().filter{$0.kind == .transmit}
        XCTAssertEqual(initialTX.count,2)
        XCTAssertEqual(CallerExchangeTextTests.ownCanonical(initialTX[1].text),ContestRules.sentExchange(s,serial:1))
        XCTAssertTrue(game.fixtureSentFlags().call && game.fixtureSentFlags().exchange)

        // Use the deterministic two-key F7 burst already covered by the
        // ordinary dialogue test; catch its reply as soon as it begins.
        game.tick(20);_ = game.drainEvents()
        let initialReplyEnd=game.fixtureCallerTransmitRanges(call).map(\.end).max() ?? 20
        let readyAt=max(20,initialReplyEnd)+0.2
        game.tick(readyAt);_ = game.drainEvents()
        XCTAssertEqual(game.target?.opState,.needEnd)
        game.command(.repeatMessage)
        game.command(.repeatMessage)
        let f7TX=game.drainEvents().filter{$0.kind == .transmit}.map(\.text)
        XCTAssertEqual(f7TX,["?","?"])

        // Catch the repeated exchange as it starts, and press Enter before
        // its recorded on-air interval finishes.
        var now=readyAt+0.05
        var enterAt=now
        var repeated:RadioEvent?
        var rangesAtReceive:[(start:Double,end:Double)] = []
        var trace:[RadioEvent]=[]
        for _ in 0..<200 where repeated == nil {
            game.tick(now)
            let events=game.drainEvents();trace.append(contentsOf:events)
            repeated=events.first(where:{$0.kind == .receive && $0.reason == "repeat"})
            if repeated != nil {enterAt=now;rangesAtReceive=game.fixtureCallerTransmitRanges(call)}
            now += 0.02
        }
        XCTAssertNotNil(repeated,"F7 should trigger a repeated caller exchange; state=\(String(describing:game.target?.opState)), trace=\(trace.map{($0.kind.rawValue,$0.reason,$0.text,$0.at)})")
        guard let reply=repeated?.voices.first else {
            XCTFail("F7 should trigger a repeated caller exchange; state=\(String(describing:game.target?.opState)), trace=\(trace.map{($0.kind.rawValue,$0.reason,$0.text,$0.at)})")
            return
        }
        let repeatedStart=repeated!.at
        let repeatedEnd=repeatedStart+ContestRules.cwSeconds(reply.message,wpm:reply.wpm)
        XCTAssertLessThan(enterAt,repeatedEnd,"Enter must be sent while the repeated exchange is on air")

        game.command(.esm,call:call,exchange:exchange)
        let enterEvents=game.drainEvents().filter{$0.kind == .transmit}
        let enterTX=enterEvents.map(\.text)
        let busyRanges=rangesAtReceive
        XCTAssertEqual(enterTX,["TU"],"The already-sent call and exchange make this Enter a TU")
        XCTAssertTrue(busyRanges.contains(where:{$0.start <= (enterEvents.first?.at ?? -.infinity) && (enterEvents.first?.at ?? .infinity) < $0.end}),"At Enter, one recorded caller transmission must still be on air: \(busyRanges)")
        XCTAssertEqual(game.log.count,1,"Enter creates its provisional row as soon as TU is queued")
        XCTAssertEqual(game.log[0].note,"Pending TU confirmation")

        let tuEnd=enterAt+ContestRules.cwSeconds("TU",wpm:s.wpm)+0.11
        XCTAssertLessThan(tuEnd,repeatedEnd,"TU should complete before the caller finishes transmitting")
        game.tick(tuEnd)
        let result=game.drainEvents()
        let traceText="call=\(call), initialTX=\(initialTX.map{($0.text,$0.at)}), F7TX=\(f7TX), receives=\(trace.filter{$0.kind == .receive}.map{($0.reason,$0.text,$0.at)}), repeat=\(reply.message) at \(repeatedStart) through \(repeatedEnd), callerRangesAtReceive=\(busyRanges), EnterAt=\(enterEvents.first?.at ?? -1), TU completion=\(tuEnd), callbackClock=\(game.fixtureClock), stateAfter=\(String(describing:game.target?.opState)), targetAfter=\(String(describing:game.targetCall)), log=(\(game.log.first?.note ?? ""), verified:\(game.log.first?.correct ?? false), diagnosis:\(game.log.first?.diagnosis.code ?? "")), notices=\(result.filter{$0.kind == .notice}.map(\.text))"
        XCTAssertEqual(game.targetCall,call,"MRCE ignores TU while this caller is in stSending. \(traceText)")
        XCTAssertNotEqual(game.target?.opState,.done,"The on-air caller must remain active after ignoring TU")
        XCTAssertEqual(game.log.count,1,"The single provisional row is reconciled in place")
        XCTAssertFalse(game.log[0].correct,"An ignored TU must not verify the contact")
        XCTAssertTrue(result.contains(where:{$0.kind == .notice && $0.text.contains("did not accept TU")}),
                      "Trace should distinguish a transmitted TU from caller acceptance. \(traceText)")
    }
    func testFirstEnterWithClearedCallAndExchangeFlagsSendsExchangeBeforeTU() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let actual=game.pileup[0].call,exchange=game.pileup[0].exchange
        let last=actual.last!
        let oldCall=String(actual.dropLast())+(last == "X" ? "Y" : "X")
        game.command(.hiscall,call:oldCall)
        game.tick(20);_ = game.drainEvents()
        XCTAssertEqual(game.targetCall,actual)

        // Changing Edit1 invalidates CallSent. With no prior NR sent, MRCE's
        // first Enter sends HIS CALL and our exchange, then waits for another
        // Enter before it sends TU and saves.
        game.command(.esm,call:actual,exchange:exchange)
        let firstTX=game.drainEvents().filter{$0.kind == .transmit}.map(\.text)
        XCTAssertTrue(firstTX.contains(where:{$0.hasPrefix(actual)}))
        XCTAssertTrue(firstTX.contains(where:{CallerExchangeTextTests.ownCanonical($0).contains(ContestRules.sentExchange(s,serial:1))}))
        XCTAssertFalse(firstTX.contains(where:{$0.hasPrefix("TU")}))
        XCTAssertTrue(game.log.isEmpty)
        XCTAssertEqual(game.fixtureSentFlags().call,true)
        XCTAssertEqual(game.fixtureSentFlags().exchange,true)

        game.tick(40);_ = game.drainEvents()
        game.command(.esm,call:actual,exchange:exchange)
        XCTAssertTrue(game.drainEvents().contains(where:{$0.kind == .transmit && $0.text.hasPrefix("TU")}))
        XCTAssertEqual(game.log.count,1)
    }
    func testF7RequestIsIgnoredWhileCallerExchangeIsStillTransmitting() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call
        game.command(.esm,call:call)
        let firstTX=try! XCTUnwrap(game.drainEvents().first(where:{$0.kind == .transmit}))
        let txEnd=MorseTimeline.blockPadded(ContestRules.cwSeconds(firstTX.text,wpm:s.wpm))

        var now=txEnd+0.05
        var received:RadioEvent?
        while now<txEnd+10 && received == nil {
            game.tick(now)
            received=game.drainEvents().first(where:{$0.kind == .receive})
            now += 0.05
        }
        let reply=try! XCTUnwrap(received?.voices.first,"The caller should answer the initial Enter")
        let replyEnd=(received?.at ?? now)+ContestRules.cwSeconds(reply.message,wpm:reply.wpm)
        XCTAssertLessThan(now-0.05,replyEnd,"Press F7 while the caller is still sending its exchange")

        game.command(.repeatMessage)
        XCTAssertEqual(game.drainEvents().filter{$0.kind == .transmit}.map(\.text),["?"])
        game.tick(now+ContestRules.cwSeconds("?",wpm:s.wpm)+0.2)
        XCTAssertFalse(game.drainEvents().contains(where:{$0.kind == .receive && $0.reason == "repeat"}),
                       "MRCE does not process F7 while the station's own transmission is on air")
    }
    func testPendingLogDiagnosisDistinguishesBustedCallFromExchangeMatch() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let actual=game.pileup[0].call,exchange=game.pileup[0].exchange
        game.command(.call,call:actual)
        game.tick(20);_ = game.drainEvents()
        let wrong=String(actual.dropLast())+(actual.last == "X" ? "Y" : "X")

        let pending=try! XCTUnwrap(game.logQSO(call:wrong,exchange:exchange))

        XCTAssertEqual(pending.diagnosis.code,"PENDING")
        XCTAssertTrue(pending.callError)
        XCTAssertTrue(pending.diagnosis.explanation.contains("Copied call \(wrong) does not match the station call \(actual)"))
        XCTAssertTrue(pending.diagnosis.explanation.contains("The copied exchange matches"))

        game.tick(40)
        XCTAssertEqual(game.log.first?.diagnosis.code,"CALL")
        XCTAssertTrue(game.log.first?.diagnosis.explanation.contains(wrong) ?? false)
    }
    func testF4AddsCallersOnlyAfterAQSOInPileupMode() {
        var s=ContestSettings();s.mode = .pileup;s.seed=72;s.activity=30
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        game.command(.mycall)
        game.tick(10);_ = game.drainEvents()
        XCTAssertTrue(game.pileup.isEmpty,"F4 before a logged QSO does not add callers")

        game.command(.cq)
        game.tick(30);_ = game.drainEvents()
        XCTAssertFalse(game.pileup.isEmpty)
        let first=game.pileup[0]
        game.command(.call,call:first.call)
        game.tick(50);_ = game.drainEvents()
        if game.target?.opState == .needNr {
            game.command(.exchange)
            game.tick(70);_ = game.drainEvents()
        }
        XCTAssertNotNil(game.logQSO(call:first.call,exchange:first.exchange))
        game.tick(90);_ = game.drainEvents()
        XCTAssertEqual(game.verified,1)
        let beforeF4=game.pileup.count

        var time=120.0
        for _ in 0..<4 where game.pileup.count == beforeF4 {
            game.command(.mycall)
            game.tick(time);_ = game.drainEvents()
            time += 10
        }

        XCTAssertGreaterThan(game.pileup.count,beforeF4,"F4 after a logged QSO triggers eligible caller arrivals")
    }

    func testNILIsIgnoredWhileCallerIsTransmitting() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call
        // Let the caller's reply actually start; a reply that is merely
        // scheduled is abandoned when the operator keys (MRCE evMeStarted).
        let range=try! XCTUnwrap(game.fixtureCallerTransmitRanges(call).first)
        game.tick(range.start+0.01);_ = game.drainEvents()
        let before=game.pileup[0].patience
        game.command(.nil)
        XCTAssertEqual(game.drainEvents().filter{$0.kind == .transmit}.map(\.text),["NIL"])
        XCTAssertEqual(game.pileup.first(where:{$0.call==call})?.patience,before,"Caller state must not change before NIL finishes transmitting")
        game.tick(game.fixtureClock+ContestRules.cwSeconds("NIL",wpm:s.wpm)+0.2)
        XCTAssertEqual(game.pileup.first(where:{$0.call==call})?.patience,before,
                       "MRCE ignores NIL while the caller is transmitting")
    }

    func testInstantNILWaitsForTransmissionThenDropsSelectedCaller() {
        var s=ContestSettings();s.mode = .single;s.seed=1234;s.nilInstant=true
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call
        game.command(.nil)
        XCTAssertTrue(game.pileup.contains(where:{$0.call==call}),"Instant NIL selection happens when the macro finishes")
        game.tick(game.fixtureClock+ContestRules.cwSeconds("NIL",wpm:s.wpm)+0.2)
        XCTAssertFalse(game.pileup.contains(where:{$0.call==call}))
    }

    func testEnterSendsNormalExchangeForUnmatchedCall() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        game.command(.esm,call:"ZZ9ZZZ")
        let tx=game.drainEvents().filter{$0.kind == .transmit}.map{CallerExchangeTextTests.ownCanonical($0.text)}
        // The keyer never reveals hidden caller state: same message as a match.
        XCTAssertEqual(tx,["ZZ9ZZZ",ContestRules.sentExchange(s,ownSerial:game.snapshot.serial)])
    }

    func testCompetitionTimerReflectsEffectiveModeNotPracticeSlider() {
        var s=ContestSettings();s.duration=2;s.competitionDuration=7
        XCTAssertEqual(s.effective().duration,2)
        s.mode = .wpxCompetition
        XCTAssertEqual(s.effective().duration,7)
        let game=ContestSimulator(settings:s)
        startAndAdvanceSingle(game)
        XCTAssertEqual(game.snapshot.remaining,420)
        game.tick(5)
        XCTAssertEqual(game.snapshot.remaining,415)
    }
    func testLongPracticeDurationsPersistAndExpireAtTheirSelectedBoundary() throws {
        for minutes in [90,120] {
            var settings=ContestSettings();settings.mode = .single;settings.duration=minutes
            let saved=try JSONEncoder().encode(settings)
            let reloaded=try JSONDecoder().decode(ContestSettings.self,from:saved)
            XCTAssertEqual(reloaded.duration,minutes)
            XCTAssertEqual(reloaded.effective().duration,minutes)

            let game=ContestSimulator(settings:reloaded);startAndAdvanceSingle(game);_ = game.drainEvents()
            let boundary=Double(minutes*60)
            game.tick(boundary-0.01)
            XCTAssertTrue(game.snapshot.running,"\(minutes)-minute practice should continue before expiry")
            game.tick(boundary)
            XCTAssertFalse(game.snapshot.running,"\(minutes)-minute practice should stop at expiry")
            XCTAssertEqual(game.snapshot.remaining,0)
            game.tick(boundary+0.01)
            XCTAssertFalse(game.snapshot.running,"practice must remain stopped after expiry")
        }
    }
    func testLongPracticeDurationDoesNotChangeCompetitionPreference() {
        var settings=ContestSettings();settings.duration=120;settings.competitionDuration=17
        XCTAssertEqual(settings.effective().duration,120)
        settings.mode = .wpxCompetition
        XCTAssertEqual(settings.effective().duration,17)
        XCTAssertEqual(settings.competitionDuration,17)
    }
    func testQuestionMarkWithoutCallRequestsRepeatInsteadOfSendingCopiedCall() {
        var s=ContestSettings();s.mode = .single;s.seed=172
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        game.command(.esm,call:"?")
        let tx=game.drainEvents().filter{$0.kind == .transmit}
        XCTAssertEqual(tx.map(\.text),["?"])
        XCTAssertEqual(game.selectedCall,"")
    }
    func testWildcardPartialAsksForClarificationWithoutPrematureExchange() throws {
        var s=ContestSettings();s.mode = .single;s.seed=172
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game)
        let station=game.pileup[0]
        _ = game.drainEvents()
        let partial=String(station.call.prefix(2))+"?"
        game.command(.esm,call:partial)
        let tx=game.drainEvents().filter{$0.kind == .transmit}
        XCTAssertEqual(tx.count,1)
        XCTAssertEqual(tx.first?.text,partial)
        XCTAssertFalse(tx[0].text.contains("599"))
        game.tick(5)
        let early=game.drainEvents()
        game.tick(10)
        let delivered=game.drainEvents()
        let correction=(early+delivered).first(where:{$0.kind == .receive})
        let received=try XCTUnwrap(correction,"A caller should respond to the partial call")
        XCTAssertEqual(received.stationCalls,[station.call])
        XCTAssertGreaterThan(received.at,tx[0].at)

        game.command(.esm,call:station.call,exchange:station.exchange)
        let enterTX=game.drainEvents().filter{$0.kind == .transmit}
        XCTAssertFalse(enterTX.isEmpty,"Enter should key the corrected callsign/exchange path")
        XCTAssertTrue(enterTX.allSatisfy{$0.at >= received.at},"Enter transmission follows the delivered correction")
        XCTAssertTrue((early+delivered).allSatisfy{$0.kind != .transmit},"The partial call and its response finish before Enter")
    }
    func testTwoQueuedMacrosDoNotPrematurelyTriggerReplies() {
        var s=ContestSettings();s.mode = .pileup;s.seed=72;s.activity=9
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        game.command(.cq)
        let first=game.drainEvents().first(where:{$0.kind == .transmit})!
        game.command(.mycall)
        let second=game.drainEvents().first(where:{$0.kind == .transmit})!
        XCTAssertEqual(second.text,s.myCall)
        let firstEnd=MorseTimeline.blockPadded(ContestRules.cwSeconds(first.text,wpm:s.wpm))
        let secondEnd=firstEnd+MorseTimeline.blockPadded(ContestRules.cwSeconds(second.text,wpm:s.wpm))
        game.tick(firstEnd+0.005)
        XCTAssertTrue(game.drainEvents().allSatisfy{$0.kind != .receive},"CQ must not create a caller midway through queued MY CALL")
        game.tick(secondEnd+0.01)
        XCTAssertGreaterThanOrEqual(game.pileup.count,1,"Queued CQ should still produce calls")
    }
    func testQueuedCallAndHisCallUseTheirOwnCallerMatches() {
        var s=ContestSettings();s.mode = .pileup;s.seed=72;s.activity=9
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        game.command(.cq);game.tick(20);_ = game.drainEvents()
        XCTAssertGreaterThanOrEqual(game.pileup.count,2)
        let first=game.pileup[0],second=game.pileup[1]

        game.command(.call,call:first.call)
        let firstTX=game.drainEvents().filter{$0.kind == .transmit}.map(\.text)
        game.command(.hiscall,call:second.call)
        let secondTX=try! XCTUnwrap(game.drainEvents().first(where:{$0.kind == .transmit}))
        XCTAssertEqual(firstTX.first,first.call)
        XCTAssertEqual(secondTX.text,second.call)
        let firstEnd=20+firstTX.reduce(0){$0+ContestRules.cwSeconds($1,wpm:s.wpm)+0.1}
        let secondEnd=firstEnd+ContestRules.cwSeconds(secondTX.text,wpm:s.wpm)+0.2

        game.tick(firstEnd)
        XCTAssertNil(game.targetCall,"Actions in one uninterrupted keyer burst react after the final piece")
        XCTAssertEqual(game.pileup.first(where:{$0.call==first.call})?.opState,.needQso)
        XCTAssertEqual(game.pileup.first(where:{$0.call==second.call})?.opState,.needQso,
                       "Neither queued action reacts before the burst ends")

        game.tick(secondEnd)
        // MRCE hands every caller one message set ([his call, NR]) and matches
        // it against the call in the entry box when the burst ends: the last one.
        XCTAssertEqual(game.targetCall,second.call,"The burst matches the call keyed last")
        XCTAssertEqual(game.pileup.first(where:{$0.call==first.call})?.opState,.needPrevEnd,
                       "A mismatched call makes the earlier caller wait for the end of that QSO")
        XCTAssertTrue([OperatorState.needEnd,.needNr].contains(game.pileup.first(where:{$0.call==second.call})?.opState),
                      "The matched caller hears its call and the exchange in one event")
    }
    func testBackToBackCQActsAsOneStationArrivalTrigger() {
        var s=ContestSettings();s.mode = .pileup;s.seed=72;s.activity=9
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        game.command(.cq);game.command(.cq)
        _ = game.drainEvents()
        game.tick(30)
        let receives=game.drainEvents().filter{$0.kind == .receive}
        XCTAssertLessThanOrEqual(receives.count,1,"Two queued CQs should produce one aggregate caller-reaction event")
    }
    func testStopAbortsQueuedMacrosAndPreventCQCaller() {
        var s=ContestSettings();s.mode = .pileup;s.activity=9;s.seed=72
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        game.command(.cq);game.command(.mycall)
        game.command(.stop)
        _ = game.drainEvents()
        game.tick(25)
        XCTAssertEqual(game.pileup.count,0)
        XCTAssertFalse(game.drainEvents().contains(where:{$0.kind == .receive}))
    }
    func testEscapeReactsToAnOverlappingOperatorCallAndDiscardsQueuedMacro() {
        var s=ContestSettings();s.mode = .single;s.seed=172
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call
        game.command(.call,call:call)
        game.command(.mycall)
        game.command(.stop)
        let stopped=game.drainEvents()
        XCTAssertTrue(stopped.contains(where:{$0.kind == .stopAudio}),"STOP must tell the host to cut current audio immediately")
        XCTAssertTrue(stopped.contains(where:{$0.kind == .receive}) == false,"Caller audio is scheduled after Escape's garbage event")
        game.tick(30)
        XCTAssertTrue(game.drainEvents().contains(where:{$0.kind == .receive}),"A caller processes partial garbage and may repeat its current message")
    }
    func testEscapeClearsOnlySentPartsPresentInTheAbortedKeyerBurst() {
        var s=ContestSettings();s.mode = .single;s.seed=172
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        game.command(.call,call:game.pileup[0].call)
        XCTAssertEqual(game.fixtureSentFlags().call,true)
        XCTAssertEqual(game.fixtureSentFlags().exchange,true)
        game.command(.stop)
        XCTAssertEqual(game.fixtureSentFlags().call,false)
        XCTAssertEqual(game.fixtureSentFlags().exchange,false)

        game.command(.numberAgain)
        XCTAssertEqual(game.fixtureSentFlags().exchange,false,"F12 NR? is a repeat request, not the F2 exchange token that sets NrSent")
    }
    func testF12AndManualTUUseMRCEStationIDRules() {
        var s=ContestSettings();s.mode = .pileup;s.stationIdRate=3;s.seed=172
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        game.fixtureSetStationIDCount(2)
        game.command(.tu)
        XCTAssertEqual(game.drainEvents().filter{$0.kind == .transmit}.map(\.text),["TU \(s.myCall)"])
        game.tick(20)
        XCTAssertEqual(game.fixtureStationIDCount(),2,"Without a completed QSO, TU does not advance the three-QSO ID counter")
        game.fixtureSetStationIDCount(3)
        game.command(.tu)
        XCTAssertEqual(game.drainEvents().filter{$0.kind == .transmit}.map(\.text),["TU \(s.myCall)"])
        game.tick(30)
        XCTAssertEqual(game.fixtureStationIDCount(),0,"Finishing TU at the threshold resets the consecutive-QSO counter")
        game.command(.numberAgain)
        XCTAssertEqual(game.fixtureSentFlags().exchange,false)
    }
    func testInstantNILPrefersActiveThenTransmittingThenWaitingCallers() {
        var s=ContestSettings();s.nilInstant=true;s.mode = .pileup
        let game=ContestSimulator(settings:s)
        func station(_ call:String,_ state:OperatorState,_ volume:Double) -> Station {
            var st=Station(call:call,exchange:"599 001",wpm:25,tone:600,volume:volume,shift:0)
            st.opState=state
            return st
        }
        let waiting=station("K1AAA",.needQso,0.99)
        let active=station("K1BBB",.needNr,0.5)
        XCTAssertEqual(game.fixtureDropInstantNIL([waiting,active]).map(\.call),[waiting.call],"An active operator is preferred even when a waiting caller is louder")

        let transmitting=station("K1CCC",.needQso,0.5)
        let otherWaiting=station("K1DDD",.needPrevEnd,0.99)
        XCTAssertEqual(game.fixtureDropInstantNIL([transmitting,otherWaiting],transmittingCalls:[transmitting.call]).map(\.call),[otherWaiting.call],"A transmitting station is removed before a louder waiting caller")
        let excluded=station("K1EEE",.done,1.0)
        XCTAssertEqual(game.fixtureDropInstantNIL([excluded]).map(\.call),[excluded.call],"Done/failed stations are not fallback candidates")

        var weakRF=station("K1FFF",.needNr,0.99),strongRF=station("K1GGG",.needCall,0.10)
        weakRF.rfAmplitude=10_000;strongRF.rfAmplitude=44_000
        let weakPatience=weakRF.patience
        _ = game.drainEvents()
        game.fixtureScheduleReceive(RadioEvent(.receive,"K1FFF K1GGG",calls:[weakRF.call,strongRF.call],voices:[RadioVoice(station:weakRF,message:"K1FFF"),RadioVoice(station:strongRF,message:"K1GGG")]),due:1)
        XCTAssertEqual(game.fixtureDropInstantNIL([weakRF,strongRF]).map(\.call),[weakRF.call],
                       "Instant NIL selects the strongest received RF signal even when its UI volume is lower")
        let remaining=game.pileup.first(where:{$0.call==weakRF.call})
        XCTAssertEqual(remaining?.patience,weakPatience,"Other caller FSMs are untouched by instant NIL")
        let cancel=game.drainEvents().first(where:{$0.kind == .cancelReceive})
        XCTAssertEqual(cancel?.stationCalls,[strongRF.call],"Cancellation identifies only the NIL-selected caller")
        let queued=try! XCTUnwrap(game.fixtureScheduledReceives().first)
        XCTAssertEqual(queued.stationCalls,[weakRF.call],"Queued RX keeps survivor voices and removes the selected caller")
    }
    func testRegularOperationMayRepeatPreviouslyWorkedCallAndScoresItAsDupe() {
        var s=ContestSettings();s.mode = .single;s.seed=9;s.customCalls=["K1AAA"]
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()

        func finishContact(at firstTime:Double,call:String,exchange:String) {
            game.command(.call,call:call)
            game.tick(firstTime);_ = game.drainEvents()
            if game.target?.opState == .needNr {
                game.command(.exchange)
                game.tick(firstTime+20);_ = game.drainEvents()
            }
            XCTAssertNotNil(game.logQSO(call:call,exchange:exchange))
            game.tick(firstTime+40)
        }

        let first=game.pileup[0]
        finishContact(at:20,call:first.call,exchange:first.exchange)
        XCTAssertEqual(game.log.first?.correct,true)
        XCTAssertEqual(game.pileup.first?.call,first.call,"Regular operation may draw a previously worked call again")

        let second=game.pileup[0]
        finishContact(at:80,call:second.call,exchange:second.exchange)
        XCTAssertEqual(game.log.first?.call,first.call)
        XCTAssertTrue(game.log.first?.dupe == true)
        XCTAssertFalse(game.log.first?.correct ?? true)
        XCTAssertEqual(game.verified,1,"A duplicate contact must not increase verified QSOs")
    }
    func testTUCommandLogsCompletedQSOAndTransmitsTU() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game)
        let call=game.pileup[0].call
        game.command(.call,call:call)
        game.tick(20)
        if game.target?.opState == .needNr {
            game.command(.exchange)
            game.tick(40)
        }
        XCTAssertEqual(game.target?.opState,.needEnd,"The exchange must be copied before TU can log")
        game.command(.log,call:call,exchange:game.target!.exchange)
        let transmitted=game.drainEvents().filter{$0.kind == .transmit}.map(\.text)
        XCTAssertEqual(game.log.count,1,"TU / LOG must record a completed contact")
        XCTAssertEqual(game.log.first?.note,"Pending TU confirmation")
        XCTAssertTrue(transmitted.last?.hasPrefix("TU") == true,"TU / LOG must key TU after recording the contact")
        game.tick(60)
        XCTAssertNil(game.targetCall,"The completed operator must leave the active target")
    }
    func testManualTUTransmitsWithoutSavingWhenNoStationIsSelected() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        game.command(.tu)
        XCTAssertEqual(game.log.count,0,"MRCE's F3 TU macro does not itself call SaveQso")
        XCTAssertEqual(game.drainEvents().filter{$0.kind == .transmit}.map(\.text),["TU"])
        game.tick(10)
        XCTAssertNil(game.targetCall,"TU without a selected caller does not start a QSO")
        XCTAssertEqual(game.log.count,0)
    }
    func testManualTUClosesReadyDialogueWithoutSaving() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call
        game.command(.call,call:call)
        game.tick(20);_ = game.drainEvents()
        XCTAssertEqual(game.target?.opState,.needEnd)
        game.command(.tu)
        game.tick(40)
        XCTAssertEqual(game.target?.opState,.done)
        XCTAssertEqual(game.targetCall,call,"MRCE retains a completed station until SaveQso removes it")
        XCTAssertEqual(game.log.count,0)
    }
    func testSaveOnlySavesAnAcceptedCallerWithoutStartingAnotherTransmission() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call,exchange=game.pileup[0].exchange
        game.command(.call,call:call)
        game.tick(20);_ = game.drainEvents()
        if game.target?.opState == .needNr {
            game.command(.exchange)
            game.tick(40);_ = game.drainEvents()
        }
        XCTAssertEqual(game.target?.opState,.needEnd)
        game.command(.tu)
        game.tick(60);_ = game.drainEvents()
        XCTAssertEqual(game.target?.opState,.done)

        game.command(.saveOnly,call:call,exchange:exchange)

        XCTAssertEqual(game.log.count,1)
        XCTAssertTrue(game.log[0].correct)
        XCTAssertTrue(game.drainEvents().allSatisfy{$0.kind != .transmit},"Save Only invokes SaveQso without keying TU")
    }
    func testSaveOnlyCannotCompleteACallerBeforeTU() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call,exchange=game.pileup[0].exchange
        game.command(.call,call:call)
        game.tick(20);_ = game.drainEvents()
        if game.target?.opState == .needNr {
            game.command(.exchange)
            game.tick(40);_ = game.drainEvents()
        }
        XCTAssertEqual(game.target?.opState,.needEnd)

        game.command(.saveOnly,call:call,exchange:exchange)

        XCTAssertEqual(game.target?.opState,.needEnd,"Save Only must not synthesize TU acceptance")
        XCTAssertEqual(game.targetCall,call,"The caller remains available to respond to manual TU")
        XCTAssertEqual(game.log.count,1)
        XCTAssertFalse(game.log[0].correct)
        XCTAssertFalse(game.log[0].note == "Pending TU confirmation")
        XCTAssertTrue(game.drainEvents().allSatisfy{$0.kind != .transmit})

        let rowID=game.log[0].id
        game.command(.stop)
        XCTAssertEqual(game.log.count,1,"Escape before SaveQso must not create or finalize a row")
        XCTAssertEqual(game.log[0].id,rowID)
        XCTAssertEqual(game.log[0].status,.completed,"Escape preserves MRCE's visible preconfirmation NIL row")
        XCTAssertEqual(game.log[0].diagnosis.code,"NIL")
        game.command(.tu)
        game.tick(60)
        XCTAssertNil(game.targetCall,"A subsequent manual TU reconciles and removes the saved caller")
        XCTAssertEqual(game.verified,1,"Manual TU confirms the previously saved row without creating a duplicate")
        XCTAssertEqual(game.log.count,1,"Reconciliation updates the same log row")
        XCTAssertEqual(game.log[0].id,rowID)
    }
    func testSaveOnlyWithBlankExchangeCreatesAnUnverifiedExchangeErrorRowWithoutTX() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call
        game.command(.call,call:call)
        game.tick(20);_ = game.drainEvents()
        XCTAssertEqual(game.targetCall,call)

        game.command(.saveOnly,call:call,exchange:"")

        XCTAssertEqual(game.log.count,1,"Direct Save records the incomplete entry for later diagnosis")
        XCTAssertFalse(game.log[0].correct)
        XCTAssertTrue(game.log[0].exchangeErrors.isEmpty == false)
        XCTAssertEqual(game.log[0].received,"","Save preserves a blank copied exchange in the raw log")
        XCTAssertFalse(game.log[0].note == "Pending TU confirmation")
        XCTAssertTrue(game.drainEvents().allSatisfy{$0.kind != .transmit},"Save Only does not key TU")
    }
    func testB4IsAppliedAfterItsTransmissionFinishes() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call
        game.command(.b4)
        XCTAssertEqual(game.pileup.first(where:{$0.call==call})?.opState,.needQso,
                       "The caller cannot react to B4 before the operator finishes sending it")
        game.tick(ContestRules.cwSeconds("QSO B4",wpm:s.wpm)+0.2)
        XCTAssertEqual(game.pileup.first(where:{$0.call==call})?.opState,.needQso)
        XCTAssertGreaterThan(game.pileup.first(where:{$0.call==call})?.patience ?? 0,1,
                             "B4 restarts the caller's QSO state after the transmission")
    }
    func testCorrectedCallEnterIsProvisionalUntilTUIsAccepted() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call,exchange=game.pileup[0].exchange
        let final=call.last!
        let typo=String(call.dropLast())+(final == "X" ? "Y" : "X")
        game.command(.esm,call:typo)
        XCTAssertEqual(game.log.count,0,"The initial wrong-call Enter only starts the contact")
        game.tick(20);_ = game.drainEvents()
        game.tick(40);_ = game.drainEvents()
        XCTAssertEqual(game.targetCall,call,"The station's correction should identify the caller")

        // Enter the corrected call and copied exchange. The macro keys the
        // correction, then saves a provisional row while TU is on the air.
        game.command(.esm,call:call,exchange:exchange)
        XCTAssertEqual(game.log.count,1)
        let provisional=game.log[0]
        XCTAssertFalse(provisional.correct)
        XCTAssertEqual(provisional.note,"Pending TU confirmation")
        XCTAssertEqual(game.verified,0)
        XCTAssertTrue(game.drainEvents().contains(where:{$0.kind == .transmit && $0.text.hasPrefix("TU")}))

        game.tick(60)
        XCTAssertEqual(game.log.count,1,"Reconciliation updates the provisional contact")
        XCTAssertEqual(game.log[0].id,provisional.id,"Reconciliation preserves the log row identity")
        XCTAssertEqual(game.log[0].copiedCall,call)
        XCTAssertEqual(game.log[0].received,exchange)
        XCTAssertTrue(game.log[0].correct)
        XCTAssertEqual(game.log[0].diagnosis.code,"OK")
        XCTAssertEqual(game.verified,1)
    }
    func testIncompleteCorrectedCallerTUFallsBackAfterTXAndCannotVerifyPendingRow() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call,exchange=game.pileup[0].exchange
        game.fixtureSetOperatorState(call,.needCallNr)

        let provisional=try! XCTUnwrap(game.logQSO(call:call,exchange:exchange))
        XCTAssertEqual(provisional.status,.pendingTUConfirmation)
        XCTAssertEqual(game.target?.opState,.needCallNr,"TU must wait for its scheduled transmission to finish")
        XCTAssertEqual(game.verified,0)

        game.tick(0.1)
        XCTAssertEqual(game.target?.opState,.needCallNr,"The caller cannot react to queued TU")
        XCTAssertEqual(game.log[0].status,.pendingTUConfirmation)
        game.tick(10)
        XCTAssertEqual(game.log.count,1,"The captured row is reconciled once after TX completion")
        XCTAssertEqual(game.log[0].id,provisional.id)
        XCTAssertEqual(game.log[0].status,.pendingTUConfirmation,"The caller is still in the QSO, so the row stays provisional")
        XCTAssertFalse(game.log[0].correct,"An incomplete corrected exchange cannot verify the QSO")
        XCTAssertEqual(game.verified,0)
        XCTAssertEqual(game.targetCall,call,"The caller remains active after rejecting TU")
        XCTAssertEqual(game.target?.opState,.needQso,"The rejected corrected TU resets the caller")
        XCTAssertFalse(game.target?.correctedCallAndExchSent ?? true)
    }
    func testPendingQSOReconcilesAgainstItsOriginalCallerAfterTargetChanges() {
        var s=ContestSettings();s.mode = .pileup;s.seed=72;s.activity=9
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        game.command(.cq)
        game.tick(20);_ = game.drainEvents()
        XCTAssertGreaterThanOrEqual(game.pileup.count,2,"The fixture needs two independent callers")
        let first=game.pileup[0],second=game.pileup[1]
        game.command(.call,call:first.call)
        game.tick(40);_ = game.drainEvents()
        if game.target?.opState == .needNr {
            game.command(.exchange)
            game.tick(60);_ = game.drainEvents()
        }
        XCTAssertEqual(game.targetCall,first.call)
        XCTAssertNotNil(game.logQSO(call:first.call,exchange:first.exchange))
        let pending=try! XCTUnwrap(game.log.first)
        XCTAssertEqual(pending.note,"Pending TU confirmation")
        XCTAssertEqual(pending.status,.pendingTUConfirmation)

        game.fixtureSetTargetCall(second.call)
        game.tick(80)

        XCTAssertEqual(game.log.count,1)
        XCTAssertEqual(game.log.first?.id,pending.id)
        XCTAssertTrue(game.log.first?.correct ?? false,"Caller A's TU result must use A's captured station state")
        XCTAssertEqual(game.log.first?.status,.completed)
        XCTAssertEqual(game.targetCall,second.call,"Reconciling caller A must preserve the newly selected caller B")
        XCTAssertTrue(game.pileup.contains(where:{$0.call==second.call}))
    }
    func testTUAcceptanceCoversTheSelectedCallerStates() {
        let simulator=ContestSimulator(settings:ContestSettings())
        for state in [OperatorState.needNr,.needCall,.needEnd,.needCallNr] {
            var station=Station(call:"K1ABC",exchange:"599 123",wpm:25,tone:600,volume:0.8,shift:0)
            station.opState=state
            station.correctedCallAndExchSent=state == .needCallNr
            let after=simulator.fixtureOperatorTransition(station,input:.tu,confidence:100)
            XCTAssertEqual(after.opState,.done,"Selected caller in \(state) should accept TU")
        }

        var waiting=Station(call:"K1ABD",exchange:"599 124",wpm:25,tone:600,volume:0.8,shift:0)
        waiting.opState = .needPrevEnd
        XCTAssertEqual(simulator.fixtureOperatorTransition(waiting,input:.tu,confidence:0).opState,.needQso,
                       "An inactive caller waiting for the previous QSO to end returns to need-QSO")
    }
    func testStoppingBeforeTUKeepsProvisionalRowForLaterReconciliation() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call,exchange=game.pileup[0].exchange
        game.command(.call,call:call)
        game.tick(20);_ = game.drainEvents()
        if game.target?.opState == .needNr {
            game.command(.exchange)
            game.tick(40);_ = game.drainEvents()
        }
        XCTAssertEqual(game.target?.opState,.needEnd)

        game.command(.log,call:call,exchange:exchange)
        let pending=try! XCTUnwrap(game.log.first)
        XCTAssertEqual(pending.note,"Pending TU confirmation")
        game.command(.stop)

        XCTAssertEqual(game.log.count,1)
        XCTAssertFalse(game.log[0].correct)
        XCTAssertEqual(game.log[0].id,pending.id)
        XCTAssertEqual(game.log[0].note,"Pending TU confirmation")
        XCTAssertEqual(game.log[0].diagnosis.code,"PENDING")

        game.command(.tu)
        game.tick(60)
        XCTAssertTrue(game.log[0].correct)
        XCTAssertEqual(game.log[0].id,pending.id)
        XCTAssertEqual(game.verified,1)
    }
    func testCombinedTuAndSaveValidatesThenLogsSelectedCaller() {
        var s=ContestSettings();s.mode = .single;s.seed=1234
        let game=ContestSimulator(settings:s);startAndAdvanceSingle(game);_ = game.drainEvents()
        let call=game.pileup[0].call,exchange=game.pileup[0].exchange
        game.command(.call,call:call)
        game.tick(20);_ = game.drainEvents()
        XCTAssertEqual(game.targetCall,call,"The station must be selected before logging")
        if game.target?.opState == .needNr {
            game.command(.exchange)
            game.tick(40);_ = game.drainEvents()
        }
        game.command(.log,call:call,exchange:exchange)
        XCTAssertEqual(game.log.count,1,"Complete fields create a provisional row while TU is on the air")
        XCTAssertEqual(game.log.first?.note,"Pending TU confirmation")
        XCTAssertEqual(game.drainEvents().filter{$0.kind == .transmit}.first?.text,"TU",
                       "MRCE station ID is sent only in pileup/WPX mode")
        game.tick(60)
        XCTAssertEqual(game.log.count,1)
        XCTAssertEqual(game.log.first?.diagnosis.code,"OK")
        XCTAssertNil(game.targetCall,"A completed logged caller leaves the active target")
    }
    func testReceiveAndInterferenceEventsHideTranscriptAndConditionText() {
        XCTAssertEqual(RadioActivityText.visible(RadioEvent(.notice,"Fill in CALL and RECEIVED.")),"Fill in CALL and RECEIVED.")
        XCTAssertEqual(RadioActivityText.visible(RadioEvent(.receive,"K1ABC 599 001")),"")
        XCTAssertEqual(RadioActivityText.visible(RadioEvent(.interference,"Band interference")),"")
        XCTAssertEqual(RadioActivityText.visible(RadioEvent(.cancelReceive,"",calls:["K1ABC"],reason:"NIL")),"")
        XCTAssertEqual(RadioActivityText.visible(RadioEvent(.transmit,"CQ TEST")),"CQ TEST")
    }
    func testNoticeProjectionHidesUnheardCallerStateAndKeepsDirectInputFeedback() {
        let hiddenNotices=[
            "No caller. Send CQ.",
            "No callers. Send CQ first.",
            "No answer. Try CQ again.",
            "No station on frequency. Send CQ.",
            "Select a caller before logging.",
            "Caller needs a call or exchange correction before TU.",
            "Receive the caller's exchange before TU.",
            "Caller repeated the requested information.",
            "Caller repeated at a slower speed.",
            "Several callers match the partial. Copy their complete callsign.",
            "K1ABC responded. Copy the exchange.",
            "History hint for K1ABC: 86 CT",
            "K1ABC acknowledged TU.",
            "2 new station(s) calling.",
            "NIL: skipped K1ABC.",
            "K1ABC: Exchange error: NR. Expected 599 001"
        ]
        for notice in hiddenNotices {
            XCTAssertEqual(RadioActivityText.visible(RadioEvent(.notice,notice)),"",notice)
        }
        for notice in ["Entry cleared.","TX cancelled. Call or repeat to continue.",
                       "Type a callsign first.","Fill in CALL and RECEIVED."] {
            XCTAssertEqual(RadioActivityText.visible(RadioEvent(.notice,notice)),notice)
        }
        let invalidExchange=RadioEvent(.notice,"raw internal text",noticeCode:.exchangeInvalid)
        XCTAssertEqual(RadioActivityText.visible(invalidExchange),RadioNoticeCode.exchangeInvalid.safeDisplayText)
    }
    func testLogDiagnosisGivesExactBustedCallAndExchangeValues() {
        func record(copy:String="K1ABC",actual:String="K1ABC",errors:[String]=[],dupe:Bool=false) -> QSOEntry {
            QSOEntry(id:1,at:0,call:actual,copiedCall:copy,sent:"599 001",received:"599 999",
                     expected:"599 003",correct:copy==actual && errors.isEmpty && !dupe,
                     points:0,multipliers:[],note:"",dupe:dupe,callError:copy != actual,exchangeErrors:errors,wpm:25)
        }
        XCTAssertEqual(record(copy:"K1ABX").diagnosis.code,"NIL")
        XCTAssertTrue(record(copy:"K1ABX").diagnosis.explanation.contains("K1ABC"))
        XCTAssertEqual(record(dupe:true).diagnosis.code,"DUP")
        XCTAssertEqual(record(errors:["Serial"]).diagnosis.code,"NR")
        XCTAssertEqual(record(errors:["RST"]).diagnosis.code,"RST")
        XCTAssertEqual(record(errors:["Section"]).diagnosis.code,"EXCH")
        XCTAssertTrue(record(errors:["Serial"]).diagnosis.explanation.contains("599 003"))
        XCTAssertEqual(record().diagnosis.code,"OK")
    }
    func testMRCEStyleRSTAndNRAreDistinct() {
        var s=ContestSettings();s.contest = .wpx
        let rst=ContestRules.checkExchange(s,received:"579 003",expected:"599 003")
        XCTAssertEqual(rst.errors,["RST"])
        let serial=ContestRules.checkExchange(s,received:"599 004",expected:"599 003")
        XCTAssertEqual(serial.errors,["Exchange"])
        XCTAssertTrue(ContestRules.checkExchange(s,received:"003",expected:"599 003").valid)
        XCTAssertEqual(ContestRules.checkExchange(s,received:"5NN 003",expected:"599 003").errors,["RST"],
                       "the report is logged in digits, as in MRCE")
    }
}
