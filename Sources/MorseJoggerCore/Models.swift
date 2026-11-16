//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

/// Portable, platform-independent CW Field simulator types. No Apple UI, browser or JS APIs.
public enum ContestID: String, Codable, CaseIterable, Sendable, Identifiable {
    case wpx, cqww, arrldx, fieldday, sweepstakes, naqp, cwt, sst, iaru, allja, acag, arrl10, hst, pota
    public var id: String { rawValue }
    public var definition: ContestDefinition { ContestDefinition(id: self) }
    public var label: String { definition.label }
    public var exchangeLabel: String { definition.exchangeLabel }
    public var receivedExchangeFields:(first:String?,second:String,secondAllowsSpaces:Bool) {
        definition.receivedExchangeFields
    }
}

public enum SessionMode: String, Codable, CaseIterable, Sendable {
    case pileup, single, wpxCompetition, hstCompetition
    public var label: String {
        switch self {
        case .pileup: "Pileup"
        case .single: "Single calls"
        case .wpxCompetition: "WPX competition"
        case .hstCompetition: "HST competition"
        }
    }
}
public enum SerialRange: String, Codable, CaseIterable, Sendable { case start, mid, end, custom }
public enum IARUExchangeMode: String, Codable, CaseIterable, Sendable { case zone, society }
/// The operator's sent serial is independent of the number of contacts in the
/// log. Advance it only when the session accepts a saved QSO.
public struct OwnSerialCounter:Codable,Equatable,Sendable {
    public private(set) var value:Int
    public init(startingAt:Int){value=max(1,startingAt)}
    public mutating func advanceAfterSavedContact(){value+=1}
}
public enum OperatorState: String, Codable, Sendable {
    case needPrevEnd, needQso, needNr, needCall, needCallNr, needEnd, done, failed
}
public enum SessionPhase: String, Codable, Sendable { case ready, listening, copy, logged, finished }
public enum QSOEntryField:Int,CaseIterable,Sendable {case callsign,exchangeFirst,exchangeSecond}
public enum Command: String, Codable, CaseIterable, Sendable {
    case cq, call, exchange, repeatMessage, numberAgain, tu, log, saveOnly, wipe, stop, esm, mycall, hiscall, b4, `nil`
    public var label: String {
        switch self {
        case .cq: "CQ"; case .call: "CALL"; case .exchange: "EXCH"; case .repeatMessage: "?"
        case .numberAgain: "NR?"
        case .tu: "TU"; case .log: "TU / LOG"; case .saveOnly: "SAVE ONLY"; case .wipe: "WIPE F11"; case .stop: "STOP / ESC"
        case .esm: "ENTER"; case .mycall: "MY CALL"; case .hiscall: "HIS CALL"
        case .b4: "B4"; case .nil: "NIL"
        }
    }
    /// MRCE key assignment. WIPE is F11 in upstream; STOP is Escape.
    public var functionKey: Int? {
        switch self {
        case .cq: 1
        case .exchange: 2
        case .tu: 3
        case .mycall: 4
        case .hiscall: 5
        case .b4: 6
        case .repeatMessage: 7
        case .nil: 8
        case .wipe: 11
        case .numberAgain: 12
        default: nil
        }
    }
}

public struct Effects: Codable, Equatable, Sendable {
    public var qrn = false, qrm = false, qsb = false, flutter = false, lids = false
    public init() {}
    public static func all(_ enabled: Bool) -> Effects { var e=Effects(); e.qrn=enabled; e.qrm=enabled; e.qsb=enabled; e.flutter=enabled; e.lids=enabled; return e }
}
public struct HistoryRecord: Codable, Equatable, Sendable {
    public var call = ""; public var state = ""; public var section = ""; public var name = ""
    public var check = ""; public var precedence = ""; public var cwops = ""; public var fdClass = ""
    public var cq = 0; public var itu = 0; public var country = ""; public var continent = ""
    public var society = ""; public var jaPref = ""; public var jaCity = ""; public var power = ""
    public var jaPower:String? = nil
    public var userText:String? = nil
    public init(call: String = "") { self.call = call }
}
public struct ImportedHistory: Codable, Equatable, Sendable {
    public var calls: [String] = []
    public var records: [String: HistoryRecord] = [:]
    public var sourceName: String = ""
    /// Physical imported rows. SST samples these independently, preserving duplicate-call weights.
    public var rows: [HistoryRecord] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case calls, records, sourceName, rows }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calls = try c.decodeIfPresent([String].self, forKey: .calls) ?? []
        records = try c.decodeIfPresent([String:HistoryRecord].self, forKey: .records) ?? [:]
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        rows = try c.decodeIfPresent([HistoryRecord].self, forKey: .rows) ?? []
    }
}

public enum CallerSpeedMode: String, Codable, Sendable {
    case halfToFull, custom
}

public struct ContestSettings: Codable, Equatable, Sendable {
    public var myCall="VE3NEA"
    /// Operator exchange overrides keyed by contest; absent entries use contest defaults.
    public var operatorExchangeProfiles: [String:OperatorExchangeProfile]? = nil
    public var contest: ContestID = .wpx, mode: SessionMode = .pileup
    public var duration=30, wpm=25, activity=2, pitch=600, volume=1.0
    public var dxMinWpm=0, dxMaxWpm=0
    /// Nil supports settings saved before the explicit speed selector existed.
    public var callerSpeedSelection: CallerSpeedMode? = nil
    public var callerSpeedMode: CallerSpeedMode {
        get { callerSpeedSelection ?? ((dxMinWpm == -1 || dxMaxWpm == -1) ? .halfToFull : .custom) }
        set {
            callerSpeedSelection = newValue
            dxMinWpm = min(80, max(0, dxMinWpm))
            dxMaxWpm = min(80, max(0, dxMaxWpm))
        }
    }
    public var customCalls: [String] = []
    public var customRecords: [String: HistoryRecord] = [:]
    public var contestHistories: [String: ImportedHistory] = [:]
    /// User-imported prefix overrides, kept separately from copyright-restricted CTY.DAT.
    public var countryPrefixes: [String: HistoryRecord] = [:]
    public var serialPadding=3, qsk=false, rit=0, bandwidth=500, monitor=0, showCallsignInfo=true
    public var showCorrectAnswers=false
    public var effects = Effects(), seed: UInt32 = 0
    public var serialRange: SerialRange = .start
    public var serialMin=1, serialMax=99, gaussianSpeed=false, callerQrs=false, callerStays=false, nilInstant=false
    /// MRCE Ctrl-U: a CQ or TU that draws no caller always brings one. Nil
    /// (settings saved before this existed) means off.
    public var continuousPileup: Bool? = nil
    /// MRCE's `F8` setting: text sent in place of `NIL`. Nil or empty sends NIL.
    public var nilText: String? = nil
    public var effectiveNilText: String {
        let text=(nilText ?? "").uppercased().trimmingCharacters(in:.whitespacesAndNewlines)
        return text.isEmpty ? "NIL" : text
    }
    /// Original endpoint widths from MRCE's custom range parser. Optional for
    /// migration from saved settings created before widths were preserved.
    public var serialMinDigits:Int? = nil, serialMaxDigits:Int? = nil
    public var stationIdRate=3, fast5nn=false, fast5nnOccurrenceRate=80, farnsworthCharRate=25
    public var singleCallStartDelay=0, showCheckSection=50, showExchangeSummary=true, competitionDuration=60
    public init() {}
    public func exchangeProfile(for contest:ContestID? = nil) -> OperatorExchangeProfile {
        let key=(contest ?? self.contest).rawValue
        return operatorExchangeProfiles?[key] ?? OperatorExchangeProfile.defaults(for:contest ?? self.contest)
    }
    public mutating func setExchangeProfile(_ profile:OperatorExchangeProfile, for contest:ContestID? = nil) {
        let key=(contest ?? self.contest).rawValue
        if operatorExchangeProfiles == nil { operatorExchangeProfiles = [:] }
        operatorExchangeProfiles?[key] = profile
    }
    public func effective() -> ContestSettings {
        var s = self
        s.duration = min(1440, max(1, s.duration)); s.wpm = min(120, max(5,s.wpm))
        s.activity = min(9,max(1,s.activity)); s.serialPadding = min(6,max(1,s.serialPadding))
        s.volume = min(1,max(0,s.volume))
        s.callerSpeedMode = callerSpeedMode
        s.pitch = Self.nearestChoice(s.pitch, choices: Array(stride(from: 300, through: 900, by: 50)))
        s.bandwidth = Self.nearestChoice(s.bandwidth, choices: Array(stride(from: 100, through: 600, by: 50)))
        s.monitor = min(0,max(-60,s.monitor))
        s.singleCallStartDelay = min(2500,max(0,s.singleCallStartDelay))
        if s.mode == .wpxCompetition || s.mode == .hstCompetition {
            s.duration = max(1,min(60,s.competitionDuration)); s.effects = .all(s.mode == .wpxCompetition)
            if s.mode == .hstCompetition {
                s.bandwidth = 600
                s.activity = 4
            }
        }
        return s
    }

    /// Error shown before a session can start. Equal bounds are valid; the
    /// caller generator handles that as a fixed serial without invoking
    /// Delphi Random(0), whose historical behavior is unverified.
    public var customSerialRangeError:String? {
        guard serialRange == .custom, customSerialRangeIsRelevant else { return nil }
        guard (1...9999).contains(serialMin) else { return "Custom serial minimum must be from 1 to 9999." }
        guard (1...9999).contains(serialMax) else { return "Custom serial maximum must be from 1 to 9999." }
        guard serialMin <= serialMax else { return "Custom serial minimum must not exceed the maximum." }
        return nil
    }

    public var customSerialRangeIsRelevant:Bool {
        contest.definition.supportsCustomSerialRange
    }

    public var serialMinDigitWidth:Int { max(1,serialMinDigits ?? String(max(1,serialMin)).count) }
    public var serialMaxDigitWidth:Int { max(1,serialMaxDigits ?? String(max(1,serialMax)).count) }

    public static func nearestChoice(_ value: Int, choices: [Int]) -> Int {
        choices.min(by: { abs($0 - value) < abs($1 - value) }) ?? value
    }
}

/// Contest-local values used to form the operator's sent exchange.
public struct OperatorExchangeProfile: Codable, Equatable, Sendable {
    public var name:String, state:String, section:String, fdClass:String
    public var zone:Int, ituZone:Int, ituSociety:String
    /// Optional raw exchange text keeps meaningful leading zeroes such as 03.
    /// Nil means use the legacy integer field for older saved profiles.
    public var zoneText:String, ituZoneText:String
    public var iaruExchangeMode:IARUExchangeMode
    public var cwopsNumber:String, check:String, precedence:String, power:String
    public var jaPrefecture:String, jaCity:String, jaPower:String
    /// The operator's first serial number, when it should not come from the
    /// serial range. Nil uses the range.
    public var firstSerial:Int? = nil
    private enum CodingKeys:String,CodingKey {case firstSerial,name,state,section,fdClass,zone,ituZone,zoneText,ituZoneText,ituSociety,iaruExchangeMode,cwopsNumber,check,precedence,power,jaPrefecture,jaCity,jaPower}
    public init(name:String="OP",state:String="NY",section:String="ON",fdClass:String="3A",zone:Int=5,ituZone:Int=8,ituSociety:String="",zoneText:String?=nil,ituZoneText:String?=nil,iaruExchangeMode:IARUExchangeMode = .zone,cwopsNumber:String="123",check:String="86",precedence:String="A",power:String="100",jaPrefecture:String="10",jaCity:String="1002",jaPower:String="H") {
        self.name=name;self.state=state;self.section=section;self.fdClass=fdClass;self.zone=zone;self.ituZone=ituZone;self.zoneText=zoneText ?? String(zone);self.ituZoneText=ituZoneText ?? String(ituZone);self.ituSociety=ituSociety;self.iaruExchangeMode=iaruExchangeMode;self.cwopsNumber=cwopsNumber;self.check=check;self.precedence=precedence;self.power=power;self.jaPrefecture=jaPrefecture;self.jaCity=jaCity;self.jaPower=jaPower
    }
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        let zone=try c.decodeIfPresent(Int.self,forKey:.zone) ?? 5
        let ituZone=try c.decodeIfPresent(Int.self,forKey:.ituZone) ?? 8
        let society=try c.decodeIfPresent(String.self,forKey:.ituSociety) ?? ""
        self.init(name:try c.decodeIfPresent(String.self,forKey:.name) ?? "OP",
                  state:try c.decodeIfPresent(String.self,forKey:.state) ?? "NY",
                  section:try c.decodeIfPresent(String.self,forKey:.section) ?? "ON",
                  fdClass:try c.decodeIfPresent(String.self,forKey:.fdClass) ?? "3A",
                  zone:zone,
                  ituZone:ituZone,
                  ituSociety:society,
                  zoneText:try c.decodeIfPresent(String.self,forKey:.zoneText) ?? String(format:"%02d",zone),
                  ituZoneText:try c.decodeIfPresent(String.self,forKey:.ituZoneText) ?? String(format:"%02d",ituZone),
                  iaruExchangeMode:try c.decodeIfPresent(IARUExchangeMode.self,forKey:.iaruExchangeMode) ?? (society.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? .zone : .society),
                  cwopsNumber:try c.decodeIfPresent(String.self,forKey:.cwopsNumber) ?? "123",
                  check:try c.decodeIfPresent(String.self,forKey:.check) ?? "86",
                  precedence:try c.decodeIfPresent(String.self,forKey:.precedence) ?? "A",
                  power:try c.decodeIfPresent(String.self,forKey:.power) ?? "100",
                  jaPrefecture:try c.decodeIfPresent(String.self,forKey:.jaPrefecture) ?? "10",
                  jaCity:try c.decodeIfPresent(String.self,forKey:.jaCity) ?? "1002",
                  jaPower:try c.decodeIfPresent(String.self,forKey:.jaPower) ?? "H")
        firstSerial=try c.decodeIfPresent(Int.self,forKey:.firstSerial)
    }
    public static func defaults(for contest:ContestID)->OperatorExchangeProfile {
        contest.definition.defaultOperatorProfile
    }
}
public struct Station: Codable, Equatable, Sendable {
    public var call: String, exchange: String, wpm: Int, tone: Int, volume: Double, shift: Double
    /// MRCE RF source amplitude draw, sampled once for this station and carried
    /// unchanged by every immutable on-air voice snapshot.
    public var rfAmplitude: Double? = nil
    /// Selected imported row for contests whose source list preserves duplicate rows.
    public var importedRecord: HistoryRecord? = nil
    /// Seeded random stream for this caller's behavior. Kept on the value so
    /// copies in scheduled events and pending QSOs continue the same stream.
    var behaviorRNGState: UInt32 = 0
    /// Separate stream for on-air exchange text draws (cut numbers, ENN, LID
    /// errors). Zero means a hand-built station that keeps canonical text.
    var exchangeRNGState: UInt32 = 0
    /// MRCE `TStation.R1`: one draw per station, fixed for its life. It picks
    /// the faster-5NN rate, the cut-number habit for zones and power, and the
    /// wording of a repeat request. It is separate from `replyStyle`, which is
    /// the operator's `R2` and picks the call-correction style.
    public var stationDraw=0.0
    /// SST pleasantry (`GM <name> `), chosen the first time this caller uses
    /// one and reused afterwards. Nil until then; empty means none.
    var sstGreeting: String? = nil
    public var name="", state="", section="", fdClass="2A", precedence="A", check="86", cwops=""
    public var jaPref="10", jaCity="1002", jaPower="H", power="100"
    public var opState: OperatorState = .needQso
    public var patience=6, incomplete=0, nextAction=0.0, duplicate=false, skill=2, ghosting=false
    public var lastReply="", replyCount=0, sentCall="", correctedCallAndExchSent=false, qrsStage=0
    public var baseWpm=0, characterWpm=0, silentTimeouts=0, sendNrQuestionCount=0, repeatCount=1
    public var replyStyle=0.0, rfBusyUntil=0.0, transmittedExchange="", nrWithError=false
    public var country="", continent="", cqZone=0, ituZone=0, serial=1
    /// Stable MRCE serial-width choice for custom WPX caller exchanges.
    var serialMinimumWidth:Int? = nil, serialNaturalWidth:Int? = nil, serialUsesMinimumWidth:Bool? = nil
    private enum CodingKeys: String, CodingKey {
        case call, exchange, wpm, tone, volume, shift, rfAmplitude, importedRecord, name, state, section
        case fdClass, precedence, check, cwops, jaPref, jaCity, jaPower, power
        case opState, patience, incomplete, nextAction, duplicate, skill, ghosting
        case lastReply, replyCount, sentCall, correctedCallAndExchSent, qrsStage
        case baseWpm, characterWpm, silentTimeouts, sendNrQuestionCount, repeatCount
        case replyStyle, rfBusyUntil, transmittedExchange, nrWithError, country, continent
        case cqZone, ituZone, serial, serialMinimumWidth, serialNaturalWidth, serialUsesMinimumWidth
    }
    public init(call:String, exchange:String, wpm:Int, tone:Int, volume:Double, shift:Double, rfAmplitude:Double? = nil) {
        self.call=call; self.exchange=exchange; self.wpm=wpm; self.tone=tone; self.volume=volume; self.shift=shift; sentCall=call
        self.rfAmplitude=rfAmplitude
    }
}
public enum QSOEntryStatus: String, Codable, Sendable {
    case completed
    case pendingTUConfirmation
}

public struct QSOEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: Int, at: Double, call: String, copiedCall: String, sent: String, received: String, expected: String
    public var correct: Bool, points: Int, multipliers: [String], note: String, dupe: Bool, callError: Bool
    public var exchangeErrors: [String], wpm: Int
    public var status: QSOEntryStatus
    public init(id:Int,at:Double,call:String,copiedCall:String,sent:String,received:String,expected:String,correct:Bool,points:Int,multipliers:[String],note:String,dupe:Bool,callError:Bool,exchangeErrors:[String],wpm:Int,status:QSOEntryStatus = .completed) {
        self.id=id; self.at=at; self.call=call; self.copiedCall=copiedCall; self.sent=sent
        self.received=received; self.expected=expected; self.correct=correct; self.points=points
        self.multipliers=multipliers; self.note=note; self.dupe=dupe; self.callError=callError
        self.exchangeErrors=exchangeErrors; self.wpm=wpm; self.status=status
    }

    private enum CodingKeys: String, CodingKey {
        case id, at, call, copiedCall, sent, received, expected, correct, points
        case multipliers, note, dupe, callError, exchangeErrors, wpm, status
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        at = try values.decode(Double.self, forKey: .at)
        call = try values.decode(String.self, forKey: .call)
        copiedCall = try values.decode(String.self, forKey: .copiedCall)
        sent = try values.decode(String.self, forKey: .sent)
        received = try values.decode(String.self, forKey: .received)
        expected = try values.decode(String.self, forKey: .expected)
        correct = try values.decode(Bool.self, forKey: .correct)
        points = try values.decode(Int.self, forKey: .points)
        multipliers = try values.decode([String].self, forKey: .multipliers)
        note = try values.decode(String.self, forKey: .note)
        dupe = try values.decode(Bool.self, forKey: .dupe)
        callError = try values.decode(Bool.self, forKey: .callError)
        exchangeErrors = try values.decode([String].self, forKey: .exchangeErrors)
        wpm = try values.decode(Int.self, forKey: .wpm)
        status = try values.decodeIfPresent(QSOEntryStatus.self, forKey: .status) ?? .completed
    }
}
/// Post-contact diagnosis. Original MRCE prioritizes NIL, DUP, RST and NR;
/// additional CW Field contests can have named exchange fields.
public struct QSODiagnosis: Equatable, Sendable {
    public var code:String, explanation:String
    public init(code:String,explanation:String) {self.code=code;self.explanation=explanation}
}
public extension QSOEntry {
    var diagnosis:QSODiagnosis {
        if status == .pendingTUConfirmation {
            let callResult = callError
                ? "Copied call \(copiedCall) does not match the station call \(call)."
                : "Copied call \(copiedCall) matches the station call."
            let exchangeResult = exchangeErrors.isEmpty
                ? "The copied exchange matches."
                : "The exchange differs: copied \(received), expected \(expected)."
            return QSODiagnosis(code:"PENDING",explanation:"\(callResult) \(exchangeResult) Final verification awaits TU confirmation.")
        }
        if callError {
            if note.hasPrefix(DiagnosticText.callNotePrefix) {
                return QSODiagnosis(code:"CALL",explanation:"Busted call: copied \(copiedCall), station sent \(call). Correct the call to \(call).")
            }
            let explanation = copiedCall == call
                ? "NIL: the station did not accept TU and did not log this contact."
                : "Busted call: copied \(copiedCall), station sent \(call). MRCE calls a contact absent from the other station's log NIL."
            return QSODiagnosis(code:"NIL",explanation:explanation)
        }
        if dupe {return QSODiagnosis(code:"DUP",explanation:"Duplicate: this callsign was already worked and verified.")}
        if !exchangeErrors.isEmpty {
            let rst=exchangeErrors.contains(where:{$0.uppercased().contains(DiagnosticText.rst)})
            let code=rst ? "RST" : (exchangeErrors.contains(DiagnosticText.exchange) || exchangeErrors.contains(DiagnosticText.serial) ? "NR" : "EXCH")
            return QSODiagnosis(code:code,explanation:"Exchange differs: copied \(received), expected \(expected). Check \(exchangeErrors.joined(separator:", ")).")
        }
        return QSODiagnosis(code:"OK",explanation:"Copied callsign and exchange match the station's logged values.")
    }
}

public enum RadioEventKind: String, Codable, Sendable { case transmit, receive, interference, notice, stopAudio, cancelReceive, finished
    /// The caller's call in an own transmission that is queued or under way
    /// was edited: `text` replaces the text of the transmit event with the
    /// same `pieceID`, and whatever is queued behind it moves up or back.
    case rekey
    /// MRCE `MainForm.Advance`: the piece being sent has ended after an Enter
    /// that did not log, so the host moves the cursor on.
    case advanceEntry
}
/// Typed user-facing validation notices. These may be shown directly in the
/// native controls without exposing arbitrary simulator transcripts.
public enum RadioNoticeCode: String, Codable, Sendable {
    case exchangeInvalid, callInvalid, entryInvalid
    public var safeDisplayText:String {
        switch self {
        case .exchangeInvalid: return "Exchange is incomplete or invalid. Correct it before logging."
        case .callInvalid: return "Enter a valid callsign before saving."
        case .entryInvalid: return "Fill in a valid CALL and RECEIVED."
        }
    }
}
/// Immutable on-air data captured at the moment a caller is scheduled.
/// The host must not reconstruct these replies from the latest station state
/// or infer them from the aggregate UI text: the callers can overlap or leave.
public struct RadioVoice: Codable, Equatable, Sendable {
    public var call:String, message:String, wpm:Int, characterWpm:Int, tone:Int, volume:Double
    public var rfAmplitude:Double?
    /// True when the contest keys with MRCE's Farnsworth keyer (SST), whose
    /// extra-space rule differs even at or above the character rate.
    public var farnsworthKeyer:Bool? = nil
    /// Optional offset of the report's first character in `message`; the next
    /// three characters use `fastReportRate` when present.
    public var fastReportStart:Int? = nil, fastReportStarts:[Int]? = nil, fastReportRate:Double = 1.0
    public var effectiveFastReportStarts:[Int] { fastReportStarts ?? fastReportStart.map{[$0]} ?? [] }
    public init(station:Station,message:String,fastReportStart:Int?=nil,fastReportStarts:[Int]?=nil,fastReportRate:Double=1.0) {
        call=station.call;self.message=message;wpm=station.wpm
        characterWpm=station.characterWpm;tone=station.tone;volume=station.volume
        rfAmplitude=station.rfAmplitude
        self.fastReportStart=fastReportStarts?.first ?? fastReportStart
        self.fastReportStarts=fastReportStarts ?? fastReportStart.map{[$0]}
        self.fastReportRate=fastReportRate
    }
}
public struct RadioEvent: Codable, Sendable {
    /// Event time in simulator seconds. TX/notice events use publication time;
    /// ordinary RX is published when its scheduled due time is delivered by
    /// `tick`, while lookahead QRM keeps its future scheduled time here.
    public var kind: RadioEventKind, text: String, stationCalls: [String], reason: String, at: Double
    public var noticeCode:RadioNoticeCode? = nil
    public var voices:[RadioVoice]
    /// Optional offset of a transmitted report; the next three characters
    /// use `fastReportRate` when present.
    public var fastReportStart:Int? = nil, fastReportStarts:[Int]? = nil, fastReportRate:Double = 1.0
    /// Character rate for a transmit event keyed with Farnsworth spacing;
    /// nil when characters are sent at the operator's speed.
    public var characterWpm:Int? = nil
    /// Identifies one own transmission (an MRCE keyer piece) so a later
    /// `.rekey` event can name it.
    public var pieceID:Int? = nil
    public var effectiveFastReportStarts:[Int] { fastReportStarts ?? fastReportStart.map{[$0]} ?? [] }
    public init(_ kind:RadioEventKind, _ text:String, calls:[String]=[], reason:String="", at:Double=0,voices:[RadioVoice]=[],fastReportStart:Int?=nil,fastReportStarts:[Int]?=nil,fastReportRate:Double=1.0,noticeCode:RadioNoticeCode?=nil) {
        self.kind=kind; self.text=text; stationCalls=calls; self.reason=reason; self.at=at;self.voices=voices
        self.noticeCode=noticeCode
        self.fastReportStart=fastReportStarts?.first ?? fastReportStart
        self.fastReportStarts=fastReportStarts ?? fastReportStart.map{[$0]}
        self.fastReportRate=fastReportRate
    }
}
public struct SessionSnapshot: Codable, Sendable {
    public var running:Bool, phase:SessionPhase, remaining:Double, elapsed:Double
    public var contacts:Int, verified:Int, score:Int, multipliers:Int, rawPoints:Int, dupes:Int, rate:Int
    public var pending:Int, selectedCall:String, serial:Int, status:String
}
