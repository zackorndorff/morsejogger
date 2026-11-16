//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import XCTest
@testable import MorseJoggerCore

final class QRMSourceStatisticsTests: XCTestCase {
    func testGeometricArrivalRateMatchesMRCEReferenceBlocks() {
        var rng=ContestRNG(seed:0xA17A_4010)
        let trials=100_000
        var total=0.0,oneBlock=0
        for _ in 0..<trials {
            let interval=QRMSourceModel.interarrival(using:&rng)
            total += interval
            if interval <= 512/11_025 {oneBlock += 1}
        }
        let mean=total/Double(trials)
        XCTAssertEqual(mean,512/(11_025*0.0002),accuracy:3)
        XCTAssertGreaterThanOrEqual(oneBlock,8)
        XCTAssertLessThanOrEqual(oneBlock,32)
    }

    func testInitialMessageWeightsAndPatienceRange() {
        var messageRNG=ContestRNG(seed:0xB155_49A1)
        var counts=[QRMMessageType:Int]()
        let trials=100_000
        for _ in 0..<trials {counts[QRMSourceModel.initialMessageType(using:&messageRNG),default:0] += 1}
        for (type,probability) in [(QRMMessageType.qrl,1.0/7),(QRMMessageType.repeatedQRL,2.0/7),(.cq,3.0/7),(.qsy,1.0/7)] {
            XCTAssertEqual(Double(counts[type,default:0]),Double(trials)*probability,accuracy:650)
        }

        var patienceRNG=ContestRNG(seed:0x715A_9E1)
        var patienceCounts=[Int](repeating:0,count:6)
        for _ in 0..<50_000 {patienceCounts[QRMSourceModel.patience(using:&patienceRNG)] += 1}
        for patience in 1...5 {
            XCTAssertGreaterThanOrEqual(patienceCounts[patience],9_500)
            XCTAssertLessThanOrEqual(patienceCounts[patience],10_500)
        }
    }

    func testBoundedRetryDelayAndQRMStationParameters() {
        var retryRNG=ContestRNG(seed:0x4E71_7A1)
        let retryTrials=20_000
        var retryTotal=0.0
        for _ in 0..<retryTrials {
            let delay=QRMSourceModel.retryDelay(using:&retryRNG)
            XCTAssertGreaterThanOrEqual(delay,2)
            XCTAssertLessThanOrEqual(delay,6)
            retryTotal += delay
        }
        XCTAssertEqual(retryTotal/Double(retryTrials),4,accuracy:0.02)

        var stationRNG=ContestRNG(seed:0x5017_0A11)
        for _ in 0..<20_000 {
            let draw=QRMSourceModel.stationDraw(using:&stationRNG)
            XCTAssertGreaterThanOrEqual(draw.amplitude,5_000)
            XCTAssertLessThanOrEqual(draw.amplitude,30_000)
            XCTAssertGreaterThanOrEqual(draw.speed,30)
            XCTAssertLessThanOrEqual(draw.speed,49)
            XCTAssertLessThanOrEqual(abs(draw.frequencyOffset),300)
        }
    }

    func testSeededQRMEventsTerminateWithoutReceiveOrQSOAcknowledgement() {
        func simulate() -> ([String],Int,Bool) {
            var settings=ContestSettings()
            settings.seed=0x5A17_0A11
            settings.duration=60
            settings.effects.qrm=true
            let game=ContestSimulator(settings:settings)
            game.start()
            game.tick(60*60)
            let events=game.drainEvents()
            let interference=events.filter{$0.kind == .interference}
            let stable=interference.map{"\($0.at)|\($0.text)|\($0.stationCalls.joined(separator:","))"}
            let hasFinished=events.contains{$0.kind == .finished}
            XCTAssertFalse(events.contains{$0.kind == .receive || $0.kind == .transmit})
            XCTAssertEqual(game.contacts,0)
            XCTAssertFalse(game.running)
            XCTAssertTrue(hasFinished)
            return (stable,game.contacts,hasFinished)
        }
        let first=simulate(),second=simulate()
        XCTAssertEqual(first.0,second.0)
        XCTAssertGreaterThan(first.0.count,0)
        XCTAssertLessThan(first.0.count,200)
        XCTAssertEqual(first.1,0)
        XCTAssertTrue(first.2)
    }

    func testSSTPileupQRMDoesNotCreateRealCallersBeforeCQ() {
        var settings=ContestSettings()
        settings.contest = .sst
        settings.mode = .pileup
        settings.customCalls=["DL1ABC"]
        settings.duration=30
        settings.effects.qrm=true
        settings.seed=0x5A17_0A11
        let game=ContestSimulator(settings:settings)
        game.start()
        game.tick(1_700)

        let events=game.drainEvents()
        XCTAssertTrue(game.pileup.isEmpty,
                      "Pileup mode must not add contest callers until the operator's CQ completes")
        XCTAssertTrue(events.contains(where:{$0.kind == .interference && $0.reason == "qrm"}),
                      "Enabled SST QRM is a separate interference source and may sound before a caller exists")
        XCTAssertFalse(events.contains(where:{$0.kind == .receive}),
                       "QRM interference must not enter the caller receive channel")
    }
}
