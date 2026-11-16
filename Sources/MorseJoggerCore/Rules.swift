//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import Foundation
public enum ContestRules {
    public struct CallsignInformation: Equatable, Sendable {
        public let call: String
        public let geography: String?
        public let contestHistory: String?
        public var displayText: String {
            [contestHistory, geography].compactMap { $0 }.joined(separator: " · ")
        }
    }
    /// Resolve the call shown by assistance. A deliberate log-row selection
    /// wins until the operator changes the typed callsign; active caller and
    /// latest log are fallbacks when the entry is empty.
    public static func callsignInformationCall(typedCall:String, selectedLogCall:String?, activeCall:String?, latestLogCall:String?) -> String? {
        for candidate in [selectedLogCall, typedCall, activeCall, latestLogCall].compactMap({$0}) {
            let call=normalizeCall(candidate)
            if !call.isEmpty { return call }
        }
        return nil
    }
    public static func normalizeCall(_ value: String) -> String {
        String(value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "/" || $0 == "?") }.prefix(20))
    }
    public static func tokens(_ value: String) -> [String] { value.uppercased().split(whereSeparator: { $0.isWhitespace }).map(String.init) }
    /// Join the two MRCE-style exchange controls into the canonical string
    /// consumed by the simulator and contest validators.
    public static func joinReceivedExchangeFields(first:String,second:String)->String {
        [first,second].map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}
            .filter{!$0.isEmpty}.joined(separator:" ").uppercased()
    }
    /// Derives the two received-exchange boxes from one joined string for
    /// callers that predate separate fields. RST contests treat a leading
    /// report token as the first box; Sweepstakes has only the second box.
    public static func deriveReceivedExchangeFields(_ value:String,contest:ContestID)->(first:String,second:String) {
        let words=tokens(value)
        guard !words.isEmpty else{return ("","")}
        if contest == .sweepstakes {return ("",words.joined(separator:" "))}
        if contest.definition.usesRST {
            if isReportToken(words[0]) {return (words[0],words.dropFirst().joined(separator:" "))}
            return ("599",words.joined(separator:" "))
        }
        return (words[0],words.dropFirst().joined(separator:" "))
    }
    /// Populate two editable controls from a prior/canonical exchange value.
    /// Sweepstakes places the serial in the first control and the remaining
    /// multi-part exchange in its second control.
    public static func splitReceivedExchangeFields(_ value:String,contest:ContestID)->(first:String,second:String) {
        let words=tokens(value)
        guard !words.isEmpty else{return ("","")}
        if contest == .sweepstakes {return ("",words.joined(separator:" "))}
        return (words[0],words.dropFirst().joined(separator:" "))
    }
    public static func nextEntryField(after field:QSOEntryField,backwards:Bool=false)->QSOEntryField {
        let fields=QSOEntryField.allCases
        let index=fields.firstIndex(of:field) ?? 0
        return fields[(index+(backwards ? fields.count-1 : 1)) % fields.count]
    }
    public static func nextEntryField(after field:QSOEntryField,contest:ContestID,backwards:Bool=false)->QSOEntryField {
        let fields:[QSOEntryField]=contest == .sweepstakes ? [.callsign,.exchangeSecond] : QSOEntryField.allCases
        let index=fields.firstIndex(of:field) ?? 0
        return fields[(index+(backwards ? fields.count-1 : 1)) % fields.count]
    }
    public static func nextSpaceEntryField(after field:QSOEntryField,contest:ContestID)->QSOEntryField? {
        guard spaceAdvancesEntryField(contest:contest,field:field) else{return nil}
        if field == .callsign, contest.definition.usesRST {return .exchangeSecond}
        if contest == .sweepstakes,field == .callsign {return .exchangeSecond}
        return nextEntryField(after:field,contest:contest)
    }
    /// MRCE uses Space to advance between controls, except in Sweepstakes'
    /// final control where spaces separate the copied exchange components.
    public static func spaceAdvancesEntryField(contest:ContestID,field:QSOEntryField)->Bool {
        field != .exchangeSecond || !contest.receivedExchangeFields.secondAllowsSpaces
    }
    public struct CallMeta: Sendable {
        public var country:String, continent:String, cq:Int, itu:Int, prefix:String
        public var known: Bool { country != "UNKNOWN" && continent != "??" }
        /// MRCE includes Hawaii in the NAQP home region.
        public var isNAQPLocal: Bool { known && (continent == "NA" || country == "KH6") }
        public var isARRL10Local: Bool { usve || ["XE","KL7","KH6"].contains(country) }
        public var usCanadaIncludingAlaskaHawaii: Bool { usve || ["KL7","KH6"].contains(country) }
        public var hasARRLSection: Bool { usCanadaIncludingAlaskaHawaii || ["KP2","KP4","KH0","KH2","KH8"].contains(country) }
        public var usve: Bool { country == "K" || country == "VE" }
    }
    private static let countries: [(String,String,String,Int,Int)] = [
        ("KH6","KH6","OC",31,61),("KH7","KH6","OC",31,61),
        ("AH6","KH6","OC",31,61),("AH7","KH6","OC",31,61),("NH6","KH6","OC",31,61),("NH7","KH6","OC",31,61),
        ("WH6","KH6","OC",31,61),("WH7","KH6","OC",31,61),
        ("KL7","KL7","NA",1,1),("KL","KL7","NA",1,1),("AL","KL7","NA",1,1),("NL","KL7","NA",1,1),("WL","KL7","NA",1,1),
        ("KP2","KP2","NA",8,11),("KP4","KP4","NA",8,11),
        ("NP2","KP2","NA",8,11),("WP2","KP2","NA",8,11),("NP4","KP4","NA",8,11),("WP4","KP4","NA",8,11),
        ("VE","VE","NA",4,9),("VA","VE","NA",4,9),("VO","VE","NA",4,9),("VY","VE","NA",4,9),
        // Canada's other allocations (CFA-CKZ, CZA-CZZ, VBA-VGZ, VXA-VXZ, XJA-XOZ).
        // CY0 and CY9 are separate entities and are left out.
        ("VB","VE","NA",4,9),("VC","VE","NA",4,9),("VD","VE","NA",4,9),("VF","VE","NA",4,9),("VG","VE","NA",4,9),("VX","VE","NA",4,9),
        ("XJ","VE","NA",4,9),("XK","VE","NA",4,9),("XL","VE","NA",4,9),("XM","VE","NA",4,9),("XN","VE","NA",4,9),("XO","VE","NA",4,9),
        ("CF","VE","NA",4,9),("CG","VE","NA",4,9),("CH","VE","NA",4,9),("CI","VE","NA",4,9),("CJ","VE","NA",4,9),("CK","VE","NA",4,9),("CZ","VE","NA",4,9),
        ("XE","XE","NA",6,10),("JA","JA","AS",25,45),("JE","JA","AS",25,45),("JF","JA","AS",25,45),("JG","JA","AS",25,45),("JH","JA","AS",25,45),("JI","JA","AS",25,45),("7J","JA","AS",25,45),
        ("JJ","JA","AS",25,45),("JK","JA","AS",25,45),("JL","JA","AS",25,45),("JM","JA","AS",25,45),
        ("JN","JA","AS",25,45),("JO","JA","AS",25,45),("JP","JA","AS",25,45),("JQ","JA","AS",25,45),
        ("JR","JA","AS",25,45),("JS","JA","AS",25,45),
        ("DL","DL","EU",14,28),("DA","DL","EU",14,28),("DB","DL","EU",14,28),("DC","DL","EU",14,28),
        ("EA","EA","EU",14,37),("EB","EA","EU",14,37),("EC","EA","EU",14,37),
        ("VK","VK","OC",30,59),("ZL","ZL","OC",32,60),("PY","PY","SA",11,15),("LU","LU","SA",13,14),
        ("SM","SM","EU",14,18),("OH","OH","EU",15,18),("ON","ON","EU",14,27),("PA","PA","EU",14,27),
        ("HB","HB","EU",14,28),("OE","OE","EU",15,28),("SP","SP","EU",15,28),("OK","OK","EU",15,28),
        ("OM","OM","EU",15,28),("9A","9A","EU",15,28),("S5","S5","EU",15,28),("YO","YO","EU",20,28),
        ("LZ","LZ","EU",20,28),("UA","UA","EU",16,29),("YU","YU","EU",15,28),("4X","4X","AS",20,39),
        ("G","G","EU",14,27),("M","G","EU",14,27),("F","F","EU",14,27),("I","I","EU",15,28),
        ("K","K","NA",5,8),("N","K","NA",5,8),("W","K","NA",5,8),
    ]
    public static func callMeta(_ value: String, settings:ContestSettings? = nil) -> CallMeta {
        let pieces = normalizeCall(value).split(separator:"/").map(String.init)
        var call = pieces.first ?? ""
        if pieces.count > 1 {
            let leading = pieces[0]
            if leading.count <= 4 && leading.last?.isNumber == true && pieces[1].count >= 4 { call = leading }
            else if let last = pieces.last, last.count <= 4 && last.last?.isNumber == true { call = last }
        }
        var meta = CallMeta(country:"UNKNOWN",continent:"??",cq:0,itu:0,prefix:call)
        if let hit = countries.first(where: { call.hasPrefix($0.0) }) {
            meta.country=hit.1;meta.continent=hit.2;meta.cq=hit.3;meta.itu=hit.4
        } else if call.count >= 2 && call.first == "A" && "ABCDEFGHIJKL".contains(call.dropFirst().first ?? "_") {
            meta.country="K";meta.continent="NA";meta.cq=5;meta.itu=8
        }
        // The United States and Canada span several zones. Without per-station
        // data, the call area is the usual guide (as in CTY.DAT's defaults).
        if let area = call.last(where: { $0.isNumber }) {
            if meta.country == "K" {
                switch area {
                case "6","7": meta.cq=3;meta.itu=6
                case "5","9","0": meta.cq=4;meta.itu=7
                case "8": meta.cq=4;meta.itu=8
                default: meta.cq=5;meta.itu=8
                }
            } else if meta.country == "VE" {
                if call.hasPrefix("VO") { meta.cq = area == "2" ? 2 : 5;meta.itu=9 }
                else if call.hasPrefix("VY") {
                    switch area { case "1": meta.cq=1;meta.itu=2; case "2": meta.cq=5;meta.itu=9; default: meta.cq=2;meta.itu=4 }
                } else {
                    switch area {
                    case "1","9": meta.cq=5;meta.itu=9
                    case "2": meta.cq=5;meta.itu=4
                    case "3": meta.cq=4;meta.itu=4
                    case "4": meta.cq=4;meta.itu=3
                    case "5": meta.cq=4;meta.itu=3
                    case "6": meta.cq=4;meta.itu=2
                    case "7": meta.cq=3;meta.itu=2
                    case "8": meta.cq=1;meta.itu=3
                    default: break
                    }
                }
            }
        }
        if let index = call.firstIndex(where: { $0.isNumber }) { meta.prefix=String(call[...index]) }
        if let settings {
            // Longest matching user-imported prefix wins; exact-call history
            // always wins over that generic prefix below.
            if let key=settings.countryPrefixes.keys.filter({call.hasPrefix($0)}).max(by:{$0.count<$1.count}),
               let match=settings.countryPrefixes[key] {
                if !match.country.isEmpty {meta.country=match.country}
                if !match.continent.isEmpty {meta.continent=match.continent}
                if match.cq>0 {meta.cq=match.cq};if match.itu>0 {meta.itu=match.itu}
            }
        }
        if let settings, let record = settings.contestHistories[settings.contest.rawValue]?.records[normalizeCall(value)] ?? settings.customRecords[normalizeCall(value)] {
            if !record.country.isEmpty { meta.country=record.country }
            if !record.continent.isEmpty { meta.continent=record.continent }
            if record.cq > 0 { meta.cq=record.cq }; if record.itu > 0 { meta.itu=record.itu }
        }
        return meta
    }
    /// Callsign assistance, limited to what MRCE's status bar shows for the
    /// contest (`GetStationInfo` in each contest unit): the history file's
    /// user text and, where MRCE gives it, continent/entity. Exchange fields
    /// (class, section, check, zone) are never shown.
    public static func callsignInformation(_ value:String, settings:ContestSettings) -> CallsignInformation? {
        let call=normalizeCall(value)
        guard !call.isEmpty else { return nil }
        let meta=callMeta(call,settings:settings)
        let entity:String?=meta.known ? "\(meta.continent)/\(meta.country)" : nil
        let record=settings.contestHistories[settings.contest.rawValue]?.records[call]
            ?? settings.customRecords[call]
        var text=nonempty(record?.userText)
        var geography:String?
        switch settings.contest {
        case .sweepstakes, .allja, .acag: break
        case .fieldday: if record?.section.uppercased() == "DX" { geography=entity }
        case .naqp: if (record?.state ?? "").isEmpty { geography=entity }
        case .arrldx: if callMeta(settings.myCall,settings:settings).usve { geography=entity }
        case .cwt:
            // A non-member's user text would give away a US state or province.
            let member=record.map { !$0.cwops.isEmpty && $0.cwops.allSatisfy(\.isNumber) } ?? false
            if text == nil || (!member && meta.usve) { text=entity }
        case .sst:
            if text == nil, meta.country != callMeta(settings.myCall,settings:settings).country { text=entity }
        case .wpx, .cqww, .iaru, .arrl10, .hst, .pota: geography=entity
        }
        return CallsignInformation(call:call,geography:geography,contestHistory:text)
    }
    private static func nonempty(_ value:String?) -> String? {
        guard let value else { return nil }
        let trimmed=value.trimmingCharacters(in:.whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    /// WPX prefix, a port of MRCE `CallsignUtils.ExtractPrefix` with
    /// `DeleteTrailingLetters` set; `MRCEPrefixOracleTests` holds it to the
    /// compiled Pascal.
    public static func wpxPrefix(_ value:String) -> String {
        var call=normalizeCall(value)
        // Kill one trailing modifier, in MRCE's order, then collapse "//".
        for modifier in ["/QRP","/MM","/M","/P"] where call.hasSuffix(modifier) {
            call=String(call.dropLast(modifier.count))
        }
        while call.contains("//") {call=call.replacingOccurrences(of:"//",with:"/")}
        guard call.count >= 2 else {return ""}
        var digit:Character?
        var result:String
        if let slash=call.firstIndex(of:"/") {
            let first=String(call[..<slash]),second=String(call[call.index(after:slash)...])
            if first.isEmpty {result=second}
            else if second.isEmpty {result=first}
            else if first.count == 1,first.first!.isNumber {digit=first.first;result=second}
            else if second.count == 1,second.first!.isNumber {digit=second.first;result=first}
            else {result=first.count <= second.count ? first : second}
        } else {result=call}
        guard !result.contains("/"),!result.isEmpty else {return ""}
        // Delete trailing letters, keeping at least two characters.
        var chars=Array(result)
        var index=chars.count-1
        while index >= 2 {
            if chars[index].isNumber {break}
            chars.remove(at:index)
            index-=1
        }
        if chars.last?.isNumber != true {chars.append("0")}
        if let digit {chars[chars.count-1]=digit}
        return String(chars.prefix(5))
    }
    public static func sentExchange(_ settings:ContestSettings, serial:Int) -> String {
        sentExchange(settings,ownSerial:initialOwnSerial(settings)+max(0,serial-1))
    }
    /// Formats the exchange with the current own-counter value. Session code
    /// should use this overload for both TX events and saved log rows.
    public static func sentExchange(_ settings:ContestSettings,ownSerial:Int) -> String {
        let n = ownSerialText(settings,serial:ownSerial)
        let profile=settings.exchangeProfile()
        switch settings.contest {
        case .wpx,.hst: return "5NN \(n)"
        case .cqww: return "5NN \(profile.zoneText)"
        case .iaru:
            let exchange=profile.iaruExchangeMode == .society
                ? profile.ituSociety.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
                : profile.ituZoneText
            return "5NN \(exchange)"
        case .fieldday: return "\(profile.fdClass) \(callMeta(settings.myCall,settings:settings).hasARRLSection ? profile.section : "DX")".uppercased()
        case .sweepstakes: return "\(n) \(profile.precedence) \(normalizeCall(settings.myCall)) \(profile.check) \(profile.section)".uppercased()
        case .naqp:
            return (callMeta(settings.myCall,settings:settings).isNAQPLocal
                ? "\(profile.name) \(profile.state)" : profile.name).uppercased()
        case .sst: return "\(profile.name) \(callMeta(settings.myCall,settings:settings).usCanadaIncludingAlaskaHawaii ? profile.state : "DX")".uppercased()
        case .pota: return "5NN \(profile.state)".uppercased()
        case .cwt: return "\(profile.name) \(profile.cwopsNumber)".uppercased()
        case .allja: return "5NN \(profile.jaPrefecture)\(profile.jaPower)".uppercased()
        case .acag: return "5NN \(profile.jaCity)\(profile.jaPower)".uppercased()
        case .arrldx: return "5NN \(callMeta(settings.myCall,settings:settings).usve ? profile.state : profile.power)".uppercased()
        case .arrl10: return "5NN \(normalizeCall(settings.myCall).hasSuffix("/MM") || callMeta(settings.myCall,settings:settings).isARRL10Local ? profile.state : n)".uppercased()
        }
    }
    /// MRCE's operator serial width is contest specific. Keep the historical
    /// native preference for contests without a source-defined serial format.
    public static func ownSerialText(_ settings:ContestSettings,serial:Int) -> String {
        let value=String(max(0,serial))
        let minimumWidth:Int
        switch settings.contest {
        case .wpx,.hst: minimumWidth=3
        case .sweepstakes,.arrl10: minimumWidth=1
        default: minimumWidth=settings.serialPadding
        }
        return String(repeating:"0",count:max(0,minimumWidth-value.count))+value
    }
    /// Caller serial text follows MRCE Station.NrAsText. WPX Start and HST
    /// callers use three digits; a Custom WPX range can retain its entered
    /// minimum width or use the natural width of the lower endpoint.
    static func callerSerialText(_ settings:ContestSettings,serial:Int,customMinimumWidth:Int?=nil,naturalWidth:Int?=nil,useMinimumWidth:Bool=true)->String {
        let value=String(max(0,serial))
        let width:Int
        if settings.contest == .wpx || settings.contest == .hst {
            if settings.contest == .wpx, settings.serialRange == .custom {
                width=useMinimumWidth ? (customMinimumWidth ?? 1) : (naturalWidth ?? 1)
            } else { width=3 }
        } else if settings.contest == .sweepstakes || settings.contest == .arrl10 {
            width=1
        } else { width=settings.serialPadding }
        return String(repeating:"0",count:max(0,width-value.count))+value
    }
    static func callerSerialUsesMinimumWidth(rng:inout ContestRNG)->Bool { rng.random() < 0.5 }
    /// The operator's first serial: the profile's own value when one is set,
    /// otherwise the start the serial range produced. HST always starts at 1.
    public static func initialOwnSerial(_ settings:ContestSettings,generatedStart:Int=1)->Int {
        guard settings.contest != .hst else{return 1}
        return max(1,settings.exchangeProfile().firstSerial ?? generatedStart)
    }
    /// Validate the fields actually transmitted; inactive per-contest fields
    /// and inactive per-contest fields do not constrain the default formatter.
    public static func defaultSentExchangeValidationError(_ settings:ContestSettings)->String? {
        let text=sentExchange(settings,serial:1)
        let pattern:String
        switch settings.contest {
        case .wpx,.hst: pattern="5NN [0-9]+"
        case .cqww: pattern="5NN [0-9]{1,2}"
        case .iaru: pattern="5NN [A-Z0-9]+"
        case .fieldday: pattern="[1-9][0-9]*[A-F] [A-Z]{2,3}"
        case .sweepstakes: pattern="[0-9]+ [QABUMS] [A-Z0-9/]+ [0-9]{2} [A-Z]{2,3}"
        case .naqp:
            pattern=callMeta(settings.myCall,settings:settings).isNAQPLocal ? "[A-Z]+ [A-Z0-9/]+" : "[A-Z]+"
        case .sst,.cwt: pattern="[A-Z]+ [A-Z0-9/]+"
        case .arrldx: pattern=callMeta(settings.myCall,settings:settings).usve ? "5NN [A-Z]{2}" : "5NN ([0-9AOTN]+|K|KW)"
        case .arrl10:
            pattern=normalizeCall(settings.myCall).hasSuffix("/MM") ? "5NN [123]"
                : callMeta(settings.myCall,settings:settings).isARRL10Local ? "5NN [A-Z]{2,3}" : "5NN [0-9]+"
        case .allja: pattern="5NN [0-9]{2,3}[LMHP]"
        case .acag: pattern="5NN [0-9]{4,6}[LMHP]"
        case .pota: pattern="5NN [A-Z0-9/]+"
        }
        guard text.range(of:"^(?:"+pattern+")$",options:.regularExpression) != nil else {
            return "Complete the operator exchange fields for this contest."
        }
        if settings.contest == .cqww, !(1...40).contains(Int(tokens(text).last ?? "") ?? 0) {
            return "CQ zone must be between 1 and 40."
        }
        if settings.contest == .iaru, settings.exchangeProfile().iaruExchangeMode == .zone,
           !(1...90).contains(Int(tokens(text).last ?? "") ?? 0) {
            return "ITU zone must be between 1 and 90."
        }
        return nil
    }

    private static func isReportToken(_ text:String)->Bool {
        text == "TTN" || text.range(of:"^[1-5E][1-9N]{2}$",options:.regularExpression) != nil
    }
    private static func withoutReport(_ tokens:[String]) -> [String] {
        tokens.count > 1 && isReportToken(tokens[0]) ? Array(tokens.dropFirst()) : tokens
    }
    /// Delphi `StrToIntDef(text, 0)` for a logged field: digits only.
    private static func typedInteger(_ value:String) -> Int {
        let text=value.trimmingCharacters(in:.whitespaces)
        guard !text.isEmpty,text.allSatisfy({$0.isASCII && $0.isNumber}) else {return 0}
        return Int(text) ?? 0
    }
    private static func reduceCutDigits(_ value:String,includingO:Bool) -> String {
        String(value.uppercased().map { c -> Character in
            switch c { case "T": "0"; case "O": includingO ? "0" : "O"; case "A": "1"; case "N": "9"; default: c }
        })
    }
    /// MRCE's Enter path checks that exchange fields are present and have the
    /// expected contest structure before sending TU. Value correctness is
    /// diagnosed later, when the QSO is checked against the caller's exchange.
    public static func isExchangeStructurallyValid(_ s:ContestSettings, received:String, expected:String) -> Bool {
        let raw=tokens(received)
        guard !raw.isEmpty else { return false }
        // A report alone is the RST box without the exchange box (MRCE's R is
        // false), never a complete exchange.
        if s.contest.definition.usesRST, raw.count == 1, isReportToken(raw[0]) { return false }
        let reference=s.contest.definition.usesRST ? withoutReport(tokens(expected)) : tokens(expected)
        var fields=raw
        if s.contest.definition.usesRST, raw.count > 1,
           isReportToken(raw[0]) {
            fields=Array(raw.dropFirst())
        }
        switch s.contest {
        case .sweepstakes:
            guard fields.count >= 3 && fields.count <= 5,
                  fields[fields.count-2].count == 2,
                  fields.last!.count >= 2 && fields.last!.count <= 3,
                  fields.last!.allSatisfy({$0.isLetter}) else { return false }
            let prefix=Array(fields.dropLast(2))
            let precedences=prefix.indices.filter { ["Q","A","B","U","M","S"].contains(prefix[$0]) }
            guard precedences.count == 1, let precedence=precedences.first else { return false }
            let before=Array(prefix[..<precedence]), after=Array(prefix.dropFirst(precedence+1))
            let serialValid=before.isEmpty || (before.count == 1 &&
                (before[0] == "#" || before[0].allSatisfy({$0.isNumber})))
            let callValid=after.isEmpty || (after.count == 1 && after[0].count >= 3 &&
                after[0].contains(where:{$0.isLetter}) && after[0].contains(where:{$0.isNumber}) &&
                after[0].allSatisfy({$0.isLetter || $0.isNumber || $0 == "/" || $0 == "?"}))
            return serialValid && callValid
        case .fieldday:
            return fields.count == 2 && fields[0].count > 1 && fields[1].count > 1
        case .naqp:
            return (fields.count == 2 && fields[0].count > 1 && !fields[1].isEmpty) ||
                (fields.count == 1 && reference.count == 1 && fields[0].count > 1)
        case .sst:
            return fields.count == 2 && fields[0].count > 1 && fields[1].count > 1
        case .cwt:
            return fields.count == 2 && fields[0].count > 1 && !fields[1].isEmpty
        case .allja:
            return fields.count == 1 && fields[0].count > 2
        case .acag:
            return fields.count == 1 && fields[0].count > 3
        case .arrldx,.arrl10:
            guard fields.count == reference.count, let field=fields.first else { return false }
            // CE configures State/Prov as a two-character field and power or
            // serial as a nonempty field. The expected station exchange tells
            // which of those field types applies to this contact.
            let expectedField=reference.first ?? ""
            let isState=expectedField.count == 2 && expectedField.allSatisfy({$0.isLetter})
            return isState ? field.count > 1 : !field.isEmpty
        default:
            return fields.count == reference.count && !fields.isEmpty && fields.allSatisfy({!$0.isEmpty})
        }
    }
    public struct ExchangeCheck: Sendable { public var valid:Bool, errors:[String] }
    public static func checkExchange(_ s:ContestSettings, received:String, expected:String, callerCall:String = "") -> ExchangeCheck {
        let rawRX=tokens(received),rawReference=tokens(expected)
        var rx=s.contest.definition.usesRST ? withoutReport(rawRX) : rawRX
        var ref=s.contest.definition.usesRST ? withoutReport(rawReference) : rawReference
        var errors:[String] = []
        // Preserve MRCE's separate RST/NR diagnosis after the two entry
        // controls are joined for contest validation. A mistyped 579 003 is an RST bust, NOT a
        // serial-number error. MRCE stores the report with StrToIntDef, so it
        // must be typed in digits: 5NN is an RST error.
        if s.contest.definition.usesRST,rawRX.count>1,rawReference.count>1 {
            let first=rawRX[0]
            let hasReport=isReportToken(first)
            if hasReport {
                if typedInteger(first) != typedInteger(rawReference[0]) {errors.append(DiagnosticText.rst)}
                rx=Array(rawRX.dropFirst())
                ref=withoutReport(rawReference)
            }
        }
        // How MRCE reads each logged field (Contest.SaveEnteredExchToQso and
        // Log.CheckExch2). Cut numbers are accepted only where MRCE reduces
        // them; everywhere else the operator must type what the letters mean.
        enum Reading {
            case exact          // string compare
            case digits         // StrToIntDef: digits only, leading zeros ignored
            case reduced        // T,O->0 A->1 N->9, then StrToIntDef (CQ zone)
            case serialReduced  // T->0 A->1 N->9, then StrToIntDef (ARRL 10m serial)
        }
        func matches(_ lhs:String,_ rhs:String,_ reading:Reading) -> Bool {
            switch reading {
            case .exact: return lhs == rhs
            case .digits: return typedInteger(lhs) == typedInteger(rhs)
            case .reduced: return typedInteger(reduceCutDigits(lhs,includingO:true)) == typedInteger(reduceCutDigits(rhs,includingO:true))
            case .serialReduced: return typedInteger(reduceCutDigits(lhs,includingO:false)) == typedInteger(rhs)
            }
        }
        func compare(_ title:String,_ lhs:String?,_ rhs:String?,_ reading:Reading = .exact) {
            guard let lhs,let rhs, !lhs.isEmpty, !rhs.isEmpty, matches(lhs,rhs,reading) else { errors.append(title); return }
        }
        switch s.contest {
        case .sweepstakes:
            guard (rx.count == 4 || rx.count == 5) && ref.count == 5 else {
                return ExchangeCheck(valid:false,errors:["SS format: NR PREC [CALL] CHECK SECTION"])
            }
            let withCall = rx.count == 5
            compare(DiagnosticText.serial,rx[0],ref[0],.digits);compare("Precedence",rx[1],ref[1])
            if withCall {compare("Call",rx[2],ref[2])}
            compare("Check",rx[withCall ? 3 : 2],ref[3],.digits)
            compare("Section",rx[withCall ? 4 : 3],ref[4])
        case .naqp where ref.count == 1:
            compare("First field",rx.first,ref.first)
            if rx.count > 2 || (rx.count == 2 && rx[1] != "DX") {errors.append("Second field")}
        case .fieldday,.naqp,.sst,.cwt:
            compare("First field",rx.first,ref.first)
            if ref.count > 1 {compare("Second field",rx.dropFirst().first,ref.dropFirst().first)}
            if rx.count != ref.count { errors.append("Field count") }
        default:
            if rx.count != 1 || ref.count != 1 { errors.append("Exchange format") }
            if s.contest == .arrldx, let received=rx.first, let expected=ref.first,
               expected.contains(where:{$0.isNumber}) || ["KW","K"].contains(expected) {
                func power(_ value:String)->String {
                    value.replacingOccurrences(of:"T",with:"0").replacingOccurrences(of:"O",with:"0")
                        .replacingOccurrences(of:"A",with:"1").replacingOccurrences(of:"N",with:"9")
                }
                compare(DiagnosticText.exchange,power(received),power(expected))
            } else {
                let reading:Reading
                switch s.contest {
                case .wpx,.hst: reading = .digits
                case .cqww: reading = .reduced
                case .arrl10 where ref.first?.allSatisfy({$0.isNumber}) == true &&
                    !normalizeCall(callerCall).hasSuffix("/MM"): reading = .serialReduced
                // IARU zone or society, ALLJA, ACAG, states and ITU regions.
                default: reading = .exact
                }
                compare(DiagnosticText.exchange,rx.first,ref.first,reading)
            }
        }
        return ExchangeCheck(valid:errors.isEmpty,errors:errors)
    }
    public struct Scoring: Sendable { public var points:Int, multipliers:[String] }
    public static func score(_ settings:ContestSettings,station:Station) -> Scoring {
        let dx=callMeta(station.call,settings:settings), me=callMeta(settings.myCall,settings:settings)
        let known=dx.known && me.known
        switch settings.contest {
        case .wpx: return .init(points:1,multipliers:["P:\(wpxPrefix(station.call))"])
        case .cqww:
            if station.call.hasSuffix("/MM") { return .init(points:0,multipliers:dx.cq > 0 ? ["Z:\(dx.cq)"] : []) }
            let points = !known ? 0 : me.continent != dx.continent ? 3 : me.country != dx.country ? (me.continent == "NA" && dx.continent == "NA" ? 2 : 1) : 0
            // CqWW.pas counts Alaska and Hawaii as the United States for the
            // country multiplier; they still score as their own entities.
            let entity=["KL7","KH6"].contains(dx.country) ? "K" : dx.country
            return .init(points:points,multipliers: known && dx.cq > 0 ? ["C:\(entity)","Z:\(dx.cq)"] : [])
        case .arrldx:
            return .init(points:known && me.usve != dx.usve ? 3 : 0,multipliers:known && me.usve && !dx.usve ? ["DX:\(dx.country)"] : known && !me.usve && dx.usve ? ["S:\(station.state)"] : [])
        case .fieldday: return .init(points:2,multipliers:["CONST:1"])
        case .sweepstakes: return .init(points:2,multipliers:station.section.isEmpty ? [] : ["SEC:\(station.section)"])
        case .naqp: return .init(points:1,multipliers:dx.isNAQPLocal && !station.state.isEmpty ? ["S:\(station.state)"] : [])
        case .cwt: return .init(points:1,multipliers:["CALL:\(normalizeCall(station.call))"])
        case .sst: return .init(points:1,multipliers:station.state != "DX" && !station.state.isEmpty ? ["S:\(station.state)"] : known ? ["DX:\(dx.country)"] : [])
        case .iaru:
            let record=settings.contestHistories["iaru"]?.records[station.call] ?? settings.customRecords[station.call]
            let text = withoutReport(tokens(station.exchange)).first ?? ""
            let got = !(record?.society ?? "").isEmpty ? record!.society : (record?.itu ?? 0) > 0 ? String(record!.itu) : text
            let own = withoutReport(tokens(sentExchange(settings,serial:1))).first ?? ""
            let same = Int(got) != nil && Int(own) != nil ? Int(got) == Int(own) : got == own
            let hq = !((record?.society ?? "").isEmpty) || Int(got) == nil
            return .init(points:hq || same ? 1 : !known ? 1 : me.continent == dx.continent ? 3 : 5,multipliers:got.isEmpty || got == "0" ? [] : ["\(hq ? "HQ" : "I"):\(Int(got).map(String.init) ?? got)"])
        case .allja: return .init(points:1,multipliers:station.jaPref.isEmpty ? [] : ["JA:\(station.jaPref)"])
        case .acag: return .init(points:1,multipliers:station.jaCity.isEmpty ? [] : ["JA:\(station.jaCity)"])
        case .arrl10:
            let mult=station.call.hasSuffix("/MM") ? "ITU:\(withoutReport(tokens(station.exchange)).first ?? station.state)" : dx.isARRL10Local ? "S:\(station.state)" : "DX:\(dx.country)"
            return .init(points:4,multipliers:!known && !station.call.hasSuffix("/MM") ? [] : [mult])
        case .hst: return .init(points:hstCallScore(station.call),multipliers:[])
        case .pota: return .init(points:1,multipliers:station.state.isEmpty ? [] : ["POTA:\(station.state)"])
        }
    }
    private static let morse:[Character:String] = ["A":".-","B":"-...","C":"-.-.","D":"-..","E":".","F":"..-.","G":"--.","H":"....","I":"..","J":".---","K":"-.-","L":".-..","M":"--","N":"-.","O":"---","P":".--.","Q":"--.-","R":".-.","S":"...","T":"-","U":"..-","V":"...-","W":".--","X":"-..-","Y":"-.--","Z":"--..","0":"-----","1":".----","2":"..---","3":"...--","4":"....-","5":".....","6":"-....","7":"--...","8":"---..","9":"----.","/":"-..-.","?":"..--.."]
    public static func morseSymbols(_ character:Character) -> String { morse[Character(String(character).uppercased())] ?? "" }
    public static func cwSeconds(_ text:String,wpm:Int) -> Double {
        MorseTimeline.duration(text,wpm:wpm)
    }
    public static func hstCallScore(_ call:String) -> Int {
        var points = -1
        for c in normalizeCall(call) {
            let symbols = morseSymbols(c)
            for element in symbols { points += element == "." ? 2 : 4 }
            if !symbols.isEmpty { points += 2 }
        }
        return max(0,points-2)
    }
}
