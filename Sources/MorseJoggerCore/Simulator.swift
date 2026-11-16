//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import Foundation
/// Deterministic game-state simulator. Time is passed in by the host in seconds;
/// no audio or application framework enters this module.
public struct ContestRNG: Sendable {
    private var value: UInt32
    // Seed 0 stays deterministic in the portable core; the native shell supplies a random nonzero seed for unseeded sessions.
    public init(seed:UInt32) {value=seed == 0 ? 0x9E3779B9 : seed}
    var state: UInt32 { value }
    public mutating func random() -> Double {
        // Mulberry32 as used by the v0.15 web engine. All arithmetic wraps.
        value = value &+ 0x6D2B79F5
        var t=value
        t=(t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296.0
    }
    /// MRCE RndUShaped: sin(pi * (Random - 0.5)), with Random in [0,1).
    public mutating func uShaped() -> Double { sin(Double.pi * (random() - 0.5)) }
    public mutating func int(_ minimum:Int,_ maximum:Int) -> Int {
        // TS RNG.int consumes one draw even for a degenerate one-element range.
        guard maximum >= minimum else {return minimum}
        return minimum + Int(random() * Double(maximum - minimum + 1))
    }
    public mutating func poisson(_ mean:Double) -> Int {
        let threshold=expApprox(-max(0,mean))
        var product=1.0
        for number in 0...30 {product *= random();if product <= threshold {return number}}
        return 30
    }
    public mutating func gaussian(_ center:Double,_ limit:Double) -> Double {
        guard limit > 0 else {return center}
        for _ in 0..<10000 {
            let a=max(1e-12,random()),b=random()
            let sample=sqrtApprox(-2*logApprox(a))*cosApprox(2*3.141592653589793*b)*limit/2
            if abs(sample) <= limit {return center+sample}
        }
        return center
    }
}

enum QRMMessageType: Int, CaseIterable {
    case qrl, repeatedQRL, cq, qsy
}

/// The operator macros that can affect a caller's dialogue state.
/// Keeping these typed prevents message text (or spelling) from becoming part
/// of the station protocol.
enum OperatorInput: String, Sendable {
    case cq, call, exchange, tu, b4, question, garbage
    case myCall = "mycall"
    case callAndExchange = "call-exchange"
    case numberQuestion = "number-question"
    case nilInput = "nil"
}

/// Station dialogue protocol. Rules are grouped by input below; compound
/// call-and-exchange input runs the call rules first, then exchange rules.
/// The ordered effect trace preserves the simulator helper/RNG call order.
enum OperatorFSM {
    enum Effect: Equatable {
        case reset(OperatorState), setState(OperatorState), morePatience
        case incomplete, decrementPatience
    }
    struct Result {
        var accepted: Bool
        var effects: [Effect]
        static let rejected=Result(accepted:false,effects:[])
    }

    static func mayInterruptTransmit(_ input: OperatorInput, state: OperatorState) -> Bool {
        input == .tu && state == .needCall
    }

    /// MRCE delivers one event per keyer burst, carrying every message kind of
    /// the burst (`Me.Msg`). This runs `TDxOperator.MsgReceived` over that set:
    /// CQ and NIL are exclusive early exits, then his call, B4, the exchange,
    /// TU and `?` apply in order against the state left by the previous step,
    /// and the patience decrement happens once at the end. A lone `.garbage`
    /// is the "missed the message" event. A single kind (or call plus
    /// exchange) forwards to the one-input rules, which fixture tests lock.
    static func transition(
        inputs: Set<OperatorInput>, station: inout Station, typed: String,
        knownConfidence: Int?, settings: ContestSettings,
        selectedCallIsEmpty: Bool, selectedForQSO: Bool,
        matchCall: (String, inout Station) -> Int,
        reset: (inout Station, OperatorState) -> Void,
        decrement: (inout Station) -> Void,
        morePatience: (inout Station) -> Void,
        markIncomplete: (inout Station) -> Void,
        acceptExchange: (inout Station) -> Bool
    ) -> Result {
        func single(_ input: OperatorInput, finalDecrement: Bool = true) -> Result {
            transition(input: input, station: &station, typed: typed, knownConfidence: knownConfidence,
                       settings: settings, selectedCallIsEmpty: selectedCallIsEmpty,
                       selectedForQSO: selectedForQSO, matchCall: matchCall, reset: reset,
                       decrement: decrement, morePatience: morePatience,
                       markIncomplete: markIncomplete, acceptExchange: acceptExchange,
                       finalDecrement: finalDecrement)
        }
        if inputs.count == 1, let only = inputs.first { return single(only) }
        if inputs.isEmpty { return .rejected }
        if inputs.contains(.cq) { return single(.cq) }
        if inputs.contains(.nilInput) { return single(.nilInput) }
        let hasCall = inputs.contains(.call) || inputs.contains(.callAndExchange)
        let hasExchange = inputs.contains(.exchange) || inputs.contains(.callAndExchange)
        let relevant = inputs.subtracting([.myCall, .numberQuestion])
        if relevant.isEmpty { return single(.myCall) }
        if relevant == [.garbage] { return single(.garbage) }
        if relevant == [.call, .exchange] || relevant == [.callAndExchange] { return single(.callAndExchange) }
        var effects: [Effect] = []
        func run(_ input: OperatorInput) {
            effects += single(input, finalDecrement: false).effects
        }
        if hasCall { run(.call) }
        if inputs.contains(.b4) { run(.b4) }
        if hasExchange { run(.exchange) }
        if inputs.contains(.tu) { run(.tu) }
        if inputs.contains(.question) {
            if station.opState == .needPrevEnd && selectedCallIsEmpty {
                reset(&station, .needQso); effects.append(.reset(.needQso))
            }
            if !hasCall, [.needCall, .needCallNr, .needEnd].contains(station.opState) {
                markIncomplete(&station); effects.append(.incomplete)
            }
        }
        if station.opState != .needPrevEnd {
            decrement(&station); effects.append(.decrementPatience)
        }
        return Result(accepted: true, effects: effects)
    }

    static func transition(
        input: OperatorInput, station: inout Station, typed: String,
        knownConfidence: Int?, settings: ContestSettings,
        selectedCallIsEmpty: Bool, selectedForQSO: Bool,
        matchCall: (String, inout Station) -> Int,
        reset: (inout Station, OperatorState) -> Void,
        decrement: (inout Station) -> Void,
        morePatience: (inout Station) -> Void,
        markIncomplete: (inout Station) -> Void,
        acceptExchange: (inout Station) -> Bool,
        finalDecrement: Bool = true
    ) -> Result {
        var effects: [Effect] = []
        func setState(_ value: OperatorState) {
            station.opState = value
            effects.append(.setState(value))
        }
        func resetState(_ value: OperatorState) {
            reset(&station, value)
            effects.append(.reset(value))
        }
        func decrementPatience() {
            decrement(&station)
            effects.append(.decrementPatience)
        }
        func extendPatience() {
            morePatience(&station)
            effects.append(.morePatience)
        }
        func incomplete() {
            markIncomplete(&station)
            effects.append(.incomplete)
        }
        func result() -> Result {
            Result(accepted: true, effects: effects)
        }

        // CQ / NIL / B4 / TU define the main protocol resets and completions.
        if input == .cq {
            switch station.opState {
            case .needPrevEnd: resetState(.needQso)
            case .needNr, .needCall, .needCallNr: setState(.failed)
            case .needEnd: setState(.done)
            default: decrementPatience()
            }
            return result()
        }
        if input == .nilInput {
            switch station.opState {
            case .needPrevEnd: resetState(.needQso)
            case .needQso: decrementPatience()
            case .needNr, .needCall, .needCallNr, .needEnd: setState(.failed)
            case .done, .failed: break
            }
            return result()
        }
        if input == .b4 {
            switch station.opState {
            case .needPrevEnd, .needQso: resetState(.needQso)
            case .needNr, .needEnd: setState(.failed)
            case .needCall, .needCallNr, .done, .failed: break
            }
            if finalDecrement && station.opState != .needPrevEnd { decrementPatience() }
            return result()
        }
        if input == .tu {
            switch station.opState {
            case .needPrevEnd, .needQso: resetState(.needQso)
            case .needEnd: setState(.done)
            case .needNr, .needCall:
                if selectedForQSO { setState(.done) } else { resetState(.needQso) }
            case .needCallNr:
                if selectedForQSO && station.correctedCallAndExchSent { setState(.done) }
                else { resetState(.needQso) }
            case .done, .failed: break
            }
            if finalDecrement && station.opState != .needPrevEnd { decrementPatience() }
            return result()
        }

        // Requests and interrupted keying alter patience/copy quality.
        if input == .question {
            if station.opState == .needPrevEnd && selectedCallIsEmpty { resetState(.needQso) }
            if [.needCall, .needCallNr, .needEnd].contains(station.opState) { incomplete() }
            decrementPatience()
            return result()
        }
        if input == .numberQuestion {
            decrementPatience()
            return result()
        }
        if input == .garbage {
            if !settings.effects.lids {
                switch station.opState {
                case .needQso, .needNr, .needCall, .needCallNr: extendPatience()
                case .needPrevEnd, .needEnd, .done, .failed: break
                }
            }
            if station.opState != .needPrevEnd { decrementPatience() }
            return result()
        }

        // CALL is processed before EXCHANGE for combined input. Reset calls
        // may consume random draws; later rules observe their resulting state.
        if input == .call || input == .callAndExchange {
            let matched = knownConfidence ?? matchCall(typed, &station)
            if matched == 0 {
                switch station.opState {
                case .needQso, .needNr, .needCall, .needCallNr: setState(.needPrevEnd)
                case .needEnd: setState(.done)
                default: break
                }
            } else if matched < 100 {
                switch station.opState {
                case .needQso, .needPrevEnd, .needNr: resetState(.needCallNr)
                case .needEnd: resetState(.needCall)
                default: break
                }
                incomplete()
            } else {
                if [.needNr, .needEnd].contains(station.opState) { extendPatience() }
                switch station.opState {
                case .needQso, .needPrevEnd, .needCallNr: resetState(.needNr)
                case .needCall: resetState(.needEnd)
                default: break
                }
            }
        }
        if input == .exchange || input == .callAndExchange {
            switch station.opState {
            case .needPrevEnd: break
            case .needQso: setState(.needPrevEnd)
            case .needNr:
                if acceptExchange(&station) { resetState(.needEnd) } else { extendPatience() }
            case .needCall, .needEnd: extendPatience()
            case .needCallNr:
                if acceptExchange(&station) { resetState(.needCall) } else { extendPatience() }
            case .done, .failed: break
            }
        }
        if finalDecrement && ![OperatorState.done, .failed, .needPrevEnd].contains(station.opState) {
            decrementPatience()
        }
        return result()
    }
}

struct QRMStationDraw: Equatable {
    var frequencyOffset: Double
    var amplitude: Double
    var speed: Int
}

/// Pure MRCE QRM samplers shared by the live simulator and deterministic
/// distribution tests. Inputs remain the simulator's seeded random stream.
enum QRMSourceModel {
    static func interarrival(using rng: inout ContestRNG) -> Double {
        let u=min(1-1e-15,max(0,rng.random()))
        let blocks=max(1,Int(ceil(logApprox(max(1e-15,1-u))/logApprox(1-0.0002))))
        return Double(blocks)*512/11_025
    }
    static func initialMessageType(using rng: inout ContestRNG) -> QRMMessageType {
        switch rng.int(1,7) {
        case 1: .qrl
        case 2,3: .repeatedQRL
        case 4,5,6: .cq
        default: .qsy
        }
    }
    /// MRCE `TContest.SendMsg` texts for a QRM station. The long CQ carries
    /// the QRM station's own call (`<my>`); only QSY addresses the operator
    /// (`<his>`). The extra spaces are keyed as wider gaps.
    static func message(_ type: QRMMessageType, stationCall: String, operatorCall: String,
                        contest: ContestID = .wpx) -> String {
        switch type {
        case .qrl: "QRL?"
        case .repeatedQRL: "QRL?   QRL?"
        case .cq: longCQ(stationCall: stationCall, contest: contest)
        case .qsy: "\(operatorCall)  QSY QSY"
        }
    }
    static func longCQ(stationCall call: String, contest: ContestID) -> String {
        switch contest {
        case .cwt: "CQ CQ CWT \(call) \(call)"
        case .sst: "CQ CQ SST \(call) \(call)"
        case .sweepstakes: "CQ CQ SS \(call) \(call) SS"
        case .fieldday: "CQ CQ FD \(call) \(call) FD"
        default: "CQ CQ TEST \(call) \(call) TEST"
        }
    }
    static func patience(using rng: inout ContestRNG) -> Int { rng.int(1,5) }
    static func retryDelay(using rng: inout ContestRNG) -> Double { rng.gaussian(4,2) }
    static func stationDraw(using rng: inout ContestRNG) -> QRMStationDraw {
        let frequencyOffset=rng.gaussian(0,300)
        let amplitude=5000+25000*rng.random()
        let speed=rng.int(30,49)
        return QRMStationDraw(frequencyOffset:frequencyOffset,amplitude:amplitude,speed:speed)
    }
}

// Math is provided by the Swift platform C runtime through an import; WASI libc
// supplies the same functions when cross-compiled with the Swift Wasm SDK.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WASILibc)
import WASILibc
#endif
@inline(__always) private func expApprox(_ n:Double)->Double { exp(n) }
@inline(__always) private func logApprox(_ n:Double)->Double { log(n) }
@inline(__always) private func sqrtApprox(_ n:Double)->Double { sqrt(n) }
@inline(__always) private func cosApprox(_ n:Double)->Double { cos(n) }

public final class ContestSimulator {
    /// MRCE's `3 + Round(RndRayleigh(3))` caller patience. The uniforms are
    /// supplied by the caller so reset sites retain their RNG draw order and
    /// this low-tail boundary can be tested directly. Delphi Round uses the
    /// default nearest-even FPU mode; keep that rule for exact ties.
    static func rayleighPatience(first: Double, second: Double) -> Int {
        3 + Int((3 * sqrtApprox(-logApprox(first) - logApprox(second))).rounded(.toNearestOrEven))
    }
    // Synthetic names are used only when contest history has no name for a
    // station. Keep this list local and generic; imported records remain the
    // source of truth whenever they provide a name.
    private static let fallbackNames = [
        "ALEX","ANDY","ANN","ART","ASH","BEN","BILL","BOB","BRAD","BRIAN",
        "CAL","CARL","CHRIS","DAN","DAVE","DEAN","DICK","DON","ED","EDDY",
        "ERIC","EVAN","FRANK","FRED","GARY","GEO","GREG","HANK","IAN","JACK",
        "JAY","JEFF","JIM","JOE","JOHN","KAI","KEN","KEVIN","KIM","KIRK",
        "LARRY","LEE","LEO","LEON","LOU","LUKE","MARK","MATT","MAX","MIKE",
        "NED","NEIL","NICK","NORM","PAUL","PAT","PETE","PHIL","RAY","RICK",
        "ROB","ROD","RON","ROY","RUSS","SAM","SCOTT","SETH","STEVE","TED",
        "TIM","TODD","TOM","TONY","VIC","WALT","WES","WILL","ZAC","ALAN",
        "BARRY","CASEY","CURT","ELI","ELLIOT","GUS","JERRY","JORDAN","MORGAN","TERRY"
    ]
    public private(set) var settings:ContestSettings
    public private(set) var running=false, phase:SessionPhase = .ready
    private var hasStarted=false
    public private(set) var elapsed=0.0, remaining=0.0
    public private(set) var pileup:[Station]=[], targetCall:String?=nil
    public private(set) var log:[QSOEntry]=[]
    public private(set) var selectedCall="", received="", status="Ready to begin"
    public private(set) var verified=0, rawPoints=0, verifiedPoints=0, dupes=0
    public private(set) var rawMultipliers:Set<String>=[], verifiedMultipliers:Set<String>=[]
    private var clock=0.0, txBusyUntil=0.0, lastArrival=0, eventSequence=0
    private var scheduledFIFO=0
    private var nextQSOEntryID=1
    private struct PendingQSOEntry {
        var call:String
        var exchange:String
        var station:Station
        var allowBlankExchange=false
    }
    private var pendingQSOEntries:[Int:PendingQSOEntry]=[:]
    // MRCE's MainForm tracks whether the operator has keyed the other station's
    // call and number/exchange since the last wipe/save.
    private var callSent=false, numberSent=false, callSentValue=""
    // MRCE keeps message tokens for the current keyer burst until the next
    // burst starts. Escape clears only the corresponding sent flags.
    private var burstHasCall=false, burstHasExchange=false
    /// MRCE `TMyStation.Pieces`: own transmissions queued or under way. The
    /// caller's call is a piece of its own (`@`), which is what lets it be
    /// re-keyed when the call box is edited while it is being sent.
    private struct OwnPiece {
        var id:Int, isCall:Bool, text:String, start:Double, end:Double
    }
    private var ownPieces:[OwnPiece]=[], nextOwnPieceID=0
    /// MRCE `MainForm.MustAdvance`: set by an Enter that did not log a
    /// complete call; the cursor moves when the piece being sent ends.
    private var mustAdvance=false
    // MRCE raises one `evMeFinished` per keyer burst and hands every station
    // the union of the burst's message kinds (`Me.Msg`). The burst is open
    // from the first queued macro until the last queued piece ends.
    private var burstOpen=false, burstKinds:Set<OperatorInput>=[], burstTypedCall=""
    private var burstTUCall="", burstCompletesQSO=false
    // Stations that were already on the air when the burst started keep
    // sending and later hear the burst only as garbage (MRCE `stSending`).
    private var sendingAtBurstStart:Set<String>=[]
    private var qsosSinceStationID=0
    private var callerTransmitRanges:[String:[(start:Double,end:Double)]]=[:]
    private var ownSerialCounter:OwnSerialCounter
    private var homeFastReportR1=0.0
    private var activeQSOCalls:Set<String>=[]
    // MRCE accepts mcAlmost only at or above the best confidence established
    // by the most recent callsign sent by the operator.
    private var bestMatchCallConfidence=1
    private var sessionDrainUntil=0.0
    private var completed:[Station]=[]
    private var preparedFieldDayCalls:[String]=[]
    /// General SCP callers are a fallback pool after contest-specific and
    /// user-imported calls. Kept separate from ContestSettings so a large
    /// reference database never enters settings persistence.
    private let genericRecords:[String:HistoryRecord]
    private let genericCalls:[String]
    private let genericCallSet:Set<String>
    private var callerMetadata:[String:ContestRules.CallMeta]=[:]
    private var contestCallerPool:[String]=[]
    private var sstCallerPool:[HistoryRecord]=[]
    private var eligibleGenericPool:[String]=[]
    private var seenGenericCalls:Set<String>=[]
    private var seenStationCalls:Set<String>=[]
    /// The Sweepstakes history hint has its own stream, so the learning aid's
    /// rate cannot change any caller's behaviour for a given seed.
    private var hintRng=ContestRNG(seed:1)
    private var rng:ContestRNG, rfRng:ContestRNG, nextSingleBlock=0, singleStartupPending=false, events:[RadioEvent]=[]
    private var fallbackNameCycle:[String]=[], fallbackNameIndex=0, lastFallbackName:String?
    private var sessionFallbackNames:[String:String]=[:]
    /// True when `contestCallerPool` is a general call list rather than a
    /// history imported for this contest.
    private var callerPoolIsGeneral=true
    /// Share of callers that are US or Canadian stations when calls come from
    /// a general, worldwide list or the generator. The figures are the shares
    /// in MRCE's own call-history file for each contest (pinned commit), which
    /// is what MRCE draws from. Contests without an entry keep the list's own
    /// mix. POTA has no MRCE file; its figure is an estimate.
    static func homeShare(_ contest:ContestID) -> Double? {
        switch contest {
        case .fieldday: return 0.98
        case .naqp: return 0.98
        case .sst: return 0.94
        case .cwt: return 0.68
        case .cqww: return 0.54
        case .arrl10: return 0.45
        case .iaru: return 0.32
        case .pota: return 0.90
        case .wpx,.hst,.arrldx,.sweepstakes,.allja,.acag: return nil
        }
    }
    /// One uniform pick from a general list, first choosing between US/Canada
    /// and everyone else by the contest's share. If the chosen side has no
    /// eligible call the other side is used.
    private func pickFromGeneralList(_ eligible:[String]) -> String? {
        guard !eligible.isEmpty else {return nil}
        guard let share=Self.homeShare(settings.contest) else {return eligible[rng.int(0,eligible.count-1)]}
        let wantHome=rng.random()<share
        let side=eligible.filter{callerMeta($0).usve == wantHome}
        let pool=side.isEmpty ? eligible : side
        return pool[rng.int(0,pool.count-1)]
    }
    private struct QRMRetry {
        var station:Station
        var patience:Int
        var due:Double
    }
    private var nextQRMDue=0.0
    private var qrmRetries:[QRMRetry]=[]
    private struct Scheduled {
        enum Action {case burstEnd, pieceEnd, received(RadioEvent)}
        var due:Double, sequence:Int, fifo:Int, action:Action
    }
    private var scheduled:[Scheduled]=[]
    public init(settings requested:ContestSettings, genericHistory:ImportedHistory? = nil) {
        settings=requested.effective()
        // Seed generated own serials independently so this one-time initial
        // exchange draw cannot shift caller selection or session timing.
        var ownSerialRng=ContestRNG(seed:requested.seed ^ 0x6A09_E667)
        let generatedOwnStart: Int
        if settings.serialRange == .mid || settings.serialRange == .end {
            // `Tst.Me.NR := 1 + (Tst.GetRandomSerialNR div 10) * 10` (Main.SetMyExch1/2).
            generatedOwnStart=1+(SerialDistribution.draw(settings,rng:&ownSerialRng,elapsed:0,skill:1)/10)*10
        } else {
            generatedOwnStart=1
        }
        ownSerialCounter=OwnSerialCounter(startingAt:ContestRules.initialOwnSerial(settings,generatedStart:generatedOwnStart))
        hintRng=ContestRNG(seed:requested.seed ^ 0x13C6_EF37)
        var homeStationRng=ContestRNG(seed:requested.seed ^ 0x243F_6A88)
        homeFastReportR1=homeStationRng.random()
        genericRecords=genericHistory?.records ?? [:]
        genericCalls=genericHistory?.calls ?? []
        genericCallSet=Set(genericHistory?.calls ?? [])
        rng=ContestRNG(seed:requested.seed)
        // Keep the audio source draws deterministic without consuming game
        // draws, so RF amplitude generation cannot shift contest behavior.
        rfRng=ContestRNG(seed:requested.seed ^ 0xF3A5_17C9)
        // Use an independent seeded stream so adding name diversity does not
        // change calls, timings, or other simulation draws.
        var nameRng=ContestRNG(seed:requested.seed ^ 0xA511E9B3)
        fallbackNameCycle=Self.fallbackNames
        if fallbackNameCycle.count > 1 {
            for index in stride(from:fallbackNameCycle.count-1,through:1,by:-1) {
                let other=nameRng.int(0,index)
                fallbackNameCycle.swapAt(index,other)
            }
        }
        if settings.contest == .fieldday,
           let history=settings.contestHistories["fieldday"],!history.calls.isEmpty {
            preparedFieldDayCalls=HistoryImport.fieldDayEligibleCalls(history,rng:&rng)
        }
        remaining=Double(settings.duration*60)
        let contestHistory=settings.contestHistories[settings.contest.rawValue]
        contestCallerPool = !preparedFieldDayCalls.isEmpty ? preparedFieldDayCalls :
            (contestHistory?.calls.isEmpty == false ? contestHistory!.calls : settings.customCalls)
        if settings.contest == .sst { sstCallerPool=contestHistory?.rows ?? [] }
        for call in Set(contestCallerPool + genericCalls + sstCallerPool.map(\.call) + [settings.myCall]) {
            callerMetadata[call]=ContestRules.callMeta(call,settings:settings)
        }
        func allowed(_ candidate:String)->Bool {
            let meta=callerMetadata[candidate] ?? ContestRules.callMeta(candidate,settings:settings)
            let mine=callerMetadata[settings.myCall] ?? ContestRules.callMeta(settings.myCall,settings:settings)
            if [.cqww,.iaru,.arrldx,.arrl10,.naqp].contains(settings.contest) && !meta.known {return false}
            if settings.contest == .sweepstakes && !meta.hasARRLSection {return false}
            if settings.contest == .arrldx && mine.usve == meta.usve {return false}
            if settings.contest == .naqp && !mine.isNAQPLocal && !meta.isNAQPLocal {return false}
            return true
        }
        contestCallerPool=contestCallerPool.filter(allowed)
        sstCallerPool=sstCallerPool.filter{allowed($0.call)}
        // The general-purpose list is worldwide. A contest whose stations all
        // come from one place takes only those calls from it; a contest
        // history the user imported is used as it stands.
        func fitsContest(_ candidate:String)->Bool {
            let meta=callerMetadata[candidate] ?? ContestRules.callMeta(candidate,settings:settings)
            switch settings.contest {
            case .allja,.acag: return meta.country == "JA"
            default: return true
            }
        }
        eligibleGenericPool=genericCalls.filter{allowed($0) && fitsContest($0)}
        callerPoolIsGeneral=contestHistory?.calls.isEmpty != false && preparedFieldDayCalls.isEmpty
        if callerPoolIsGeneral {contestCallerPool=contestCallerPool.filter(fitsContest)}
    }
    private func callerMeta(_ call:String)->ContestRules.CallMeta {
        if let cached=callerMetadata[call] {return cached}
        let resolved=ContestRules.callMeta(call,settings:settings)
        callerMetadata[call]=resolved
        return resolved
    }
    /// Radio changes made while on air affect the simulation's future TX/RX.
    public func updateRadio(_ requested:ContestSettings) {
        let wasQRM=settings.effects.qrm
        settings.wpm=max(5,min(120,requested.wpm))
        settings.activity=settings.mode == .hstCompetition ? 4 : min(9,max(1,requested.activity))
        settings.pitch=requested.pitch;settings.rit=requested.rit
        settings.bandwidth=settings.mode == .hstCompetition ? 600 : requested.bandwidth
        settings.monitor=requested.monitor;settings.volume=requested.volume;settings.qsk=requested.qsk
        if settings.mode != .wpxCompetition && settings.mode != .hstCompetition {settings.effects=requested.effects}
        if !settings.effects.qrm {
            nextQRMDue=0
            qrmRetries.removeAll()
        } else if !wasQRM, running {
            nextQRMDue=clock+qrmInterarrival()
        }
    }
    public var contacts:Int {log.count}
    public var multipliers:Int {verifiedMultipliers.count}
    public var score:Int {verifiedPoints * (settings.contest == .hst ? 1 : verifiedMultipliers.count)}
    public var rawScore:Int {rawPoints * (settings.contest == .hst ? 1 : rawMultipliers.count)}
    public var pending:Int {pileup.count}
    private var hstCallerTarget:Int { settings.activity }
    public var target:Station? {pileup.first(where:{$0.call == targetCall})}
    /// MRCE `Log.ShowRate`: contacts saved in the last five minutes (or since
    /// the start, if less), scaled to an hour. Not the whole-session average.
    public var rate:Int {
        guard elapsed > 0 else {return 0}
        let window=min(300,elapsed)
        let recent=log.filter{$0.at > elapsed-window}.count
        return Int((Double(recent)/window*3600).rounded())
    }
    public var snapshot:SessionSnapshot {
        SessionSnapshot(running:running,phase:phase,remaining:remaining,elapsed:elapsed,contacts:contacts,
                        verified:verified,score:score,multipliers:multipliers,rawPoints:rawPoints,dupes:dupes,
                        rate:rate,
                        pending:pending,selectedCall:selectedCall,serial:ownSerialCounter.value,status:status)
    }
    public func drainEvents() -> [RadioEvent] { let result=events;events.removeAll();return result }
    private func emit(_ kind:RadioEventKind,_ text:String,calls:[String]=[],reason:String="",fastReportStart:Int?=nil,fastReportStarts:[Int]?=nil,fastReportRate:Double=1.0,noticeCode:RadioNoticeCode?=nil) {
        if kind == .notice {status=text}
        events.append(RadioEvent(kind,text,calls:calls,reason:reason,at:clock,fastReportStart:fastReportStart,fastReportStarts:fastReportStarts,fastReportRate:fastReportRate,noticeCode:noticeCode))
    }
    /// Starts this simulator once. Construct a new simulator for a fresh
    /// session; stopped/finished instances cannot be restarted or resumed.
    @discardableResult public func start() -> Bool {
        guard !running, !hasStarted else {return false}
        hasStarted=true
        running=true;phase = .ready;clock=0;elapsed=0;remaining=Double(settings.duration*60)
        qsosSinceStationID=0;callerTransmitRanges.removeAll()
        nextSingleBlock=0;singleStartupPending=false
        nextQRMDue=settings.effects.qrm ? clock+qrmInterarrival() : 0
        qrmRetries.removeAll()
        switch settings.mode {
        case .single:
            singleStartupPending=true
            nextSingleBlock=Int((11025.0/512.0*Double(settings.singleCallStartDelay)/1000.0).rounded())+5
        case .hstCompetition: refillAutomatic(hstCallerTarget)
        default:break
        }
        return true
    }
    public func tick(_ now:Double) {
        guard running else {return}
        clock=max(clock,now);elapsed=clock;remaining=max(0,Double(settings.duration*60)-elapsed)
        for call in Array(callerTransmitRanges.keys) {
            callerTransmitRanges[call]?.removeAll(where:{$0.end<=clock})
            if callerTransmitRanges[call]?.isEmpty == true {callerTransmitRanges.removeValue(forKey:call)}
        }
        advanceQRM(lookahead:0.08)
        if singleStartupPending && Int((clock*11025.0/512.0).rounded(.down)) > nextSingleBlock {
            singleStartupPending=false
            refillAutomatic(1)
        }
        // An action may enqueue another action, so process all ready actions in sequence.
        var iterations=0
        while let index=scheduled.indices.filter({scheduled[$0].due <= clock}).min(by:{
            scheduled[$0].due == scheduled[$1].due
                ? scheduled[$0].fifo < scheduled[$1].fifo
                : scheduled[$0].due < scheduled[$1].due
        }),iterations<256 {
            let item=scheduled.remove(at:index);iterations+=1
            if item.sequence != eventSequence {continue}
            switch item.action {
            case .burstEnd: finishBurst(kinds:burstKinds)
            // MyStn.GetBlock calls MainForm.Advance whenever a piece ends.
            case .pieceEnd:
                if mustAdvance {mustAdvance=false;emit(.advanceEntry,"")}
            case let .received(event):
                events.append(RadioEvent(event.kind,event.text,calls:event.stationCalls,reason:event.reason,at:item.due,voices:event.voices,fastReportStart:event.fastReportStart,fastReportStarts:event.fastReportStarts,fastReportRate:event.fastReportRate))
            }
        }
        // Each caller runs its own reply timer (MRCE `evTimeout`). Only the
        // operator's own transmission holds callers off; callers never wait
        // for each other. Browser suspension (>15s) must not trigger an
        // artificial barrage of repeats, so a long-overdue timer is re-armed.
        if clock >= txBusyUntil {
            var fired=0
            while fired<256,
                  let index=pileup.indices.filter({ index in
                      let st=pileup[index]
                      return st.opState != .done && st.opState != .failed && !st.ghosting &&
                          st.nextAction > 0 && st.nextAction <= clock
                  }).min(by:{pileup[$0].nextAction < pileup[$1].nextAction}) {
                fired+=1
                let due=pileup[index].nextAction
                if clock-due > 15 {
                    let timeout=replyTimeout(&pileup[index])
                    pileup[index].nextAction=clock+timeout;continue
                }
                decrementPatience(&pileup[index],silent:true)
                if pileup[index].opState == .failed {continue}
                if pileup[index].ghosting {pileup[index].nextAction=0;continue}
                let message=operatorReply(&pileup[index],cause:.timeout)
                if message.isEmpty {pileup[index].nextAction=0}
                else {operatorSays(index,message,reason:targetCall==pileup[index].call ? "dialogue" : "repeat",startingAt:due)}
            }
        }
        // A logged caller that gives up without hearing TU leaves a NIL row at
        // once (MRCE's Log.CheckErr), not at the operator's next CQ or TU.
        if !pendingQSOEntries.isEmpty {reconcilePendingQSOs()}
        pileup.removeAll(where:{$0.opState == .failed})
        if let targetCall, !pileup.contains(where:{$0.call==targetCall}) {self.targetCall=nil;phase = .listening}
        scheduleSingleCallerIfNeeded()
        // MRCE tops the HST pile back up to Activity on every audio block,
        // so callers that give up are replaced without a CQ.
        if settings.mode == .hstCompetition && remaining > 0 {refillAutomatic(hstCallerTarget)}
        // At time, drain only a pending TU for an active QSO, capped at 15s.
        if remaining <= 0 && !(sessionDrainUntil > 0 && clock <= sessionDrainUntil && txBusyUntil > clock) {
            reconcilePendingQSOs(force:true)
            running=false;phase = .finished;scheduled.removeAll()
            qrmRetries.removeAll();nextQRMDue=0
            emit(.stopAudio,"");emit(.finished,"Session complete. 73!")
        }
    }
    /// QRM arrivals are a geometric process in MRCE's 512-frame blocks at
    /// 11,025 Hz. Emit up to one timer interval early so the audio host can
    /// place the station on its sample clock at `event.at`.
    private func qrmInterarrival() -> Double {
        QRMSourceModel.interarrival(using:&rng)
    }
    private func advanceQRM(lookahead:Double) {
        guard settings.effects.qrm else {return}
        let horizon=clock+max(0,lookahead)
        while nextQRMDue > 0 && nextQRMDue <= horizon && nextQRMDue < Double(settings.duration*60) {
            let due=nextQRMDue
            nextQRMDue=due+qrmInterarrival()
            var station=makeQRMStation()
            var stationRng=ContestRNG(seed:station.behaviorRNGState)
            let patience=QRMSourceModel.patience(using:&stationRng)-1
            let message=QRMSourceModel.message(QRMSourceModel.initialMessageType(using:&stationRng),stationCall:station.call,
                                               operatorCall:ContestRules.normalizeCall(settings.myCall),contest:settings.contest)
            station.behaviorRNGState=stationRng.state
            emitInterference(station:station,message:message,at:due)
            if patience>0 {
                let duration=MorseTimeline.duration(message,wpm:station.wpm,farnsworthKeyer:farnsworthKeyer)
                let retryDelay=stationRetryDelay(&station)
                qrmRetries.append(QRMRetry(station:station,patience:patience,
                                           due:due+duration+retryDelay))
            }
        }
        var index=0
        while index<qrmRetries.count {
            guard qrmRetries[index].due <= horizon else {index+=1;continue}
            let retry=qrmRetries.remove(at:index)
            let message=QRMSourceModel.longCQ(stationCall:retry.station.call,contest:settings.contest)
            emitInterference(station:retry.station,message:message,at:retry.due)
            let patience=retry.patience-1
            if patience>0 {
                let duration=MorseTimeline.duration(message,wpm:retry.station.wpm,farnsworthKeyer:farnsworthKeyer)
                var station=retry.station
                let retryDelay=stationRetryDelay(&station)
                qrmRetries.append(QRMRetry(station:station,patience:patience,
                                           due:retry.due+duration+retryDelay))
            }
        }
    }
    private func emitInterference(station:Station,message:String,at time:Double) {
        var voice=RadioVoice(station:station,message:message)
        voice.farnsworthKeyer=farnsworthKeyer
        events.append(RadioEvent(.interference,"Band interference",calls:[station.call],reason:"qrm",at:time,voices:[voice]))
    }
    private func makeQRMStation() -> Station {
        let history=settings.contestHistories[settings.contest.rawValue]
        let pool = !preparedFieldDayCalls.isEmpty ? preparedFieldDayCalls :
            (history?.calls.isEmpty == false ? history!.calls : settings.customCalls)
        let mine=ContestRules.callMeta(settings.myCall,settings:settings)
        func allowed(_ candidate:String)->Bool {
            let meta=ContestRules.callMeta(candidate,settings:settings)
            if [.cqww,.iaru,.arrldx,.arrl10,.naqp].contains(settings.contest) && !meta.known {return false}
            if settings.contest == .sweepstakes && !meta.hasARRLSection {return false}
            if settings.contest == .arrldx && mine.usve == meta.usve {return false}
            if settings.contest == .naqp && !mine.isNAQPLocal && !meta.isNAQPLocal {return false}
            return true
        }
        let eligible=pool.filter(allowed)
        var call=eligible.isEmpty ? "" : eligible[rng.int(0,eligible.count-1)]
        if call.isEmpty, !genericCalls.isEmpty {
            for _ in 0..<16 {
                let candidate=genericCalls[rng.int(0,genericCalls.count-1)]
                if allowed(candidate) {call=candidate;break}
            }
        }
        if call.isEmpty {call=CallsignGenerator.makeCall(&rng,region:.all)}
        let seed=UInt32(rng.random()*4_294_967_296.0)
        var stationRng=ContestRNG(seed:seed)
        let draw=QRMSourceModel.stationDraw(using:&stationRng)
        var station=Station(call:call,exchange:"",wpm:draw.speed,
                       tone:max(1,settings.pitch+Int(draw.frequencyOffset.rounded())),
                       volume:draw.amplitude/30000,shift:draw.frequencyOffset,rfAmplitude:draw.amplitude)
        station.behaviorRNGState=stationRng.state
        return station
    }
    private func stationRetryDelay(_ station:inout Station) -> Double {
        stationGaussian(&station,4,2)
    }
    public func stopSession() { reconcilePendingQSOs(force:true);running=false;phase = .finished;scheduled.removeAll();emit(.stopAudio,"");emit(.finished,"Session ended.") }
    public func stopTransmission() {
        eventSequence += 1;scheduled.removeAll();txBusyUntil=clock;ownPieces.removeAll()
        // AbortSend publishes msgGarbage as an immediate evMeFinished. Callers
        // that were copying process that partial transmission and may repeat
        // their current information.
        if callSent && burstHasCall {callSent=false;callSentValue=""}
        if numberSent && burstHasExchange {numberSent=false}
        burstHasCall=false;burstHasExchange=false
        for index in pileup.indices { pileup[index].nextAction=0 }
        for (call,ranges) in callerTransmitRanges where ranges.contains(where:{$0.start>clock}) {
            callerTransmitRanges[call]=ranges.filter{$0.start<=clock}
        }
        burstOpen=false;burstKinds=[];burstTypedCall="";burstCompletesQSO=false
        finishBurst(kinds:[.garbage])
        emit(.stopAudio,"");emit(.notice,"TX cancelled. Call or repeat to continue.")
    }
    /// `exchangeFirst`/`exchangeSecond` carry the two received-exchange boxes.
    /// When both are nil they are derived from the joined `exchange`.
    public func command(_ command:Command,call:String="",exchange:String="",exchangeFirst:String?=nil,exchangeSecond:String?=nil) {
        guard running else {return}
        let fields:(first:String,second:String)
        if exchangeFirst == nil && exchangeSecond == nil {
            fields=ContestRules.deriveReceivedExchangeFields(exchange,contest:settings.contest)
        } else {fields=(exchangeFirst ?? "",exchangeSecond ?? "")}
        let exchange=exchangeFirst == nil && exchangeSecond == nil
            ? exchange : ContestRules.joinReceivedExchangeFields(first:fields.first,second:fields.second)
        // MainForm.Edit1 is live when any macro is sent (not just Enter), and
        // DxOper uses it to decide whether F7 can restart a waiting caller.
        selectedCall=ContestRules.normalizeCall(call)
        switch command {
        case .cq: sendCq()
        case .call:
            let sentExchange=sendCall(call)
            if ContestRules.normalizeCall(call) != "?" {callSent=true;numberSent=sentExchange;callSentValue=selectedCall}
        case .hiscall: sendHisCall(call);callSent=true;callSentValue=selectedCall
        case .exchange: sendExchange();numberSent=true
        case .repeatMessage: sendRepeat(.question,message:"?")
        // F12 is msgNrQm, a request/repeat macro. MRCE's NrSent flag is set
        // only for msgNR (F2), never for this macro.
        case .numberAgain: sendRepeat(.numberQuestion,message:"NR?")
        case .tu: sendTU()
        case .log:
            if call.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                emit(.notice,"Enter a valid callsign before saving.",noticeCode:.callInvalid)
            } else {
                if !callSent {sendHisCall(call);callSent=true;callSentValue=selectedCall}
                _ = logQSO(call:call,exchange:exchange)
            }
        case .saveOnly:
            saveOnlyQSO(call:call,exchange:exchange)
        case .wipe: selectedCall="";received="";callSent=false;numberSent=false;callSentValue="";emit(.notice,"Entry cleared.")
        case .stop: stopTransmission()
        case .esm:
            // MRCE ProcessEnter is driven by MainForm's CallSent/NrSent flags
            // and the received exchange field, rather than the DX state alone.
            let normalizedCall=ContestRules.normalizeCall(call)
            mustAdvance=false
            if callSent && normalizedCall != callSentValue {callSent=false}
            if call.isEmpty {sendCq()}
            else if normalizedCall == "?" {selectedCall="";sendRepeat(.question,message:"?")}
            else if call.contains("?") {sendCall(call);callSent=true;callSentValue=normalizedCall}
            else {
                // MRCE ProcessEnter: C/N snapshot CallSent/NrSent, Q is the
                // first received box, R the second (Sweepstakes validates the
                // whole exchange; NAQP DX calls send no state).
                let hadSentCall=callSent, hadSentNumber=numberSent
                let validCall=Self.validSavedCall(call) != nil
                let q=settings.contest == .sweepstakes || !fields.first.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
                let secondFilled = !fields.second.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
                let r:Bool
                switch settings.contest {
                case .sweepstakes: r=ContestRules.isExchangeStructurallyValid(settings,received:fields.second,expected:"")
                case .naqp:
                    let meta=ContestRules.callMeta(normalizedCall,settings:settings)
                    r=secondFilled || (meta.known && !meta.isNAQPLocal)
                default: r=secondFilled
                }
                let sendHis = !hadSentCall || (!hadSentNumber && !r)
                let sendNr = !hadSentNumber && validCall
                if sendHis && sendNr {
                    // Deliver the call and exchange together so the caller answers once,
                    // after the complete transmission.
                    numberSent=sendCall(call);callSent=true;callSentValue=selectedCall
                } else {
                    if sendHis {sendHisCall(call);callSent=true;callSentValue=selectedCall}
                    if sendNr {sendExchange();numberSent=true}
                }
                if hadSentNumber && (!r || !q) {sendRepeat(.question,message:"?")}
                // MRCE validates that exchange fields are present and have
                // the contest's required shape before TU. A syntactically
                // complete but incorrect exchange is still logged; its
                // correctness is diagnosed in the log afterward.
                // The first Enter can send HIS CALL/NR and the next Enter
                // confirms the contact.
                if r && q && (hadSentCall || hadSentNumber) {
                    // With no station to compare against, only the shape of what was typed can be checked.
                    let expected=savedStation(for:call)?.exchange ?? exchange
                    if ContestRules.isExchangeStructurallyValid(settings,received:exchange,expected:expected) {
                        _ = logQSO(call:call,exchange:exchange)
                    } else {
                        emit(.notice,"Exchange is incomplete or invalid. Correct it before logging.",noticeCode:.exchangeInvalid)
                    }
                } else {mustAdvance=validCall}
            }
        case .mycall: sendTx(ContestRules.normalizeCall(settings.myCall),kinds:[.myCall])
        case .b4: sendTx("QSO B4",kinds:[.b4])
        // MRCE F8 is an on-air macro. The user decides whether to keep or
        // re-contact a caller; keying NIL alone does not discard it.
        case .nil: sendTx(settings.effectiveNilText,kinds:[.nilInput])
        }
    }
    private func sendTx(_ text:String,kinds:Set<OperatorInput>,call:String?=nil,completesQSO:Bool=false,containsCall:Bool=false,containsExchange:Bool=false) {
        let tx=text.uppercased()
        if !burstOpen {
            burstOpen=true;burstKinds=[];burstTypedCall="";burstTUCall="";burstCompletesQSO=false
            burstHasCall=false;burstHasExchange=false
            beginBurst()
        }
        burstKinds.formUnion(kinds)
        if let call {burstTypedCall=call}
        if kinds.contains(.tu) && burstTUCall.isEmpty {burstTUCall=targetCall ?? ""}
        burstCompletesQSO = burstCompletesQSO || completesQSO
        burstHasCall = burstHasCall || containsCall
        burstHasExchange = burstHasExchange || containsExchange
        let ownExchange=ContestRules.sentExchange(settings,ownSerial:ownSerialCounter.value)
        let fastStarts=fastReportStarts(in:tx,exchange:ownExchange)
        let fastRate=fastStarts.isEmpty ? nil : FastReportTiming.rate(randomValue:homeFastReportR1,occurrenceRate:settings.fast5nnOccurrenceRate,isHomeStation:true)
        // MRCE's TMyStation.AddToPieces queues new macros while sending. The
        // callers hear one message set, delivered when the LAST queued piece
        // has finished. Escape/STOP clears everything.
        let keyed=MorseTimeline.duration(tx,wpm:settings.wpm,characterWpm:ownCharacterWpm,
                                         fastReportRate:fastRate ?? 1.0,fastReportStarts:fastRate == nil ? [] : fastStarts)
        // The message set is delivered when MRCE's last envelope block ends.
        let extra=MorseTimeline.blockPadded(keyed)
        scheduled.removeAll { if case .burstEnd = $0.action {return true};return false }
        emit(.transmit,tx,fastReportStart:fastRate == nil ? nil : fastStarts.first,fastReportStarts:fastRate == nil ? nil : fastStarts,fastReportRate:fastRate ?? 1.0)
        if ownCharacterWpm != settings.wpm,let last=events.indices.last {events[last].characterWpm=ownCharacterWpm}
        let start=max(clock,txBusyUntil)
        txBusyUntil=start+extra
        ownPieces.removeAll{$0.end <= clock}
        nextOwnPieceID+=1
        ownPieces.append(OwnPiece(id:nextOwnPieceID,isCall:containsCall,text:tx,start:start,end:txBusyUntil))
        if let last=events.indices.last {events[last].pieceID=nextOwnPieceID}
        schedule(txBusyUntil,.pieceEnd)
        schedule(txBusyUntil,.burstEnd)
    }
    /// MRCE `MainForm.Edit1Change`: the host reports every edit of the call
    /// box. An edit that cannot be worked into a call still being sent means
    /// the call on the air is no longer the one in the box, so it is owed again.
    ///
    /// `sentSeconds` is MRCE's `SendPos`: given a transmit event's `pieceID`
    /// it returns how much of that piece the audio host has handed to its
    /// output buffer (zero or less if it has not started, infinity if it has
    /// gone). Without it the simulator clock is used, in whole audio blocks.
    @discardableResult public func callEdited(_ text:String,sentSeconds:((Int)->Double)?=nil) -> Bool {
        guard running else {return false}
        let call=ContestRules.normalizeCall(text)
        if call.isEmpty {numberSent=false}
        let updated=updateCallInMessage(call,sentSeconds:sentSeconds)
        if !updated {callSent=false}
        return updated
    }
    /// MRCE `MainForm.ProcessSpace`: moving the cursor by hand cancels the
    /// move that was waiting for the transmission.
    public func cancelEntryAdvance() {mustAdvance=false}
    /// MRCE `TMyStation.UpdateCallInMessage`. While the caller's call is being
    /// keyed it can still be corrected: if what has gone out so far is keyed
    /// the same in the edited call, the rest is sent from the edited call.
    /// Failing that, a call still queued behind other text is replaced.
    private func updateCallInMessage(_ call:String,sentSeconds:((Int)->Double)?) -> Bool {
        guard !call.isEmpty else {return false}
        ownPieces.removeAll{$0.end <= clock}
        func marks(_ text:String) -> [MorseTimeline.Mark] {
            MorseTimeline.marks(text,wpm:settings.wpm,characterWpm:ownCharacterWpm)
        }
        func length(_ text:String) -> Double {
            MorseTimeline.blockPadded(MorseTimeline.duration(text,wpm:settings.wpm,characterWpm:ownCharacterWpm))
        }
        var replace:[Int]=[]
        if let current=ownPieces.first,current.isCall {
            let sent=sentSeconds?(current.id) ?? MorseTimeline.blockPadded(clock-current.start)
            if sent <= 0 ||
               (length(call) >= sent && MorseTimeline.sameKeying(marks(current.text),marks(call),until:sent)) {
                replace=ownPieces.indices.filter{ownPieces[$0].isCall}
            }
        }
        // Could not correct the piece being sent, but another call is queued.
        if replace.isEmpty {replace=ownPieces.indices.dropFirst().filter{ownPieces[$0].isCall}}
        guard !replace.isEmpty else {return false}
        for index in replace {
            let old=ownPieces[index]
            guard old.text != call else {continue}
            let delta=length(call)-(old.end-old.start)
            ownPieces[index].text=call;ownPieces[index].end+=delta
            for later in ownPieces.indices where later > index {ownPieces[later].start+=delta;ownPieces[later].end+=delta}
            for item in scheduled.indices where scheduled[item].due >= old.end-0.001 {scheduled[item].due+=delta}
            txBusyUntil+=delta
            emit(.rekey,call)
            if let last=events.indices.last {
                events[last].pieceID=old.id
                if ownCharacterWpm != settings.wpm {events[last].characterWpm=ownCharacterWpm}
            }
        }
        selectedCall=call;burstTypedCall=call;callSentValue=call
        return true
    }
    private func cancelPendingTransmission(_ call:String) {
        var removed=false
        scheduled.removeAll { item in
            guard case let .received(event)=item.action,event.stationCalls == [call] else {return false}
            removed=true;return true
        }
        guard removed,let ranges=callerTransmitRanges[call],let last=ranges.lastIndex(where:{$0.start>=clock}) else {return}
        callerTransmitRanges[call]?.remove(at:last)
        if callerTransmitRanges[call]?.isEmpty == true {callerTransmitRanges.removeValue(forKey:call)}
    }
    /// MRCE `evMeStarted`: a station that is not sending switches to copying
    /// and drops its timer (one that was about to send does not send); one
    /// that is sending keeps sending and will only hear the burst as garbage.
    private func beginBurst() {
        sendingAtBurstStart=[]
        // Unheard scheduled replies are cancelled, and their on-air ranges
        // with them, so the cancelled voices never count as "transmitting".
        for item in scheduled {
            guard case let .received(event)=item.action else {continue}
            for voice in event.voices {
                if let ranges=callerTransmitRanges[voice.call],let last=ranges.lastIndex(where:{$0.end>clock && $0.start>=clock}) {
                    callerTransmitRanges[voice.call]?.remove(at:last)
                }
                if callerTransmitRanges[voice.call]?.isEmpty == true {callerTransmitRanges.removeValue(forKey:voice.call)}
            }
        }
        scheduled.removeAll { if case .received = $0.action {return true};return false }
        for index in pileup.indices {
            let call=pileup[index].call
            if isOnAir(call) {sendingAtBurstStart.insert(call)}
            else {pileup[index].nextAction=0}
        }
    }
    private func isOnAir(_ call:String) -> Bool {
        callerTransmitRanges[call,default:[]].contains(where:{$0.start<=clock && clock<$0.end})
    }
    private func fastReportStarts(in message:String,exchange:String) -> [Int] {
        guard settings.fast5nn,settings.fast5nnOccurrenceRate>0,
              settings.contest != .sst,
              ![.wpxCompetition,.hstCompetition].contains(settings.mode),
              [.wpx,.cqww,.arrldx,.iaru,.allja,.acag,.arrl10,.pota,.hst].contains(settings.contest),
              let report=exchange.uppercased().split(whereSeparator:{$0.isWhitespace}).first,
              ["599","5NN","ENN"].contains(report) else {return []}
        // Callers re-render their exchange on each transmission (5NN, ENN, cut
        // digits, LID corrections), so mark every standalone 5NN/599 token in the
        // message. MRCE's IsFastReport excludes ENN.
        var starts:[Int]=[],offset=0
        for token in message.uppercased().split(whereSeparator:{$0.isWhitespace}) {
            if token == "5NN" || token == "599" {starts.append(offset)}
            // WPX and HST run the report into the serial (`5NNTT1`).
            else if CallerExchangeText.runsReportIntoSerial(settings.contest),token.count > 3,
                    token.hasPrefix("5NN") || token.hasPrefix("599"),
                    token.dropFirst(3).allSatisfy({"0123456789TONA".contains($0)}) {starts.append(offset)}
            offset+=token.count+1
        }
        return starts
    }
    /// TX starts with a predicted horizon from Morse duration. Playback ACKs
    /// extend that horizon when actual audio runs longer, shifting queued
    /// actions that were predicted to follow the earlier end time.
    /// `startedAt` is the simulator time of the transmit event being
    /// acknowledged. Passing it keeps the end of the transmission independent
    /// of how many ticks ran before the audio host answered.
    public func acknowledgeTransmit(duration:Double,startedAt:Double?=nil) {
        guard duration.isFinite && duration > 0 else {return}
        let actual=(startedAt ?? clock)+duration
        if actual > txBusyUntil {
            let delta=actual-txBusyUntil;let previous=txBusyUntil
            txBusyUntil=actual
            for index in scheduled.indices where scheduled[index].due >= previous-0.001 {scheduled[index].due+=delta}
        }
    }
    /// Playback ACK for one caller event. Only the station(s) heard in that
    /// event are affected: their reply timeout cannot expire before the audio
    /// actually ends. Callers never wait for each other, so other stations'
    /// timers are untouched. Without `calls` nothing is adjusted.
    public func acknowledgeReceive(duration:Double,calls:[String]=[]) {
        guard duration.isFinite && duration > 0 else {return}
        let audibleUntil=clock+duration+0.05
        for call in calls {
            guard let index=pileup.firstIndex(where:{$0.call==call}),
                  ![OperatorState.done,.failed].contains(pileup[index].opState),
                  pileup[index].nextAction > 0,pileup[index].nextAction < audibleUntil else {continue}
            let timeout=replyTimeout(&pileup[index])
            pileup[index].nextAction=audibleUntil+timeout
        }
    }
    /// Puts one caller on the air. With `startingAt` the transmission begins
    /// at that instant (a fired reply timeout); otherwise the station first
    /// waits its own MRCE send delay (`GetSendDelay`: 0.1-0.6 s, HST
    /// 0.05+0.5*r*10/wpm, in 512-sample blocks at 11,025 Hz). Each caller is
    /// its own event with its own start time, so replies overlap naturally.
    private func queueTransmission(_ index:Int,_ message:String,reason:String,startingAt:Double?=nil) {
        guard pileup.indices.contains(index),!message.isEmpty else {return}
        // One timer per station: a new send replaces a still-pending one.
        cancelPendingTransmission(pileup[index].call)
        var st=pileup[index]
        let due:Double
        if let startingAt {due=startingAt}
        else {
            let delayDraw=stationRandom(&st)
            let delay=settings.mode == .hstCompetition
                ? 0.05+0.5*delayDraw*10/Double(settings.wpm)
                : 0.1+0.5*delayDraw
            due=max(clock,txBusyUntil)+(delay*11025/512).rounded()*512/11025
        }
        let reportStarts=st.qrsStage == 0 ? fastReportStarts(in:message,exchange:st.transmittedExchange.isEmpty ? st.exchange : st.transmittedExchange) : []
        let fastRate=reportStarts.isEmpty ? nil : FastReportTiming.rate(randomValue:st.stationDraw,occurrenceRate:settings.fast5nnOccurrenceRate,isHomeStation:false)
        var voice=RadioVoice(station:st,message:message,fastReportStart:fastRate == nil ? nil : reportStarts.first,fastReportStarts:fastRate == nil ? nil : reportStarts,fastReportRate:fastRate ?? 1.0)
        voice.farnsworthKeyer=farnsworthKeyer
        let duration=voiceSeconds(voice)
        callerTransmitRanges[st.call,default:[]].append((due,due+duration))
        let event=RadioEvent(.receive,message,calls:[st.call],reason:reason,at:due,voices:[voice])
        if startingAt == nil {schedule(due,.received(event))}
        else {events.append(event)}
        st.rfBusyUntil=due+duration
        // evMsgSent: the reply timeout starts when this transmission ends.
        let timeout=replyTimeout(&st)
        st.nextAction=due+duration+timeout
        pileup[index]=st
    }
    private func schedule(_ due:Double,_ action:Scheduled.Action) {
        scheduledFIFO += 1
        scheduled.append(Scheduled(due:due,sequence:eventSequence,fifo:scheduledFIFO,action:action))
    }
    private func voiceSeconds(_ voice:RadioVoice) -> Double {
        MorseTimeline.duration(voice.message,wpm:voice.wpm,characterWpm:max(voice.wpm,voice.characterWpm),
                               fastReportRate:voice.fastReportRate,fastReportStarts:voice.effectiveFastReportStarts,
                               farnsworthKeyer:voice.farnsworthKeyer)
    }
    /// MRCE creates its Farnsworth keyer for SST and uses it for every
    /// station in that contest; all other contests use the standard keyer.
    private var farnsworthKeyer:Bool? { settings.contest == .sst ? true : nil }
    /// `TMyStation.SetWpm`: in a Farnsworth contest (SST) the operator's own
    /// characters are keyed at the Farnsworth character rate when it is
    /// above the sending speed, with the spacing stretched to match.
    private var ownCharacterWpm:Int {
        settings.contest == .sst ? max(settings.wpm,settings.farnsworthCharRate) : settings.wpm
    }
    enum ReplyCause {case timeout, call, partial, repeatMessage, nr, corrected}
    /// MRCE skill-dependent Gaussian operator patience in audio blocks.
    private func replyTimeout(_ st:inout Station) -> Double {
        let blocksPerSecond=11025.0/512.0
        let mean=settings.mode == .hstCompetition ? 60.0/Double(settings.wpm) : Double(6-st.skill)
        let blocks=(mean*blocksPerSecond).rounded()
        return max(1,stationGaussian(&st,blocks,blocks/2).rounded())/blocksPerSecond
    }
    /// MRCE increments the operator's serial only when its sent exchange
    /// fields include that serial. Comparing adjacent rendered values also
    /// honors custom templates and ARRL 10m's location-dependent exchange.
    private var ownSerialAffectsSentExchange:Bool {
        ContestRules.sentExchange(settings,ownSerial:ownSerialCounter.value) !=
            ContestRules.sentExchange(settings,ownSerial:ownSerialCounter.value+1)
    }
    private func stationRandom(_ station: inout Station) -> Double {
        var stream=ContestRNG(seed:station.behaviorRNGState)
        let value=stream.random();station.behaviorRNGState=stream.state
        return value
    }
    private func stationInt(_ station: inout Station,_ minimum:Int,_ maximum:Int) -> Int {
        var stream=ContestRNG(seed:station.behaviorRNGState)
        let value=stream.int(minimum,maximum);station.behaviorRNGState=stream.state
        return value
    }
    private func stationGaussian(_ station: inout Station,_ center:Double,_ limit:Double) -> Double {
        var stream=ContestRNG(seed:station.behaviorRNGState)
        let value=stream.gaussian(center,limit);station.behaviorRNGState=stream.state
        return value
    }
    private func resetOperatorState(_ st:inout Station,_ state:OperatorState) {
        let old=st.opState
        let preserve=(old == .needCallNr || old == .needEnd) && state == .needCall
        if old != state && !preserve {st.incomplete=0}
        st.opState=state;st.ghosting=false;st.silentTimeouts=0
        if state == .needQso {
            st.repeatCount=[SessionMode.single,.hstCompetition].contains(settings.mode) ? 1 : (stationRandom(&st)<0.1 ? 2 : 1)
            st.sentCall=Array(repeating:st.call,count:st.repeatCount).joined(separator:" ")
            st.correctedCallAndExchSent=false
        }
        if state == .needQso {
            let first=max(1e-9,stationRandom(&st)),second=max(1e-9,stationRandom(&st))
            st.patience=Self.rayleighPatience(first:first,second:second)
        } else {st.patience=5}
        if state == .needNr {st.sendNrQuestionCount=0}
        if ![OperatorState.needCall,.needCallNr,.needEnd].contains(state) && st.qrsStage > 0 {
            st.wpm=st.baseWpm;st.characterWpm=max(st.wpm,settings.contest == .sst ? settings.farnsworthCharRate : st.wpm)
            st.qrsStage=0
        }
        let timeout=replyTimeout(&st)
        st.nextAction=max(clock,txBusyUntil)+timeout
    }
    private func morePatience(_ st:inout Station,explicit:Int=0) {
        if [.failed,.done].contains(st.opState) {return}
        if explicit>0 {st.patience=min(5,explicit)}
        else if st.patience<5 {st.patience=settings.mode == .single ? 4 : st.patience==0 ? 3 : min(4,st.patience+2)}
        st.ghosting=st.patience==0
    }
    private func incomplete(_ st:inout Station) {
        st.incomplete+=1
    }
    private func applyQrsIfEligible(_ st:inout Station) {
        // MRCE only slows callers while they are still transmitting the
        // opening call, number, or closing exchange. QRS is unavailable with
        // LIDs enabled and in HST competition, regardless of the saved toggle.
        guard settings.callerQrs, !settings.effects.lids,
              settings.mode != .hstCompetition,
              [.needNr,.needCall,.needCallNr,.needEnd].contains(st.opState),
              st.incomplete >= (st.skill==3 ? 4 : 3) else {return}
        let reduction=(st.skill==1 ? 0.20 : st.skill==2 ? 0.16 : 0.12)+(st.incomplete>=4 ? 0.02 : 0)
        let base=st.baseWpm
        let rounded=Int((Double(base)*(1-reduction)).rounded(.toNearestOrEven))
        st.wpm=max(5,rounded == base && base > 5 ? base-4 : rounded)
        if settings.contest == .sst {
            let baseChar=max(base,settings.farnsworthCharRate)
            let characterTarget=st.skill==3 ? baseChar : Int((Double(baseChar)*(1-reduction/2)).rounded(.toNearestOrEven))
            st.characterWpm=max(st.wpm,characterTarget)
        }else {st.characterWpm=st.wpm}
        st.qrsStage=st.incomplete
    }
    func decrementPatience(_ st:inout Station,silent:Bool=false) {
        guard ![OperatorState.done,.failed,.needPrevEnd].contains(st.opState) else {return}
        st.silentTimeouts=silent ? st.silentTimeouts+1 : 0
        if st.patience>0 {st.patience-=1}
        if st.patience==0 {
            if st.opState == .needQso {st.opState = .failed;return}
            if (settings.callerStays || settings.mode == .hstCompetition) && st.silentTimeouts<3 && [.needCall,.needCallNr,.needEnd].contains(st.opState) {
                morePatience(&st,explicit:1)
            } else if [.needCall,.needCallNr,.needEnd].contains(st.opState) {
                st.opState = .failed;st.ghosting=false
            } else {st.ghosting=true}
            // Pinned MRCE exits before QRS when patience remains at zero.
            guard st.patience > 0 else {return}
        }
        // MRCE evaluates QRS after patience handling.
        applyQrsIfEligible(&st)
    }
    private func operatorReply(_ st:inout Station,cause:ReplyCause) -> String {
        var stream=ContestRNG(seed:st.behaviorRNGState)
        let response=OperatorReplyPolicy.reply(&st, cause:cause, mode:settings.mode, contest:settings.contest,
                                               lids:settings.effects.lids,
                                               operatorName:settings.exchangeProfile().name.uppercased().trimmingCharacters(in:.whitespaces),
                                               nextRandom:{stream.random()})
        st.behaviorRNGState=stream.state
        return response
    }

    enum OperatorReplyPolicy {
        /// MRCE contest overrides of `msgNrQm` (`ArrlFd.pas`, `CWSST.pas`),
        /// chosen by the station's stable R1 draw.
        static func numberQuestion(_ st:Station,contest:ContestID) -> String {
            switch contest {
            case .sst: return ["NR?","NR?","NAME?","ST?"][min(3,Int(st.stationDraw*4))]
            case .fieldday: return ["NR?","NR?","SECT?","CLASS?","CL?"][min(4,Int(st.stationDraw*5))]
            default: return "NR?"
            }
        }
        /// What precedes the exchange in `msgR_NR`/`msgR_NR2`. CWT drops the
        /// R nine times in ten (`CWOPS.pas`); SST sends it one time in ten and
        /// adds a greeting one time in five (`CWSST.pas`).
        static func acknowledgementPrefix(_ st:inout Station,contest:ContestID,operatorName:String,
                                          nextRandom:() -> Double) -> String {
            switch contest {
            case .cwt: return nextRandom()<0.9 ? "" : "R "
            case .sst:
                var prefix=nextRandom()<0.10 ? "R " : ""
                if nextRandom()<0.20 {
                    if st.sstGreeting == nil {
                        // `GreetingAsText`: chosen once per station; one in ten is empty.
                        let pick=min(9,Int(nextRandom()*10))
                        let word=pick<3 ? "GM" : pick<6 ? "GA" : pick<9 ? "GE" : ""
                        st.sstGreeting=word.isEmpty || operatorName.isEmpty ? "" : "\(word) \(operatorName) "
                    }
                    prefix+=st.sstGreeting ?? ""
                }
                return prefix
            default: return "R "
            }
        }
        static func reply(_ st:inout Station,cause:ReplyCause,mode:SessionMode,contest:ContestID,lids:Bool,
                          operatorName:String="",nextRandom:() -> Double) -> String {
            guard !st.ghosting && st.patience>0 else {return ""}
            let style=st.replyStyle
            // Each `ex` use is one MRCE `<#>` expansion: the first carries a pending LID
            // serial error, later ones are clean. Hand-built stations stay canonical.
            let canonical=st.transmittedExchange.isEmpty ? st.exchange : st.transmittedExchange
            func exchangeText(_ st:inout Station) -> String {
                st.exchangeRNGState == 0 ? canonical : CallerExchangeText.render(&st,contest:contest,mode:mode)
            }
            switch st.opState {
            case .needQso: return st.sentCall
            case .needNr:
                // MRCE's OR expression short-circuits at patience four, so
                // neither the post-increment counter check nor its RNG
                // fallback runs for this forced NR? reply.
                if st.patience == 4 { return numberQuestion(st,contest:contest) }
                let previous=st.sendNrQuestionCount;st.sendNrQuestionCount+=1
                return previous%3==0 || nextRandom()<0.2 ? numberQuestion(st,contest:contest) : "AGN"
            case .needCallNr:
                if mode == .hstCompetition {return "DE \(st.call)"}
                if style < 1.0/6 {return "DE \(st.call)"}
                if style < 2.0/6 {return "DE \(st.call) \(st.call)"}
                if style < 4.0/6 {return st.call}
                if style < 5.0/6 {return "\(st.call) \(st.call)"}
                if lids && style < 0.88 {st.correctedCallAndExchSent=true;return "\(st.call) \(exchangeText(&st))"}
                return style < 0.95 ? st.call : "\(st.call) \(st.call)"
            case .needCall:
                if mode == .hstCompetition {return "DE \(st.call) \(exchangeText(&st))"}
                if contest == .sweepstakes {return style < 1.0/3 ? "DE \(st.call) \(exchangeText(&st))" : "\(st.call) \(exchangeText(&st))"}
                if style < 1.0/6 {return "DE \(st.call) \(exchangeText(&st))"}
                if style < 2.0/6 {return "DE \(st.call) \(st.call) \(exchangeText(&st))"}
                if style < 4.0/6 {return "\(st.call) \(exchangeText(&st))"}
                if style < 5.0/6 {return "\(st.call) \(st.call) \(exchangeText(&st))"}
                return st.call
            case .needEnd:
                if st.patience<4 {return exchangeText(&st)}
                let single=mode == .hstCompetition || contest == .sweepstakes || nextRandom()<0.9
                let prefix=acknowledgementPrefix(&st,contest:contest,operatorName:operatorName,nextRandom:nextRandom)
                if single {return "\(prefix)\(exchangeText(&st))"}
                let first=exchangeText(&st);return "\(prefix)\(first) \(exchangeText(&st))"
            default:return ""
            }
        }
    }
    #if DEBUG
    internal func fixtureMakeStation() -> Station {makeStation()}
    internal func fixtureCallerRNGSequence(interactWithOtherStation:Bool) -> (String,Double,UInt32,UInt32,String) {
        var first=makeStation(),second=makeStation()
        first.opState = .needNr;first.patience=3;first.sendNrQuestionCount=1
        second.opState = .needNr;second.patience=3;second.sendNrQuestionCount=1
        pileup=[first,second]
        if interactWithOtherStation {
            _ = operatorMessage(0,input:.exchange)
            _ = operatorReply(&pileup[0],cause:.timeout)
            _ = replyTimeout(&pileup[0])
        }
        let response=operatorReply(&pileup[1],cause:.timeout)
        let timeout=replyTimeout(&pileup[1])
        return (response,timeout,pileup[1].behaviorRNGState,rng.state,pileup[1].call)
    }

    internal func fixtureOperatorTransition(_ station:Station,input:OperatorInput,confidence:Int,active:Bool=true) -> Station {
        var station=station
        if station.behaviorRNGState == 0 {station.behaviorRNGState=rng.state}
        pileup=[station];targetCall=station.call
        activeQSOCalls=active ? [station.call] : []
        _ = operatorMessage(0,input:input,typed:"K1AB",knownConfidence:confidence)
        return pileup[0]
    }
    internal func fixtureOperatorTransitionTrace(_ station:Station,input:OperatorInput,confidence:Int) -> (Station,[OperatorFSM.Effect]) {
        var station=station
        if station.behaviorRNGState == 0 {station.behaviorRNGState=rng.state}
        pileup=[station];targetCall=station.call;activeQSOCalls=[station.call]
        var copy=station
        let result=operatorFSMTransition(input,station:&copy,typed:"K1AB",knownConfidence:confidence)
        pileup[0]=copy
        return (copy,result.effects)
    }
    #if DEBUG
    internal func fixtureSetStationIDCount(_ count:Int) {qsosSinceStationID=max(0,count)}
    internal func fixtureStationIDCount() -> Int {qsosSinceStationID}
    internal func fixtureDropInstantNIL(_ stations:[Station],transmittingCalls:Set<String>=[]) -> [Station] {
        pileup=stations;targetCall=nil
        callerTransmitRanges=Dictionary(uniqueKeysWithValues:transmittingCalls.map{($0,[(clock,clock+10)])})
        dropNil()
        return pileup
    }
    internal func fixtureScheduleReceive(_ event:RadioEvent,due:Double) { schedule(due,.received(event)) }
    internal func fixtureScheduledReceives() -> [RadioEvent] { scheduled.compactMap { if case let .received(event) = $0.action {return event};return nil } }
    internal func fixtureSentFlags() -> (call:Bool,exchange:Bool) {(callSent,numberSent)}
    internal func fixtureCallerTransmitRanges(_ call:String) -> [(start:Double,end:Double)] {callerTransmitRanges[call] ?? []}
    internal var fixtureClock:Double {clock}
    internal func fixtureSetTargetCall(_ call:String?) {targetCall=call}
    internal func fixtureSetOperatorState(_ call:String,_ state:OperatorState,
                                          correctedCallAndExchSent:Bool=false) {
        guard let index=pileup.firstIndex(where:{$0.call==call}) else {return}
        pileup[index].opState=state
        pileup[index].correctedCallAndExchSent=correctedCallAndExchSent
        targetCall=call
        activeQSOCalls.insert(call)
    }
    internal func fixtureDrawCallerCalls(_ count:Int) -> [String] {
        (0..<max(0,count)).map{_ in makeStation().call}
    }
    internal func fixtureArrivalDecision(draw:Int) {applyArrivalDraw(draw)}
    internal var fixtureArrivalInactivityCount:Int {lastArrival}
    #endif
    #endif
    #if DEBUG
    /// Regression-only entry point for source-generated operator-reply fixtures.
    /// This symbol is excluded from optimized iOS and WebAssembly releases.
    internal func fixtureOperatorReply(_ station:Station,corrected:Bool) -> (String,Station) {
        var copy=station
        let result=operatorReply(&copy,cause:corrected ? .corrected : .timeout)
        return (result,copy)
    }
    #endif
    private func operatorSays(_ index:Int,_ message:String,reason:String="dialogue",startingAt:Double?=nil) {
        guard pileup.indices.contains(index),!message.isEmpty,!pileup[index].ghosting,pileup[index].patience>0 else {return}
        pileup[index].lastReply=message;pileup[index].replyCount+=1
        queueTransmission(index,message,reason:reason,startingAt:startingAt)
    }
    private func matchWithLids(_ typed:String,_ st:inout Station) -> Int {
        var confidence=confidence(typed,st.call)
        if !settings.effects.lids || typed.count<=3 || typed.contains("?") {return confidence}
        if confidence==100 && stationRandom(&st)<0.01 {confidence=max(2,100*(st.call.count-1)/st.call.count)}
        else if confidence>0 && confidence<100 && stationRandom(&st)<0.04 {confidence=100}
        return confidence
    }
    @discardableResult private func operatorMessage(_ index:Int,input:OperatorInput,typed:String="",knownConfidence:Int?=nil) -> OperatorFSM.Result {
        guard pileup.indices.contains(index),![OperatorState.failed,.done].contains(pileup[index].opState) else {return .rejected}
        if callerTransmitRanges[pileup[index].call,default:[]].contains(where:{$0.start<=clock && clock<$0.end}),
           !(OperatorFSM.mayInterruptTransmit(input,state:pileup[index].opState)) {return .rejected}
        return operatorMessage(index,inputs:[input],typed:typed,knownConfidence:knownConfidence)
    }
    /// Runs one burst's message set through the caller's `MsgReceived`.
    @discardableResult private func operatorMessage(_ index:Int,inputs:Set<OperatorInput>,typed:String="",knownConfidence:Int?=nil) -> OperatorFSM.Result {
        guard pileup.indices.contains(index),![OperatorState.failed,.done].contains(pileup[index].opState) else {return .rejected}
        var station = pileup[index]
        let transition = operatorFSMTransition(inputs,station:&station,typed:typed,knownConfidence:knownConfidence)
        pileup[index]=station
        return transition
    }
    private func operatorFSMTransition(_ input:OperatorInput,station:inout Station,typed:String,knownConfidence:Int?) -> OperatorFSM.Result {
        operatorFSMTransition([input],station:&station,typed:typed,knownConfidence:knownConfidence)
    }
    private func operatorFSMTransition(_ inputs:Set<OperatorInput>,station:inout Station,typed:String,knownConfidence:Int?) -> OperatorFSM.Result {
        OperatorFSM.transition(
            inputs:inputs, station:&station, typed:typed, knownConfidence:knownConfidence,
            settings:settings, selectedCallIsEmpty:selectedCall.isEmpty,
            selectedForQSO:activeQSOCalls.contains(station.call),
            matchCall:{ typed, station in self.matchWithLids(typed,&station) },
            reset:{ station, state in self.resetOperatorState(&station,state) },
            decrement:{ station in self.decrementPatience(&station) },
            morePatience:{ station in self.morePatience(&station) },
            markIncomplete:{ station in self.incomplete(&station) },
            acceptExchange:{ station in
                [.single,.hstCompetition].contains(self.settings.mode) || self.stationRandom(&station)<0.9
            }
        )
    }

    private func sendCq() {
        let own=ContestRules.normalizeCall(settings.myCall)
        let prefix:[ContestID:String]=[.pota:"CQ POTA",.cwt:"CQ CWT",.fieldday:"CQ FD",.sst:"CQ SST",.sweepstakes:"CQ SS"]
        sendTx("\(prefix[settings.contest] ?? "CQ") \(own)\(prefix[settings.contest] == nil ? " TEST" : "")",kinds:[.cq])
    }
    /// `OnMeFinishedSending`: the arrival draw, `FindBestMatches`, then every
    /// station hears the burst once. `kinds` is the whole burst's message set.
    private func finishBurst(kinds:Set<OperatorInput>) {
        burstOpen=false
        let typed=burstTypedCall,tuCall=burstTUCall,completesQSO=burstCompletesQSO
        burstKinds=[];burstTypedCall="";burstTUCall="";burstCompletesQSO=false
        let wasSending=sendingAtBurstStart
        sendingAtBurstStart=[]
        let hadCQ=kinds.contains(.cq),hadTU=kinds.contains(.tu)
        // Reset the station-ID counter after a CQ or a TU that carried the ID.
        if hadCQ {qsosSinceStationID=0}
        else if hadTU,settings.stationIdRate > 0,qsosSinceStationID >= settings.stationIdRate {qsosSinceStationID=0}
        // The stations heard my CQ (or the end of a QSO) and want to call.
        var arrivalDrawn=false,arrivals:[Station]=[]
        if ![.single,.hstCompetition].contains(settings.mode),remaining > 0,
           hadCQ || (!log.isEmpty && (hadTU || kinds.contains(.myCall))) {
            arrivalDrawn=true
            let draw=rng.poisson(Double(settings.activity)/2.0)
            // The QSO that just finished is still in the pile; MRCE deducts it.
            let active=pileup.filter({$0.opState != .done && $0.opState != .failed}).count
            arrivals=applyArrivalDraw(draw,existing:hadCQ ? active : max(0,active-1))
        }
        // Update every caller's confidence metric for the call just keyed.
        var match:BestMatch?
        if kinds.contains(.call) {match=findBestMatches(typed)}
        var delivered=kinds
        if settings.nilInstant && kinds.contains(.nilInput) {
            dropNil()
            // MRCE keeps the NIL for the drop and shows everyone else garbage.
            delivered=[.garbage]
        }
        var responders:[Int]=[]
        for call in pileup.map(\.call) {
            guard let index=pileup.firstIndex(where:{$0.call==call}),pileup[index].opState != .done else {continue}
            let st=pileup[index]
            if isOnAir(call) {
                // Still sending: the burst is ignored, except that a caller
                // waiting for a call correction accepts TU and finishes.
                if st.opState == .needCall && hadTU {
                    operatorMessage(index,inputs:delivered,typed:typed,knownConfidence:match.map{$0.known(call)})
                }
                if let end=callerTransmitRanges[call]?.map(\.end).max(),pileup[index].opState != .done {
                    let timeout=replyTimeout(&pileup[index])
                    pileup[index].nextAction=end+timeout
                }
                continue
            }
            // A station that was still sending when the burst started missed
            // most of it: only CQ, TU and NIL are copied from a partial.
            let heard:Set<OperatorInput> = wasSending.contains(call) && delivered.isDisjoint(with:[.cq,.tu,.nilInput]) ? [.garbage] : delivered
            operatorMessage(index,inputs:heard,typed:typed,knownConfidence:heard == [.garbage] ? nil : match.map{$0.known(call)})
            if pileup[index].opState == .failed {continue}
            if pileup[index].ghosting {pileup[index].nextAction=0;continue}
            let message=operatorReply(&pileup[index],cause:.timeout)
            if message.isEmpty {pileup[index].nextAction=0;continue}
            pileup[index].lastReply=message
            responders.append(index)
        }
        let responderCalls=responders.map{pileup[$0].call}
        for call in responderCalls {
            guard let index=pileup.firstIndex(where:{$0.call==call}) else {continue}
            let reason:String
            if kinds.contains(.question) || kinds.contains(.numberQuestion) {reason="repeat"}
            else if kinds == [.exchange] {reason="exchange"}
            else if pileup[index].opState == .needQso {reason="pileup"}
            else {reason="dialogue"}
            operatorSays(index,pileup[index].lastReply,reason:reason)
        }
        if let match,match.confidence > 0,kinds.contains(.call) {announceCall(match,typed:typed,exchangeSent:kinds.contains(.exchange))}
        if kinds.contains(.numberQuestion) || kinds.contains(.question),let call=responderCalls.first,let index=pileup.firstIndex(where:{$0.call==call}) {
            emit(.notice,pileup[index].qrsStage > 0 ? "Caller repeated at a slower speed." : "Caller repeated the requested information.")
        }
        if hadTU,!tuCall.isEmpty,let index=pileup.firstIndex(where:{$0.call==tuCall}) {
            emit(.notice,pileup[index].opState == .done ? "\(tuCall) acknowledged TU." : "\(tuCall) did not accept TU; contact remains active.")
        }
        if kinds.contains(.b4) {emit(.notice,"QSO B4 sent.")}
        if kinds.contains(.nilInput) && !settings.nilInstant {emit(.notice,"NIL sent.")}
        if hadCQ || hadTU {reconcilePendingQSOs()}
        if hadCQ {
            activeQSOCalls.removeAll()
            pileup.removeAll(where:{$0.opState == .failed || $0.opState == .done})
        }
        pileup.removeAll(where:{$0.opState == .failed})
        if let targetCall,!pileup.contains(where:{$0.call==targetCall}) {self.targetCall=nil;phase = .listening}
        switch settings.mode {
        case .single: if hadCQ {refillAutomatic(1)} else {scheduleSingleCallerIfNeeded()}
        case .hstCompetition: if hadCQ || completesQSO {refillAutomatic(hstCallerTarget)}
        default:break
        }
        if !arrivals.isEmpty {emit(.notice,"\(arrivals.count) new station(s) calling.")}
        if completesQSO {phase = pileup.isEmpty ? .ready : .listening}
        else if (hadCQ || arrivalDrawn) && !pileup.isEmpty && !responders.isEmpty {phase = .listening}
        if arrivalDrawn && hadCQ && responders.isEmpty && pileup.isEmpty {emit(.notice,"No answer. Try CQ again.")}
    }
    /// MRCE `TStations.FindBestMatches`: the best confidence for the call the
    /// operator keyed. `active` stations meet it; `known` is the per-station
    /// confidence handed to `MsgReceived` (zero for stations outside the QSO).
    private struct BestMatch {
        var call:String, confidence:Int, active:Set<String>, confidences:[String:Int]
        var tied:[String]
        func known(_ call:String) -> Int { active.contains(call) ? confidences[call] ?? 0 : 0 }
    }
    private func findBestMatches(_ typed:String) -> BestMatch {
        let normalized=ContestRules.normalizeCall(typed)
        let candidates=pileup.indices.map { index in
            var station=pileup[index]
            let matched=matchWithLids(normalized,&station)
            pileup[index]=station
            return (station.call,matched,index,normalized==station.call)
        }.sorted {
            if $0.1 != $1.1 {return $0.1 > $1.1}
            if $0.3 != $1.3 {return $0.3}
            return $0.2 < $1.2
        }
        let confidences=Dictionary(uniqueKeysWithValues:candidates.map{($0.0,$0.1)})
        let best=candidates.first
        let bestConfidence=best?.1 ?? 0
        bestMatchCallConfidence=max(1,bestConfidence)
        let active=Set(candidates.filter{$0.1 >= max(1,bestConfidence)}.map(\.0))
        let tied=candidates.prefix(while:{$0.1 == bestConfidence && bestConfidence > 0}).map(\.0)
        activeQSOCalls=active
        if let best,best.1 > 0 {targetCall=best.0;phase = .copy}
        return BestMatch(call:best?.0 ?? "",confidence:bestConfidence,active:active,confidences:confidences,tied:tied)
    }
    /// Learning-aid and presentation hooks that follow a keyed call. These do
    /// not feed back into any caller's behaviour except the history hint draw.
    private func announceCall(_ match:BestMatch,typed:String,exchangeSent:Bool) {
        if match.tied.count > 1 && match.confidence < 100 {
            emit(.notice,"Several callers match the partial. Copy their complete callsign.");return
        }
        guard !typed.contains("?"),exchangeSent,pileup.contains(where:{$0.call==match.call}) else {return}
        let call=match.call
        if settings.contest == .sweepstakes && settings.showCheckSection>0 && hintRng.random()*100<Double(settings.showCheckSection),
           let history=settings.contestHistories["sweepstakes"],history.calls.contains(call),
           let record=history.records[call],!record.check.isEmpty && !record.section.isEmpty {
            // Independent 10% check corruption and adjacent section substitution.
            var check=Int(record.check) ?? 0,section=record.section
            if hintRng.random()<0.1 {
                check=(check+(hintRng.random()<0.5 ? 1 : 99))%100
            }
            let sections=SweepstakesParser.orderedSections
            if let offset=sections.firstIndex(of:section),hintRng.random()<0.1 {
                let step=offset==0 ? 1 : offset==sections.count-1 ? -1 : hintRng.random()<0.5 ? -1 : 1
                section=sections[offset+step]
            }
            emit(.notice,"History hint for \(call): \(String(format:"%02d",check)) \(section)")
        }
        emit(.notice,match.confidence == 100 ? "\(call) responded. Copy the exchange." : "Partial call: station is correcting its callsign.")
    }
    @discardableResult private func sendCall(_ text:String) -> Bool {
        let call=ContestRules.normalizeCall(text)
        guard !call.isEmpty else {emit(.notice,"Type a callsign first.");return false}
        // A lone ? is MRCE's question-mark repeat macro, not an operator call.
        if call == "?" {selectedCall="";sendRepeat(.question,message:"?");return false}
        activeQSOCalls.removeAll()
        selectedCall=call
        // The keyer always sends what was asked, whether or not any caller
        // matches (MRCE does not look at hidden station state when keying).
        // A partial copy goes out alone, as an on-air correction request.
        let complete = !call.contains("?")
        // MRCE sends `<his>` and the exchange as separate keyer pieces.
        sendTx(call,kinds:[.call],call:call,containsCall:true)
        if complete {sendExchange()}
        return complete
    }
    private func sendHisCall(_ text:String) {
        let typed=ContestRules.normalizeCall(text.isEmpty ? (selectedCall.isEmpty ? (targetCall ?? "") : selectedCall) : text)
        guard !typed.isEmpty else {emit(.notice,"Type a callsign first.");return}
        if typed == "?" {sendRepeat(.question,message:"?");return}
        activeQSOCalls.removeAll()
        selectedCall=typed
        sendTx(typed,kinds:[.call],call:typed,containsCall:true)
    }
    private func sendExchange() {
        sendTx(onAirOwnExchange(),kinds:[.exchange],containsExchange:true)
    }
    /// The operator's exchange as keyed. MRCE `NrAsText` puts two spaces
    /// between the CWT name and number, which the keyer sends as a wider gap.
    private func onAirOwnExchange() -> String {
        CallerExchangeText.renderOwn(ContestRules.sentExchange(settings,ownSerial:ownSerialCounter.value),
                                     settings:settings,r1:homeFastReportR1)
    }
    /// MRCE's TU macro is a radio message only. The operator may accept or
    /// reject it after the complete transmission reaches the station.
    private func sendTU(completesQSO:Bool=false,rowID:Int?=nil) {
        let message:String
        var kinds:Set<OperatorInput>=[.tu]
        // CWSST.pas overrides msgTU: SST always signs with the call.
        if settings.contest == .sst ||
           ([.pileup,.wpxCompetition].contains(settings.mode) && settings.stationIdRate > 0 &&
            qsosSinceStationID >= settings.stationIdRate-1) {
            message="TU \(ContestRules.normalizeCall(settings.myCall))"
            kinds.insert(.myCall)
        } else {message="TU"}
        sendTx(message,kinds:kinds,completesQSO:completesQSO)
    }
    /// Finalizes provisional rows whose station has finished (or left). A row
    /// stays provisional while its caller is still in the QSO: a later TU that
    /// the station accepts completes it (MRCE fills the last log entry when
    /// the station reaches osDone). `force` adjudicates everything, at the end.
    private func reconcilePendingQSOs(force:Bool=false) {
        let ready=pendingQSOEntries.keys.sorted().filter { pendingID in
            guard let pending=pendingQSOEntries[pendingID] else {return false}
            if force {return true}
            guard let live=pileup.first(where:{$0.call==pending.station.call}) else {return true}
            return live.opState == .done || live.opState == .failed
        }
        for pendingID in ready {
            guard let pending=pendingQSOEntries[pendingID] else {continue}
            var station=pileup.first(where:{$0.call==pending.station.call}) ?? pending.station
            if !pileup.contains(where:{$0.call==pending.station.call}) {station.opState = .failed}
            if saveQSO(call:pending.call,exchange:pending.exchange,rowID:pendingID,stationSnapshot:station,allowBlankExchange:pending.allowBlankExchange) != nil {
                pendingQSOEntries.removeValue(forKey:pendingID)
            }
        }
    }
    private func sendRepeat(_ kind:OperatorInput,message:String) {
        sendTx(message,kinds:[kind])
    }
    private func dropNil() {
        if settings.nilInstant {
            let active=pileup.filter{[.needNr,.needCall,.needCallNr,.needEnd].contains($0.opState)}
            let transmitting=pileup.filter { station in
                return callerTransmitRanges[station.call,default:[]].contains(where:{$0.start<=clock && clock<$0.end})
            }
            let waiting=pileup.filter{[.needQso,.needPrevEnd].contains($0.opState)}
            let pool = !active.isEmpty ? active : !transmitting.isEmpty ? transmitting : waiting
            if let strongest=pool.max(by:{($0.rfAmplitude ?? $0.volume)<($1.rfAmplitude ?? $1.volume)}) {
                let selectedCall=strongest.call
                scheduled = scheduled.compactMap { item in
                    guard case let .received(event) = item.action else { return item }
                    let voices=event.voices.filter{$0.call != selectedCall}
                    guard !voices.isEmpty else { return nil }
                    var filtered=event;filtered.voices=voices;filtered.stationCalls=voices.map(\.call)
                    return Scheduled(due:item.due,sequence:item.sequence,fifo:item.fifo,action:.received(filtered))
                }
                pileup.removeAll(where:{$0.call==selectedCall});if targetCall==selectedCall {targetCall=nil;phase = .listening}
                events.append(RadioEvent(.cancelReceive,"",calls:[selectedCall],reason:"NIL",at:clock))
                if !active.isEmpty || settings.mode == .single {emit(.notice,"NIL: skipped \(strongest.call).")}
                scheduleSingleCallerIfNeeded()
            }
        }
    }
    public func logQSO(call:String,exchange:String) -> QSOEntry? {
        guard running else {return nil}
        guard !call.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            emit(.notice,"Enter a valid callsign before saving.",noticeCode:.callInvalid)
            return nil
        }
        guard Self.validSavedCall(call) != nil,
              !exchange.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            emit(.notice,"Fill in CALL and RECEIVED.")
            return nil
        }
        // MRCE's SaveQso does not need a selected caller: it looks for a
        // station that matches the typed call, and an unmatched row is NIL.
        guard let st=savedStation(for:call) else {
            guard let entry=saveUnmatchedQSO(call:call,exchange:exchange) else {return nil}
            sendTU(completesQSO:true)
            return entry
        }
        let rowID=allocateQSOEntryID()
        let provisional=provisionalQSO(call:call,exchange:exchange,station:st,rowID:rowID)
        log.insert(provisional,at:0)
        pendingQSOEntries[rowID]=PendingQSOEntry(call:call,exchange:exchange,station:st)
        clearEntryState()
        // MRCE `ShouldDrainEndSessionQso`: a contact whose TU is still being
        // sent when time runs out gets up to 15 s to complete.
        sessionDrainUntil=clock+15
        sendTU(completesQSO:true,rowID:rowID)
        return provisional
    }
    /// The selected caller, else the newest station whose call matches the typed
    /// one well enough (MRCE SaveQso scans stations by call confidence).
    private func savedStation(for call:String) -> Station? {
        if let target {return target}
        let typed=ContestRules.normalizeCall(call)
        return pileup.reversed().first(where:{
            let score=confidence(typed,$0.call)
            return score == 100 || score >= bestMatchCallConfidence
        })
    }
    /// MRCE clears CallSent/NrSent and the entry fields when SaveQso runs.
    private func clearEntryState() {
        selectedCall="";received=""
        callSent=false;numberSent=false;callSentValue=""
    }
    /// A saved contact that no station claims: logged but NIL, zero points.
    private func saveUnmatchedQSO(call:String,exchange:String) -> QSOEntry? {
        guard var copied=Self.validSavedCall(call,stripWildcards:true) else {
            emit(.notice,"Enter a valid callsign before saving.",noticeCode:.callInvalid);return nil
        }
        var rx=exchange.uppercased().trimmingCharacters(in:.whitespacesAndNewlines)
        if settings.contest == .sweepstakes {
            let parsed=SweepstakesParser.parse(call:copied,exchange:rx)
            if parsed.complete {copied=parsed.call;rx="\(parsed.serial) \(parsed.precedence) \(parsed.correctedCall.isEmpty ? "" : parsed.correctedCall+" ")\(parsed.check) \(parsed.section)"}
        }
        let raw=ContestRules.score(settings,station:Station(call:copied,exchange:rx,wpm:settings.wpm,tone:0,volume:0,shift:0))
        rawPoints+=raw.points;rawMultipliers.formUnion(raw.multipliers)
        let entry=QSOEntry(id:allocateQSOEntryID(),at:clock,call:copied,copiedCall:copied,
                           sent:ContestRules.sentExchange(settings,ownSerial:ownSerialCounter.value),received:rx,expected:"",
                           correct:false,points:0,multipliers:[],note:"NIL — station did not log this call",dupe:false,
                           callError:true,exchangeErrors:[],wpm:settings.wpm)
        log.insert(entry,at:0)
        if ownSerialAffectsSentExchange {ownSerialCounter.advanceAfterSavedContact()}
        sessionDrainUntil=clock+15
        qsosSinceStationID += 1
        clearEntryState()
        return entry
    }
    private func allocateQSOEntryID() -> Int {
        let id=nextQSOEntryID
        nextQSOEntryID += 1
        return id
    }
    private func saveOnlyQSO(call:String,exchange:String) {
        // MRCE SaveQso removes wildcard markers, then scans stations newest
        // to oldest. Exact calls always match; mcAlmost must meet the prior
        // call-match confidence threshold.
        guard let copied=Self.validSavedCall(call,stripWildcards:true) else {
            emit(.notice,"Enter a valid callsign before saving.",noticeCode:.callInvalid);return
        }
        var associationCall=copied
        if settings.contest == .sweepstakes {
            let parsed=SweepstakesParser.parse(call:copied,exchange:exchange)
            if parsed.complete {associationCall=parsed.call}
        }
        guard let station=pileup.reversed().first(where:{
            let score=confidence(associationCall,$0.call)
            return score == 100 || score >= bestMatchCallConfidence
        }) else {emit(.notice,"Select a caller before logging.");return}
        guard let entry=saveQSO(call:copied,exchange:exchange,stationSnapshot:station,allowBlankExchange:true) else {return}
        if station.opState != .done {
            pendingQSOEntries[entry.id]=PendingQSOEntry(call:copied,exchange:exchange,station:station,allowBlankExchange:true)
        }
    }
    private static func validSavedCall(_ rawCall:String,stripWildcards:Bool=false) -> String? {
        let trimmed=rawCall.trimmingCharacters(in:.whitespacesAndNewlines)
        let candidate=stripWildcards ? trimmed.replacingOccurrences(of:"?",with:"") : trimmed
        guard !candidate.isEmpty,
              candidate.unicodeScalars.allSatisfy({scalar in
                  scalar.isASCII && (CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == "/")
              }) else {return nil}
        let normalized=candidate.uppercased()
        return Self.isValidCall(normalized) ? normalized : nil
    }
    /// MRCE `CallsignUtils.IsValidCall`: the call must contain a match for
    /// `(([0-9][A-Z])|([A-Z]{1,2}))[0-9][A-Z0-9]*[A-Z]` anywhere in it (the
    /// regex is not anchored), i.e. a prefix, a digit, and a letter after it.
    public static func isValidCall(_ call:String) -> Bool {
        let chars=Array(call.uppercased().utf8)
        func letter(_ i:Int)->Bool {i<chars.count && chars[i] >= 65 && chars[i] <= 90}
        func digit(_ i:Int)->Bool {i<chars.count && chars[i] >= 48 && chars[i] <= 57}
        for start in chars.indices {
            var prefixLengths:[Int]=[]
            if digit(start) && letter(start+1) {prefixLengths.append(2)}
            if letter(start) {prefixLengths.append(1);if letter(start+1) {prefixLengths.append(2)}}
            for length in prefixLengths where digit(start+length) {
                var index=start+length+1
                while letter(index) || digit(index) {
                    if letter(index) {return true}
                    index+=1
                }
            }
        }
        return false
    }
    private func provisionalQSO(call:String,exchange:String,station:Station,rowID:Int) -> QSOEntry {
        var copied=ContestRules.normalizeCall(call),rx=exchange.uppercased().trimmingCharacters(in:.whitespacesAndNewlines)
        if settings.contest == .sweepstakes {
            let parsed=SweepstakesParser.parse(call:copied,exchange:rx)
            if parsed.complete {copied=parsed.call;rx="\(parsed.serial) \(parsed.precedence) \(parsed.correctedCall.isEmpty ? "" : parsed.correctedCall+" ")\(parsed.check) \(parsed.section)"}
        }
        let check=ContestRules.checkExchange(settings,received:rx,expected:station.exchange,callerCall:station.call)
        return QSOEntry(id:rowID,at:clock,call:station.call,copiedCall:copied,
                        sent:ContestRules.sentExchange(settings,ownSerial:ownSerialCounter.value),received:rx,expected:station.exchange,
                        correct:false,points:0,multipliers:[],note:"Pending TU confirmation",dupe:false,
                        callError:copied != station.call,exchangeErrors:check.errors,wpm:station.wpm,
                        status:.pendingTUConfirmation)
    }
    private func saveQSO(call:String,exchange:String,rowID:Int?=nil,stationSnapshot:Station?=nil,allowBlankExchange:Bool=false) -> QSOEntry? {
        guard running else {return nil}
        guard let st=stationSnapshot ?? target else {emit(.notice,"Select a caller before logging.");return nil}
        guard let validatedCall=Self.validSavedCall(call),
              (allowBlankExchange || !exchange.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) else {
            emit(.notice,"Fill in a valid CALL and RECEIVED.",noticeCode:.entryInvalid);return nil
        }
        let stationAcceptsTU=st.opState == .done
        var copied=validatedCall,rx=exchange.uppercased().trimmingCharacters(in:.whitespacesAndNewlines)
        if settings.contest == .sweepstakes {
            let parsed=SweepstakesParser.parse(call:copied,exchange:rx)
            if parsed.complete {copied=parsed.call;rx="\(parsed.serial) \(parsed.precedence) \(parsed.correctedCall.isEmpty ? "" : parsed.correctedCall+" ")\(parsed.check) \(parsed.section)"}
        }
        let check=ContestRules.checkExchange(settings,received:rx,expected:st.exchange,callerCall:st.call)
        let existing=log.first(where:{$0.id==(rowID ?? 0)})
        let dupe=log.contains(where:{$0.id != rowID && $0.call==st.call && $0.correct})
        let correct = stationAcceptsTU && copied==st.call && check.valid && !dupe
        let rule=ContestRules.score(settings,station:st)
        var copiedStation=st;copiedStation.call=copied
        let rawRule=ContestRules.score(settings,station:copiedStation)
        let wasCounted=existing != nil && existing?.status != .pendingTUConfirmation
        if !dupe && !wasCounted {rawPoints+=rawRule.points;rawMultipliers.formUnion(rawRule.multipliers)}
        let pts=correct ? rule.points : 0
        if correct && existing?.correct != true {verifiedPoints+=pts;verifiedMultipliers.formUnion(rule.multipliers);verified+=1}
        if dupe && existing?.dupe != true {dupes+=1}
        let note=copied != st.call
            ? (stationAcceptsTU ? "\(DiagnosticText.callNotePrefix) copied \(copied); station logged \(st.call)" : "NIL — station did not log this call")
            : !stationAcceptsTU ? "NIL — station did not log this call"
            : dupe ? "DUP — already worked" : check.valid ? "Verified" : "Exchange error: \(check.errors.joined(separator:", "))"
        let id=rowID ?? allocateQSOEntryID()
        // A deferred TU adjudication may update verification, but the contact
        // facts belong to the instant the operator saved the QSO.
        let entry=QSOEntry(id:id,at:existing?.at ?? clock,call:existing?.call ?? st.call,
                           copiedCall:existing?.copiedCall ?? copied,
                           sent:existing?.sent ?? ContestRules.sentExchange(settings,ownSerial:ownSerialCounter.value),
                           received:existing?.received ?? rx,expected:existing?.expected ?? st.exchange,
                           correct:correct,points:pts,multipliers:rule.multipliers,note:note,dupe:dupe,
                           callError:copied != st.call || !stationAcceptsTU,
                           exchangeErrors:existing?.exchangeErrors ?? check.errors,wpm:existing?.wpm ?? st.wpm)
        if let existingIndex=log.firstIndex(where:{$0.id==id}) {log[existingIndex]=entry}
        else {log.insert(entry,at:0)}
        if !wasCounted && ownSerialAffectsSentExchange {ownSerialCounter.advanceAfterSavedContact()}
        if stationAcceptsTU && !completed.contains(where:{$0.call==st.call}) {completed.append(st)}
        sessionDrainUntil=clock+15
        emit(.notice,correct ? "\(st.call) logged ✓ \(pts) QSO pts." : "\(st.call): \(note). Expected \(st.exchange)")
        if stationAcceptsTU {
            if let index=pileup.firstIndex(where:{$0.call==st.call}) {_ = operatorMessage(index,input:.tu)}
            pileup.removeAll(where:{$0.call==st.call})
            if targetCall==st.call {targetCall=nil;phase = .logged}
        }
        if !wasCounted {qsosSinceStationID += 1}
        // A deferred adjudication (rowID given) must not wipe the entry state
        // of whatever contact the operator is working now.
        if rowID == nil {clearEntryState()}
        return entry
    }
    private func scheduleSingleCallerIfNeeded() {
        guard running, settings.mode == .single, pileup.isEmpty, !singleStartupPending else {return}
        refillAutomatic(1)
    }
    /// Single-call and HST callers: MRCE adds each one as if the operator had
    /// just finished a CQ, so every new caller sends its call after its own
    /// send delay.
    private func refillAutomatic(_ count:Int) {
        let missing=max(0,count-pileup.count)
        guard missing>0 else {return}
        phase = .listening
        for _ in 0..<missing {
            let station=makeStation();pileup.append(station)
            queueTransmission(pileup.count-1,station.sentCall,reason:"pileup")
        }
    }
    /// `Poisson(activity/2)` minus the callers already working, with the
    /// three-empty-draws forced arrival. New callers join in `needPrevEnd`
    /// and hear the burst that is finishing, like every other caller.
    @discardableResult private func applyArrivalDraw(_ draw:Int,existing:Int?=nil) -> [Station] {
        let present=existing ?? pileup.filter({$0.opState != .done && $0.opState != .failed}).count
        var additions=max(0,draw-present)
        // `(NoActivityCnt > 2) or (NoStopActivity > 0)`: the third empty draw,
        // or every empty draw in continuous pile-up, brings one caller.
        if additions == 0 {lastArrival+=1;if lastArrival>2 || settings.continuousPileup == true {additions=1;lastArrival=0}}
        var arrivals:[Station]=[]
        for _ in 0..<additions {
            var station=makeStation()
            station.opState = .needPrevEnd
            pileup.append(station);arrivals.append(station)
        }
        return arrivals
    }
    private func makeStation() -> Station {
        let history=settings.contestHistories[settings.contest.rawValue]
        let calls=contestCallerPool
        let mine=callerMeta(settings.myCall)
        // MRCE samples regular callers with replacement, excluding calls
        // already on the air. HST consumes its call list without replacement.
        let activeCalls=Set(pileup.filter{![OperatorState.done,.failed].contains($0.opState)}.map(\.call))
        var call=""
        var selectedRecord:HistoryRecord?
        if call.isEmpty {
            if settings.contest == .sst, !sstCallerPool.isEmpty {
                let eligible=sstCallerPool.filter{!activeCalls.contains($0.call)}
                if !eligible.isEmpty {
                    selectedRecord=eligible[rng.int(0,eligible.count-1)]
                    call=selectedRecord!.call
                }
            }
            let eligible=calls.filter{ call in
                !activeCalls.contains(call) &&
                    (settings.mode != .hstCompetition || !seenStationCalls.contains(call))
            }
            if call.isEmpty, !eligible.isEmpty {
                call=callerPoolIsGeneral ? (pickFromGeneralList(eligible) ?? "") : eligible[rng.int(0,eligible.count-1)]
            }
            else if call.isEmpty {
                let generic=eligibleGenericPool.filter { candidate in
                    !activeCalls.contains(candidate) &&
                        (settings.mode != .hstCompetition || !seenGenericCalls.contains(candidate))
                }
                if let picked=pickFromGeneralList(generic) {call=picked}
                if call.isEmpty {
                    for _ in 0..<100 {
                        let region:CallerRegion
                        if [.allja,.acag].contains(settings.contest) {region = .ja}
                        else if [.sweepstakes,.fieldday].contains(settings.contest) {region = .usve}
                        else if settings.contest == .arrldx {region=mine.usve ? .dx : .usve}
                        else if settings.contest == .naqp && !mine.isNAQPLocal {region = .usve}
                        else if let share=Self.homeShare(settings.contest) {region=rng.random()<share ? .usve : .dx}
                        else {region = .all}
                        let candidate=CallsignGenerator.makeCall(&rng,region:region)
                        let other=callerMeta(candidate)
                        // Invented calls come from a small space; do not invent
                        // one already heard this session.
                        if !activeCalls.contains(candidate) && !seenStationCalls.contains(candidate) &&
                            (settings.contest != .sweepstakes || other.hasARRLSection) &&
                            (settings.contest != .arrldx || mine.usve != other.usve) &&
                            (settings.contest != .naqp || mine.isNAQPLocal || other.isNAQPLocal) &&
                            (![ContestID.cqww,.iaru,.arrldx,.arrl10,.naqp].contains(settings.contest) || other.known) {
                            call=candidate;break
                        }
                    }
                }
            }
        }
        if call.isEmpty {call=CallsignGenerator.makeCall(&rng,region:[ContestID.allja,.acag].contains(settings.contest) ? .ja : .all)}
        // Each caller receives a deterministic stream. Callsign selection and
        // arrival timing stay session-wide; station traits and later dialogue
        // draws cannot perturb another caller's stream.
        let stationSeed=UInt32(rng.random()*4_294_967_296.0)
        var stationRng=ContestRNG(seed:stationSeed)
        var serialFormatRng=ContestRNG(seed:stationSeed ^ 0x51ED_270B)
        seenStationCalls.insert(call)
        if genericCallSet.contains(call) {seenGenericCalls.insert(call)}
        let record=selectedRecord ?? history?.records[call] ?? settings.customRecords[call] ?? genericRecords[call]
        let meta=callerMeta(call)
        // Custom speed settings are offsets below/above the operator's speed.
        // `UpdCWMinRxSpeed`: below 15 WPM callers are at most 4 WPM slower.
        let minOffset=settings.wpm < 15 ? min(4,settings.dxMinWpm) : settings.dxMinWpm,maxOffset=settings.dxMaxWpm
        let speed:Int
        if settings.mode == .hstCompetition {speed=settings.wpm}
        else if settings.callerSpeedMode == .halfToFull {speed=max(5,Int((Double(settings.wpm)*0.5*(1+stationRng.random())).rounded()))}
        else if settings.gaussianSpeed {
            let mean=Double(settings.wpm)+Double(-minOffset+maxOffset)/2
            let limit=Double(minOffset+maxOffset)/2
            speed=max(5,Int((stationRng.gaussian(mean,limit)).rounded()))
        } else {speed=max(5,Int((Double(settings.wpm-minOffset)+Double(minOffset+maxOffset)*stationRng.random()).rounded()))}
        // Legacy uniform tone draw, kept only so later draws keep their positions.
        _=stationRng.int(-90,90)
        var st=Station(call:call,exchange:"",wpm:speed,tone:settings.pitch,volume:0.35+stationRng.random()*0.65,shift:Double(stationRng.int(-180,180)))
        // MRCE caller pitch: Round(RndGaussLim(0, 300)), or 50 in single-call mode.
        var exchangeRng=ContestRNG(seed:stationSeed ^ 0xC0DE_5EED)
        st.tone=settings.pitch+Int(exchangeRng.gaussian(0,settings.mode == .single ? 50 : 300).rounded())
        st.importedRecord=record
        st.behaviorRNGState=stationRng.state
        st.rfAmplitude=9_000+18_000*(1+rfRng.uShaped())
        st.baseWpm=speed;st.characterWpm=max(speed,settings.contest == .sst ? settings.farnsworthCharRate : speed)
        st.replyStyle=stationRng.random();st.repeatCount=[SessionMode.single,.hstCompetition].contains(settings.mode) ? 1 : (stationRng.random()<0.1 ? 2 : 1)
        st.opState=targetCall == nil ? .needQso : .needPrevEnd
        if record?.name.isEmpty == false {st.name=record!.name}
        else {
            // A call heard again keeps the name it used the first time.
            let name=sessionFallbackNames[call] ?? nextFallbackName()
            sessionFallbackNames[call]=name;st.name=name
        }
        if record?.state.isEmpty == false {
            // MRCE history EXCH2 is parsed into `state`; retain it verbatim,
            // including for imported DX callers with a contest-specific value.
            st.state=record!.state
        } else if [.naqp,.arrldx,.arrl10,.sst,.pota].contains(settings.contest) {
            // Synthetic practice locations stay within the caller's entity.
            // Imported history above remains authoritative.
            switch meta.country {
            case "K":
                let states = ["NY","CA","TX","CT","MA","FL","VA","OH","PA","OR","WA"]
                st.state = states[stationRng.int(0, states.count - 1)]
            case "VE":
                let provinces = ["ON","QC","BC","AB","SK","MB","NB","NS","PE","NL","YT","NT","NU"]
                st.state = provinces[stationRng.int(0, provinces.count - 1)]
            case "KH6": st.state = "HI"
            case "KL7": st.state = "AK"
            case "XE" where settings.contest == .arrl10: st.state = "DF"
            default: st.state = settings.contest == .naqp ? (meta.isNAQPLocal ? meta.country : "") : "DX"
            }
        } else {
            // TODO: why don't we leverage our knowledge of the country? For instance ON is Ontario.
            st.state=["NY","CA","TX","CT","MA","FL","VA","OH","ON","PA","OR","WA"][stationRng.int(0,11)]
        }
        st.section=(record?.section.isEmpty == false ? record!.section : ["CT","EMA","WMA","ENY","NFL","SCV","MI","ONE","STX"][stationRng.int(0,8)])
        if [.fieldday,.sweepstakes].contains(settings.contest), record?.section.isEmpty != false {
            switch meta.country {
            case "VE": st.section = "ONE"
            case "KH6","KH0","KH2","KH8": st.section = "PAC"
            case "KL7": st.section = "AK"
            case "KP2": st.section = "VI"
            case "KP4": st.section = "PR"
            case "K": if st.section == "ONE" {st.section = "CT"}
            default: st.section = "DX"
            }
        }
        st.fdClass=(record?.fdClass.isEmpty == false ? record!.fdClass : "2A")
        st.precedence=(record?.precedence.isEmpty == false ? record!.precedence : "A")
        if settings.contest == .sweepstakes {
            // ArrlSS.pas GetExchange draws the precedence for every caller:
            // 43% A, 19% B, 28% U and 10% shared by Q, M and S.
            let draw=exchangeRng.random()
            st.precedence=draw<0.43 ? "A" : draw<0.62 ? "B" : draw<0.90 ? "U" : ["Q","M","S"][exchangeRng.int(0,2)]
        }
        st.check=(record?.check.isEmpty == false ? record!.check : "86")
        if settings.contest == .sweepstakes, let check=Int(st.check), (0...99).contains(check) {
            st.check=String(format:"%02d",check)
        }
        st.cwops=(record?.cwops.isEmpty == false ? record!.cwops : record?.state.isEmpty == false && settings.contest == .cwt ? record!.state : "1234")
        st.jaPref=record?.jaPref.isEmpty == false ? record!.jaPref : "10"
        st.jaCity=record?.jaCity.isEmpty == false ? record!.jaCity : "1002"
        st.jaPower=record?.jaPower ?? "H"
        st.power=record?.power.isEmpty == false ? record!.power : "100"
        st.country=meta.country;st.continent=meta.continent;st.cqZone=meta.cq;st.ituZone=meta.itu
        // Details no imported history supplies are made up from the call, so
        // they vary between callers, stay the same for one call, and put US,
        // Canadian and Japanese stations in their own call areas. The draws
        // above still run so that later draws keep their positions.
        let synthetic=SyntheticExchange.fields(call:call,country:meta.country)
        if record?.state.isEmpty != false,let state=synthetic.state {st.state=state}
        if record?.section.isEmpty != false,let section=synthetic.section {st.section=section}
        if record?.fdClass.isEmpty != false {st.fdClass=synthetic.fdClass}
        if record?.check.isEmpty != false {st.check=synthetic.check}
        if record?.cwops.isEmpty != false && !(record?.state.isEmpty == false && settings.contest == .cwt) {st.cwops=synthetic.cwops}
        if record?.power.isEmpty != false {st.power=synthetic.power}
        if record?.jaPref.isEmpty != false {st.jaPref=synthetic.jaPref}
        if record?.jaCity.isEmpty != false {st.jaCity=synthetic.jaCity}
        if record == nil {st.jaPower=synthetic.jaPower}
        st.skill=stationRng.int(1,3)
        st.serial=SerialDistribution.draw(settings,rng:&stationRng,elapsed:clock,skill:st.skill)
        if settings.contest == .wpx && settings.serialRange == .custom {
            st.serialMinimumWidth=settings.serialMinDigitWidth
            st.serialNaturalWidth=max(1,String(max(1,settings.serialMin)).count)
            st.serialUsesMinimumWidth=ContestRules.callerSerialUsesMinimumWidth(rng:&serialFormatRng)
        }
        let patienceFirst=max(1e-9,stationRng.random()),patienceSecond=max(1e-9,stationRng.random())
        st.patience=Self.rayleighPatience(first:patienceFirst,second:patienceSecond)
        // LIDs do not change how a caller signs: MRCE's only double call is
        // `RepeatCnt`, drawn above for one pile-up caller in ten.
        st.sentCall=Array(repeating:st.sentCall,count:st.repeatCount).joined(separator:" ")
        st.exchange=stationExchange(st)
        // MRCE LIDs: 3% of callers send RST 559/569/579/589, and 10% send one wrong
        // serial digit corrected once on air. The sent RST is the expected RST.
        let lidRST=settings.effects.lids && exchangeRng.random()<0.03 ? 559+10*exchangeRng.int(0,3) : 599
        if lidRST != 599,CallerExchangeText.sendsRST(settings.contest),st.exchange.hasPrefix("599 ") {
            st.exchange="\(lidRST) "+st.exchange.dropFirst(4)
        }
        st.nrWithError=settings.effects.lids && exchangeRng.random()<0.1
        st.stationDraw=exchangeRng.random()
        // `NrAsText`: R1 < 0.5 keeps the custom range's leading zeros.
        if st.serialUsesMinimumWidth != nil {st.serialUsesMinimumWidth=st.stationDraw < 0.5}
        st.duplicate=log.contains(where:{$0.call==call && $0.correct})
        st.exchangeRNGState=max(1,exchangeRng.state)
        st.transmittedExchange=st.exchange
        st.behaviorRNGState=stationRng.state
        let timeout=replyTimeout(&st)
        st.nextAction=clock+ContestRules.cwSeconds(call,wpm:speed)+timeout
        return st
    }

    private func nextFallbackName() -> String {
        if fallbackNameIndex >= fallbackNameCycle.count {
            // Rotate the shuffled cycle between passes, then guard its seam.
            fallbackNameCycle=fallbackNameCycle.dropFirst(1).map{$0} + fallbackNameCycle.prefix(1).map{$0}
            if let lastFallbackName, fallbackNameCycle.first == lastFallbackName {
                fallbackNameCycle.swapAt(0,1)
            }
            fallbackNameIndex=0
        }
        let name=fallbackNameCycle[fallbackNameIndex]
        fallbackNameIndex += 1
        lastFallbackName=name
        return name
    }
    private func stationExchange(_ st:Station) -> String {
        let n=ContestRules.callerSerialText(settings,serial:st.serial,
            customMinimumWidth:st.serialMinimumWidth,naturalWidth:st.serialNaturalWidth,
            useMinimumWidth:st.serialUsesMinimumWidth ?? true)
        switch settings.contest {
        case .wpx,.hst: return "599 \(n)"
        case .cqww: return "599 \(st.cqZone)"
        case .iaru:
            if let record=st.importedRecord,!record.society.isEmpty{return "599 \(record.society)"}
            return "599 \(st.ituZone)"
        case .fieldday: return "\(st.fdClass) \(st.section)"
        case .sweepstakes: return "\(n) \(st.precedence) \(st.call) \(st.check) \(st.section)"
        case .naqp: return ContestRules.callMeta(st.call,settings:settings).isNAQPLocal ? "\(st.name) \(st.state)" : st.name
        case .sst: return "\(st.name) \(st.state)"
        case .pota: return "599 \(st.state)"
        case .cwt: return "\(st.name) \(st.cwops)"
        case .allja: return "599 \(st.jaPref)\(st.jaPower)"
        case .acag: return "599 \(st.jaCity)\(st.jaPower)"
        case .arrldx: return "599 \(st.country == "K" || st.country == "VE" ? st.state : st.power)"
        case .arrl10:
            if st.call.hasSuffix("/MM") {
                // History supplies the actual region; continent is synthetic fallback only.
                let region = ["1","2","3"].contains(st.state) ? st.state
                    : ["NA","SA"].contains(st.continent) ? "2" : ["AS","OC"].contains(st.continent) ? "3" : "1"
                return "599 \(region)"
            }
            return "599 \(ContestRules.callMeta(st.call,settings:settings).isARRL10Local ? st.state : n)"
        }
    }
    private func confidence(_ typed:String,_ correct:String) -> Int {
        // MRCE matchConfidence: exact calls, wildcard substring matching,
        // Levenshtein distance, then a substring fallback in that order.
        if typed==correct {return 100}
        if typed.isEmpty {return 0}
        if typed=="?" {return 2}
        if typed.contains("?") {
            let pattern=Array(typed),candidate=Array(correct)
            let mandatory=pattern.last == "?" ? pattern.count-1 : pattern.count
            if mandatory<=candidate.count && candidate.indices.contains(where:{ start in
                guard candidate.count-start>=mandatory else {return false}
                return (0..<mandatory).allSatisfy { pattern[$0]=="?" || pattern[$0]==candidate[start+$0] }
            }) {
                let copied=pattern.filter{$0 != "?"}.count
                return max(2,100*copied/max(1,candidate.count))
            }
        }
        let a=Array(typed),b=Array(correct)
        var previous=Array(0...b.count)
        for i in 1...a.count {
            var next=[i]+Array(repeating:0,count:b.count)
            for j in 1...b.count {next[j]=min(previous[j]+1,next[j-1]+1,previous[j-1]+(a[i-1]==b[j-1] ? 0 : 1))}
            previous=next
        }
        let distance=previous[b.count]
        if distance<=(b.count-1)/2 {return 100*(b.count-distance)/max(1,b.count)}
        if correct.contains(typed) {return 100*typed.count/max(1,correct.count)}
        return 0
    }
    #if DEBUG
    internal func fixtureConfidence(typed:String,correct:String) -> Int {confidence(typed,correct)}
    #endif
}
