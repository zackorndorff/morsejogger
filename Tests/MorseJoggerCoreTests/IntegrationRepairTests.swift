//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class IntegrationRepairTests:XCTestCase {
    func testCallerRandomStreamsAreRepeatableAndIsolated() {
        var options=ContestSettings();options.seed=0
        options.mode = .single
        let firstSession=ContestSimulator(settings:options)
        let secondSession=ContestSimulator(settings:options)
        firstSession.start();secondSession.start()
        let startup=6.0 * 512.0 / 11025.0
        firstSession.tick(startup);secondSession.tick(startup)
        XCTAssertEqual(firstSession.pileup.first,secondSession.pileup.first,
                       "Seed zero must produce the same real initial caller in the portable core")

        options.mode = .pileup
        let baseline=ContestSimulator(settings:options).fixtureCallerRNGSequence(interactWithOtherStation:false)
        let afterOtherInteraction=ContestSimulator(settings:options).fixtureCallerRNGSequence(interactWithOtherStation:true)
        let repeated=ContestSimulator(settings:options).fixtureCallerRNGSequence(interactWithOtherStation:true)
        XCTAssertEqual(afterOtherInteraction.0,baseline.0)
        XCTAssertEqual(afterOtherInteraction.1,baseline.1)
        XCTAssertEqual(afterOtherInteraction.2,baseline.2)
        XCTAssertEqual(afterOtherInteraction.3,baseline.3,"Interacting with one caller must not consume the session stream")
        XCTAssertEqual(afterOtherInteraction.4,baseline.4,"A fixed session seed must select the same second caller")
        XCTAssertEqual(repeated.0,afterOtherInteraction.0)
        XCTAssertEqual(repeated.1,afterOtherInteraction.1)
        XCTAssertEqual(repeated.2,afterOtherInteraction.2)
        XCTAssertEqual(repeated.3,afterOtherInteraction.3)
        XCTAssertEqual(repeated.4,afterOtherInteraction.4,"Seed zero must remain deterministic through real caller creation")
    }

    func testStationRandomStateIsNotPartOfRadioSnapshotProtocol() throws {
        var station=Station(call:"K1ABC",exchange:"599 001",wpm:25,tone:600,volume:0.8,shift:0)
        station.behaviorRNGState=0x1234_5678
        let encoded=try JSONEncoder().encode(station)
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:encoded) as? [String:Any])
        XCTAssertNil(object["behaviorRNGState"])
    }

    func testHSTPopulationTracksEffectiveActivityAtStartupAndAfterContact() {
        for activity in [1,4,9,20] {
            var options=ContestSettings()
            options.contest = .hst;options.mode = .hstCompetition
            options.activity=activity;options.seed=UInt32(800+activity)
            let game=ContestSimulator(settings:options)
            XCTAssertEqual(game.settings.activity,4,"HST competition presets Activity to four")
            game.start()
            XCTAssertEqual(game.pileup.count,4,"HST startup should fill to four callers")

            let first=game.pileup[0]
            game.command(.call,call:first.call)
            game.tick(20)
            XCTAssertNotNil(game.target)
            XCTAssertNotNil(game.logQSO(call:first.call,exchange:first.exchange))
            game.tick(40)
            XCTAssertEqual(game.pileup.count,4,"Post-contact refill should restore four callers without overfilling")

            let removed=game.pileup.last!.call
            game.fixtureSetOperatorState(removed,.failed)
            game.command(.cq)
            game.tick(60)
            XCTAssertEqual(game.pileup.count,4,"CQ should remove the failed caller and replenish to four without overfilling")
        }
    }

    func testOrdinaryArrivalPreservesInactivityCounterUntilForcedCreation() {
        var options=ContestSettings();options.mode = .pileup;options.seed=805
        let game=ContestSimulator(settings:options)

        game.fixtureArrivalDecision(draw:0)
        XCTAssertEqual(game.fixtureArrivalInactivityCount,1)
        XCTAssertEqual(game.pileup.count,0)

        game.fixtureArrivalDecision(draw:1)
        XCTAssertEqual(game.fixtureArrivalInactivityCount,1,
                       "A sampled ordinary caller does not clear the inactivity counter")
        XCTAssertEqual(game.pileup.count,1)

        game.fixtureArrivalDecision(draw:0)
        XCTAssertEqual(game.fixtureArrivalInactivityCount,2)
        XCTAssertEqual(game.pileup.count,1)

        game.fixtureArrivalDecision(draw:0)
        XCTAssertEqual(game.fixtureArrivalInactivityCount,0,
                       "The forced-creation branch clears the counter")
        XCTAssertEqual(game.pileup.count,2,
                       "Retaining the earlier count makes the forced caller arrive now")
    }

    func testSingleModeUsesConfiguredStartupDelayOnly() {
        var options=ContestSettings()
        options.mode = .single;options.seed=173;options.singleCallStartDelay=1_000
        let simulator=ContestSimulator(settings:options)
        simulator.start()
        XCTAssertTrue(simulator.pileup.isEmpty,"Initial caller should observe the configured startup delay")
        simulator.tick(28.0 * 512.0 / 11025.0)
        let first=simulator.pileup[0]
        var time=28.0 * 512.0 / 11025.0

        simulator.command(.call,call:first.call)
        time += ContestRules.cwSeconds("\(first.call) \(ContestRules.sentExchange(options,serial:1))",wpm:options.wpm)+0.2
        simulator.tick(time)
        XCTAssertNotNil(simulator.target,"Call transmission should select the single caller: \(simulator.drainEvents().map(\.text))")
        time += 5
        simulator.tick(time)
        simulator.command(.exchange)
        let sentExchange=ContestRules.sentExchange(options,serial:1)
        time += ContestRules.cwSeconds(sentExchange,wpm:options.wpm)+0.2
        simulator.tick(time)
        XCTAssertNotNil(simulator.target)
        // The station's R/exchange response is still on air after the
        // operator finishes keying. MRCE only accepts TU in the appropriate
        // caller state, so drain that reply before ending the contact.
        time += 5
        simulator.tick(time)
        XCTAssertNotNil(simulator.logQSO(call:first.call,exchange:first.exchange))
        time += ContestRules.cwSeconds("TU",wpm:options.wpm)+0.2
        simulator.tick(time)
        XCTAssertEqual(simulator.pileup.count,1,"After startup, single mode replaces a completed caller without restarting its delay")
    }

    func testFast5NNKeepsTXTextAndAttachesOwnReportTiming() {
        var options=ContestSettings()
        options.mode = .single;options.contest = .cqww;options.seed=174
        options.fast5nn=true;options.fast5nnOccurrenceRate=1
        let simulator=ContestSimulator(settings:options)
        simulator.start()
        simulator.tick(6.0 * 512.0 / 11025.0)
        let call=simulator.pileup[0].call
        simulator.command(.call,call:call)
        let sent=simulator.drainEvents().filter{$0.kind == .transmit}
        XCTAssertEqual(sent.map(\.text),[call,"5NN 3"],"Fast 5NN changes report timing, not copied text")
        let tx=sent.last
        XCTAssertEqual(tx?.fastReportStart,0)
        XCTAssertTrue((1.2...1.5).contains(tx?.fastReportRate ?? 0))

        simulator.command(.exchange)
        let repeatedTX=simulator.drainEvents().first(where:{$0.kind == .transmit})
        XCTAssertEqual(repeatedTX?.text,"5NN 3")
        XCTAssertEqual(repeatedTX?.fastReportRate,tx?.fastReportRate,
                       "The home station keeps its R1-derived rate across sends")
    }

    func testFastReportTimelineAcceleratesBothRepeatedExchangeExpansions() {
        let text="K1ABC 5NN 003 5NN 003"
        let plain=MorseTimeline.duration(text,wpm:25)
        let firstOnly=MorseTimeline.duration(text,wpm:25,fastReportStart:6,fastReportRate:1.5)
        let both=MorseTimeline.duration(text,wpm:25,fastReportRate:1.5,fastReportStarts:[6,14])
        XCTAssertLessThan(firstOnly,plain)
        XCTAssertLessThan(both,firstOnly,
                          "Each <#> expansion accelerates its report while preserving the transmitted text")

        var options=ContestSettings();options.mode = .single;options.contest = .wpx;options.seed=175
        options.fast5nn=true;options.fast5nnOccurrenceRate=100
        var wpxProfile=options.exchangeProfile(for:.wpx);wpxProfile.firstSerial=3;options.setExchangeProfile(wpxProfile,for:.wpx)
        let simulator=ContestSimulator(settings:options)
        simulator.start();simulator.tick(6.0 * 512.0 / 11025.0)
        let call=simulator.pileup[0].call
        simulator.command(.call,call:call)
        let sent=simulator.drainEvents().filter{$0.kind == .transmit}
        XCTAssertEqual(sent.map(\.text),[call,"5NNTT3"])
        XCTAssertEqual(sent.last?.effectiveFastReportStarts,[0])
    }

    func testRepeatRequestsStayDistinctAndProduceRequestedStationAudio() {
        let requests:[(Command,String)]=[(.numberAgain,"NR?"),(.repeatMessage,"?")]
        for (request,tx) in requests {
            var options=ContestSettings()
            options.mode = .single;options.seed=172;options.duration=30
            let simulator=ContestSimulator(settings:options)
            simulator.start();simulator.tick(6.0 * 512.0 / 11025.0)
            let station=simulator.pileup[0]
            _ = simulator.drainEvents()
            simulator.command(request)
            let sent=simulator.drainEvents().filter{$0.kind == .transmit}
            XCTAssertEqual(sent.map(\.text),[tx],"Wrong TX for \(request)")
            simulator.tick(4)
            simulator.tick(7)
            let heard=simulator.drainEvents().filter{$0.kind == .receive && $0.reason == "repeat"}
            XCTAssertFalse(heard.isEmpty,"No response to \(request)")
            XCTAssertFalse(heard.flatMap(\.voices).isEmpty)
            if request == .numberAgain {
                XCTAssertTrue(heard.flatMap(\.voices).contains(where:{
                    [station.call,station.exchange,"NR?","AGN"].contains($0.message)
                }),"MRCE NR? repeats whichever information its current operator state calls for")
            }
        }
    }
    func testNumberQuestionDialogueStartsWithNRAndSeparatesF12FromExchange() {
        func dialogue(seed:UInt32)->(initial:[String],answers:[[String]],exchange:[String],state:OperatorState?) {
            var options=ContestSettings()
            options.mode = .single;options.seed=seed
            let simulator=ContestSimulator(settings:options)
            simulator.start();simulator.tick(6.0 * 512.0 / 11025.0);_ = simulator.drainEvents()

            let station=simulator.pileup[0]
            simulator.command(.hiscall,call:station.call)
            simulator.tick(20)
            var now=20.7
            simulator.tick(now)
            let initial=simulator.drainEvents().filter{$0.kind == .receive && $0.reason == "dialogue"}
                .flatMap(\.voices).map(\.message)

            // F12 asks for the current reply. Separate TX completion from RX
            // delivery so no long idle timeout changes the caller's patience.
            var answers=[[String]]()
            for _ in 0..<3 {
                simulator.command(.numberAgain)
                now += 3
                simulator.tick(now)
                now += 0.65
                simulator.tick(now)
                let reply=simulator.drainEvents().filter{$0.kind == .receive && $0.reason == "repeat"}
                answers.append(reply.flatMap(\.voices).map(\.message))
            }

            // A caller that is still on the air when the operator keys up
            // misses the message (MRCE doubling), so wait for a gap first.
            while simulator.fixtureCallerTransmitRanges(station.call).contains(where:{$0.start <= now && now < $0.end}) {
                now += 0.08
                simulator.tick(now)
            }
            _ = simulator.drainEvents()
            simulator.command(.exchange)
            now += 6
            simulator.tick(now)
            now += 2
            simulator.tick(now)
            now += 5
            simulator.tick(now)
            let exchange=simulator.drainEvents().filter{$0.kind == .receive && $0.reason == "exchange"}
                .flatMap(\.voices).map(\.message)
            return (initial,answers,exchange,simulator.target?.opState)
        }

        let trace=dialogue(seed:1234)
        XCTAssertEqual(trace.initial,["NR?"],"The first reply after a correctly copied call requests the number")
        XCTAssertEqual(trace.answers.map(\.count),[1,1,1],"Each F12 request should produce one caller response")
        XCTAssertTrue(trace.answers.flatMap{$0}.allSatisfy{["NR?","AGN"].contains($0)})
        XCTAssertTrue(trace.answers[2].allSatisfy{["NR?","AGN"].contains($0)})
        // Callers key 5NN and cut numbers (MRCE NrAsText), so compare the decoded digits.
        XCTAssertEqual(trace.exchange.map(CallerExchangeTextTests.decodeCuts),["R 599 001"],"A Start-range caller at session time zero receives serial 001; sending the exchange advances the dialogue and receives the report, unlike F12")
        XCTAssertEqual(trace.state,.needEnd)

        // Exercise both outcomes of the random 20% branch with reproducible
        // seeds. MRCE uses a different RNG stream, so this checks branch
        // behavior without claiming seed-for-seed source parity. The next
        // guaranteed cadence slot is beyond the three F12 replies observable
        // before this caller's patience is exhausted.
        let randomBranchOutcomes=(100...115).map { dialogue(seed:UInt32($0)).answers[1].first ?? "" }
        XCTAssertTrue(randomBranchOutcomes.contains("NR?"))
        XCTAssertTrue(randomBranchOutcomes.contains("AGN"))
    }
    func testReceiveEventsCaptureImmutableIndependentOperatorMessages() {
        var settings=ContestSettings()
        settings.mode = .hstCompetition;settings.seed=500
        let simulation=ContestSimulator(settings:settings)
        simulation.start()
        let expected=Dictionary(uniqueKeysWithValues:simulation.pileup.map{($0.call,$0.sentCall)})
        simulation.tick(1)
        // Every caller keys up on its own send delay, so each is its own event.
        let receives=simulation.drainEvents().filter{$0.kind == .receive && $0.reason == "pileup"}
        XCTAssertEqual(receives.count,simulation.settings.activity)
        XCTAssertTrue(receives.allSatisfy{$0.voices.count == 1})
        for voice in receives.flatMap(\.voices) {
            XCTAssertEqual(voice.message,expected[voice.call],"Initial pileup needs the transmitted call")
        }
        // Dialogue events instead carry the last reply of each operator, even
        // if the aggregate UI text has the same separator as a pileup.
        var a=Station(call:"K1ABC",exchange:"599 001",wpm:25,tone:520,volume:0.8,shift:0)
        var b=Station(call:"K1ABD",exchange:"599 002",wpm:30,tone:770,volume:0.4,shift:0)
        a.lastReply="NR?";b.lastReply="R 599 002"
        let overlapping=RadioEvent(.receive,"NR? · R 599 002",calls:[a.call,b.call],reason:"dialogue",voices:[RadioVoice(station:a,message:a.lastReply),RadioVoice(station:b,message:b.lastReply)])
        XCTAssertEqual(overlapping.voices.map(\.message),["NR?","R 599 002"])
        XCTAssertEqual(overlapping.voices.map(\.tone),[520,770])
    }
    func testPrivacyHidesReceivedTranscriptAndSensitiveNotices() {
        let voice=RadioEvent(.receive,"W1AW 599 001",calls:["W1AW"],reason:"dialogue")
        let hint=RadioEvent(.notice,"History hint for K1ABC: 86 CT")
        XCTAssertFalse(RadioActivityText.visible(voice).contains("W1AW"))
        XCTAssertFalse(RadioActivityText.visible(hint).contains("K1ABC"))
        XCTAssertFalse(RadioActivityText.visible(hint).contains("86 CT"))
        XCTAssertEqual(RadioActivityText.visible(RadioEvent(.transmit,"CQ TEST")),"CQ TEST")
    }
    func testRITMovesReceiverNotStationTone() {
        let voice=RadioVoice(station:Station(call:"K1ABC",exchange:"599 001",wpm:25,tone:600,volume:1,shift:0),message:"K1ABC")
        XCTAssertEqual(RadioTuning.signalFrequency(voice),600)
        XCTAssertEqual(RadioTuning.receiverCenter(pitch:600,rit:200),800)
        XCTAssertEqual(RadioTuning.signalFrequency(voice),600,"Tuning must not pitch-shift the station")
    }
    func testRITStepsAndLimitsMatchRadioControls() {
        // MRCE: 50 Hz, the same in every mode.
        XCTAssertEqual(RadioTuning.ritStep,50)
        XCTAssertEqual(RadioTuning.adjustedRIT(0,direction:1),50)
        XCTAssertEqual(RadioTuning.adjustedRIT(0,direction:-1),-50)
        XCTAssertEqual(RadioTuning.adjustedRIT(490,direction:1),500)
        XCTAssertEqual(RadioTuning.adjustedRIT(-490,direction:-1),-500)
        XCTAssertEqual(RadioTuning.adjustedRIT(500,direction:1),500)
        XCTAssertEqual(RadioTuning.receiverCenter(pitch:600,rit:50),650)
    }
    func testCompetitionEffectiveEffectsAreNotUserEditableInCore() {
        var options=ContestSettings()
        options.mode = .wpxCompetition
        let game=ContestSimulator(settings:options)
        XCTAssertTrue(game.settings.effects.qrn && game.settings.effects.qrm)
        var disabled=ContestSettings();disabled.effects = .all(false)
        game.updateRadio(disabled)
        XCTAssertTrue(game.settings.effects.qrn && game.settings.effects.qrm)
        options.mode = .hstCompetition
        options.effects = .all(true)
        let hst=ContestSimulator(settings:options)
        XCTAssertFalse(hst.settings.effects.qrn || hst.settings.effects.qrm)
        hst.updateRadio(options)
        XCTAssertFalse(hst.settings.effects.qrn || hst.settings.effects.qrm)
    }
}
