//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import Foundation

public enum ImportError: Error, CustomStringConvertible {
    case invalid(String)
    public var description:String {switch self {case let .invalid(value):value}}
}
public enum HistoryImport {
    /// Returns the usable Sweepstakes check and section for an imported call.
    /// Missing or partial records are deliberately not treated as hints.
    public static func sweepstakesCheckSection(for call:String,in history:ImportedHistory) -> String? {
        let normalized=ContestRules.normalizeCall(call)
        guard history.calls.contains(normalized),let record=history.records[normalized],
              let check=Int(record.check),record.check.count == 2,(0...99).contains(check),
              SweepstakesParser.sections.contains(record.section) else { return nil }
        return String(format:"%02d %@",check,record.section)
    }
    /// Decode comma-separated MRCE history records. Quotes may enclose commas;
    /// a quote inside a quoted field is represented by two consecutive quotes.
    private static func parseCSVRecords(_ text: String) throws -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var quoted = false
        var closedQuote = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if quoted {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\""); i += 1
                    } else { quoted = false; closedQuote = true }
                } else { field.append(ch) }
            } else if closedQuote {
                if ch == "," {
                    record.append(field); field = ""; closedQuote = false
                } else if ch == "\r" || ch == "\n" {
                    record.append(field); records.append(record)
                    record = []; field = ""; closedQuote = false
                    if ch == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                } else if ch.isWhitespace {
                    // Permit whitespace after a closing quote before delimiter.
                } else { throw ImportError.invalid("Unexpected character after quoted CSV field") }
            } else if ch == "," {
                record.append(field); field = ""
            } else if ch == "\r" || ch == "\n" {
                record.append(field); records.append(record)
                record = []; field = ""
                if ch == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
            } else if ch == "\"" {
                guard field.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ImportError.invalid("Quote inside unquoted CSV field")
                }
                field = ""; quoted = true
            } else { field.append(ch) }
            i += 1
        }
        guard !quoted else { throw ImportError.invalid("Unclosed quoted CSV field") }
        if closedQuote || !record.isEmpty || !field.isEmpty {
            record.append(field); records.append(record)
        }
        return records
    }
    public static func isCall(_ input:String) -> Bool {
        let call=ContestRules.normalizeCall(input)
        return call.count >= 3 && call.count <= 20 && call.contains(where:{$0.isNumber}) &&
            call.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "/") })
    }
    public static func masterDTA(_ bytes:[UInt8]) throws -> ImportedHistory {
        let entries=37*37+1,header=entries*4
        guard bytes.count >= header else {throw ImportError.invalid("MASTER.DTA has no index")}
        func offset(_ i:Int) -> Int {
            let p=i*4
            return Int(bytes[p]) | Int(bytes[p+1])<<8 | Int(bytes[p+2])<<16 | Int(bytes[p+3])<<24
        }
        guard offset(0)==header && offset(entries-1)==bytes.count else {throw ImportError.invalid("MASTER.DTA index offsets do not match file")}
        var prior=header
        for i in 0..<entries {let n=offset(i);guard n>=prior && n<=bytes.count else {throw ImportError.invalid("MASTER.DTA unsorted offsets")};prior=n}
        var history=ImportedHistory();history.sourceName="MRCE MASTER.DTA"
        var seen:Set<String>=[],begin=header
        for index in header...bytes.count where index == bytes.count || bytes[index]==0 {
            if index > begin {
                let call=String(decoding:bytes[begin..<index],as:UTF8.self).uppercased().trimmingCharacters(in:.whitespacesAndNewlines)
                if isCall(call) && !seen.contains(call) && !call.hasPrefix("VER2") {seen.insert(call);history.calls.append(call)}
            }
            begin=index+1
        }
        guard !history.calls.isEmpty else {throw ImportError.invalid("MASTER.DTA has no valid calls")}
        return history
    }
    public static func mrceHistory(_ text:String,contest:ContestID) throws -> ImportedHistory {
        let rows = try parseCSVRecords(text)
        guard let headerIndex = rows.firstIndex(where: { $0.first?.trimmingCharacters(in: .whitespaces).uppercased() == "!!ORDER!!" }) else {throw ImportError.invalid("Missing !!Order!! header")}
        let fields=rows[headerIndex].dropFirst().map{$0.uppercased().trimmingCharacters(in:.whitespaces)}
        guard fields.contains("CALL") else {throw ImportError.invalid("Call column missing")}
        // SST uses the MRCE positional exchange contract: Call, Name, Exch1,
        // UserText. Keep the generic named-column readers below for other
        // contests and for named SST exports with reordered columns.
        if contest == .sst {
            guard fields.count >= 3,
                  let callIndex = fields.firstIndex(of: "CALL"),
                  let nameIndex = fields.firstIndex(of: "NAME"),
                  let exchangeIndex = fields.firstIndex(of: "EXCH1") else {
                throw ImportError.invalid("SST history requires Call, Name, and Exch1 columns")
            }
            var history=ImportedHistory();history.sourceName="MRCE \(contest.label) history"
            for rowValues in rows.dropFirst(headerIndex + 1) {
                if rowValues.allSatisfy({$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) || rowValues.first?.trimmingCharacters(in:.whitespaces).hasPrefix("#") == true {continue}
                let values=rowValues
                guard values.indices.contains(callIndex), values.indices.contains(nameIndex), values.indices.contains(exchangeIndex) else {continue}
                let call=values[callIndex].trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
                let name=values[nameIndex].trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
                let state=values[exchangeIndex].trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
                guard isCall(call), !name.isEmpty, name.count <= 10, !state.isEmpty, state.count <= 5 else {continue}
                var record=HistoryRecord(call:call)
                record.name=name
                record.state=state
                if let userIndex=fields.firstIndex(where:{["USERTEXT","USER_TEXT"].contains($0)}),values.indices.contains(userIndex) {
                    let userText=values[userIndex]
                    if !userText.isEmpty {record.userText=userText}
                }
                if history.records[call] == nil {history.calls.append(call)}
                history.records[call]=record
                history.rows.append(record)
            }
            guard !history.calls.isEmpty else {throw ImportError.invalid("No valid SST history rows (Call, Name, and Exch1 are required; Name max 10, Exch1 max 5)")}
            history.rows.sort { $0.call < $1.call }
            return history
        }
        var history=ImportedHistory();history.sourceName="MRCE \(contest.label) history"
        var seen:Set<String>=[]
        for rowValues in rows.dropFirst(headerIndex + 1) {
            if rowValues.allSatisfy({$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) || rowValues.first?.trimmingCharacters(in:.whitespaces).hasPrefix("#") == true {continue}
            let values=rowValues.map{$0.uppercased().trimmingCharacters(in:.whitespaces)}
            guard let callIndex=fields.firstIndex(of:"CALL"), values.indices.contains(callIndex) else {continue}
            let call=values[callIndex]
            guard isCall(call) else {continue}
            if !seen.contains(call) {history.calls.append(call);seen.insert(call)}
            func get(_ names:String...) -> String {
                for name in names {if let i=fields.firstIndex(of:name),values.indices.contains(i),!values[i].isEmpty {return values[i]}}
                return ""
            }
            var rec=history.records[call] ?? HistoryRecord(call:call)
            rec.name=get("NAME");rec.state=get("STATE","ST");rec.section=get("SECT","SECTION")
            rec.fdClass=get("CLASS");rec.power=get("POWER","PWR")
            let userText=get("USERTEXT","USER_TEXT","CLUB")
            if !userText.isEmpty {rec.userText=userText}
            let exch1=get("EXCH1","EXCH","NR"),exch2=get("EXCH2")
            switch contest {
            case .fieldday:
                if !exch1.isEmpty {rec.fdClass=exch1}
                if rec.section.isEmpty {rec.section=exch2}
            case .cwt: rec.cwops = exch1.isEmpty ? get("CWOPS","CWOPSNR") : exch1
            case .sst,.naqp:if rec.name.isEmpty {rec.name=exch1};if rec.state.isEmpty {rec.state=exch2}
            case .arrldx:
                if ContestRules.callMeta(call).usve {
                    if rec.state.isEmpty {rec.state=exch1}
                } else if rec.power.isEmpty {rec.power=exch1}
            case .arrl10: if rec.state.isEmpty {rec.state=exch1}
            case .sweepstakes:
                let parts=exch1.split(separator:" ").map(String.init)
                if parts.count>1 {rec.precedence=parts[0];rec.check=parts[1]}
                if rec.section.isEmpty {rec.section=exch2}
                let ck=get("CK","CHECK"),prec=get("PREC","PRECEDENCE")
                if !ck.isEmpty {rec.check=ck};if !prec.isEmpty {rec.precedence=prec}
            case .cqww:rec.cq=Int(get("CQZONE","CQ_ZONE","ZONE")) ?? Int(exch1) ?? 0
            case .iaru:
                let zone=get("SECT","ITUZONE","ITU_ZONE")
                if let n=Int(zone.isEmpty ? exch1 : zone) {rec.itu=n}
                else {rec.society=zone.isEmpty ? exch1 : zone}
            case .allja:
                rec.jaPref=String(exch1.prefix(while:{$0.isNumber}))
                if let power=exch1.last, "LMHP".contains(power) {rec.jaPower=String(power)}
            case .acag:
                rec.jaCity=String(exch1.prefix(while:{$0.isNumber}))
                if let power=exch1.last, "LMHP".contains(power) {rec.jaPower=String(power)}
            default:break
            }
            history.records[call]=rec
        }
        guard !history.calls.isEmpty else {throw ImportError.invalid("No valid callsigns")}
        return history
    }
    public static func arrl10TSV(_ text:String) throws -> ImportedHistory {
        let lines=text.replacingOccurrences(of:"\r",with:"").components(separatedBy:"\n")
        guard let header=lines.firstIndex(where:{$0.lowercased().hasPrefix("cabrillo_id\tyear\tcall\t")}) else {throw ImportError.invalid("Expected ARRL 10 Meter TSV")}
        let columns=lines[header].lowercased().components(separatedBy:"\t")
        let sections:[String:String]=["EMA":"MA","WMA":"MA","ENY":"NY","NLI":"NY","WNY":"NY","EPA":"PA","WPA":"PA","NNJ":"NJ","SNJ":"NJ","NFL":"FL","SFL":"FL","WCF":"FL","SCV":"CA","SDG":"CA","LAX":"CA","SB":"CA","STX":"TX","NTX":"TX","WTX":"TX","EWA":"WA","WWA":"WA","NNY":"NY","EB":"CA","ORG":"CA","SF":"CA","SJV":"CA","SV":"CA","GTA":"ON","GH":"ON","ONE":"ON","ONN":"ON","ONS":"ON","TER":"NT","NWT":"NT"]
        var history=ImportedHistory();history.sourceName="ARRL 10 Meter TSV"
        for row in lines.dropFirst(header+1) {
            let values=row.components(separatedBy:"\t")
            func get(_ key:String)->String {guard let i=columns.firstIndex(of:key),values.indices.contains(i) else {return ""};return values[i].uppercased().trimmingCharacters(in:.whitespaces)}
            let call=get("call")
            guard isCall(call),history.records[call]==nil else {continue}
            var rec=HistoryRecord(call:call);let section=get("section")
            rec.state=sections[section] ?? section;rec.country=get("dxcc")
            history.calls.append(call);history.records[call]=rec
        }
        guard !history.calls.isEmpty else {throw ImportError.invalid("No valid calls")}
        return history
    }
    /// MRCE Field Day club-selection policy. Call history remains untouched;
    /// eligible callers form a new per-session pool in original source order.
    public static func fieldDayEligibleCalls(_ history:ImportedHistory,rng:inout ContestRNG) -> [String] {
        var clubs:[String:String]=[:],orphans:[String:[String]]=[:],picked:[String]=[]
        func transmitters(_ call:String) -> Int {
            Int(history.records[call]?.fdClass.prefix(while:{$0.isNumber}) ?? "") ?? 0
        }
        for call in history.calls {
            guard let record=history.records[call],!record.fdClass.isEmpty else {picked.append(call);continue}
            let kind=record.fdClass.uppercased().last ?? "?"
            let club=record.userText?.uppercased().trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            if !["B","D","E"].contains(kind) {
                if club.isEmpty {picked.append(call)}
                else if let old=clubs[club] {
                    if transmitters(call)>transmitters(old) {clubs[club]=call}
                } else {clubs[club]=call}
            } else if !club.isEmpty {orphans[club,default:[]].append(call)}
            else if rng.random()<0.25 {picked.append(call)}
        }
        // Swift dictionaries do not preserve insertion order as a public
        // contract; enumerate source calls to preserve the source JS Map order.
        var seenClubs:Set<String>=[]
        for call in history.calls {
            guard let club=history.records[call]?.userText?.uppercased().trimmingCharacters(in:.whitespacesAndNewlines),
                  !club.isEmpty,!seenClubs.contains(club),let winner=clubs[club] else {continue}
            picked.append(winner);seenClubs.insert(club)
        }
        var seenOrphans:Set<String>=[]
        for call in history.calls {
            guard let club=history.records[call]?.userText?.uppercased().trimmingCharacters(in:.whitespacesAndNewlines),
                  !club.isEmpty,!seenOrphans.contains(club),clubs[club] == nil,
                  let list=orphans[club],!list.isEmpty else {continue}
            seenOrphans.insert(club)
            let maximum=list.map(transmitters).max() ?? 0
            let top=list.filter{transmitters($0)==maximum}
            let chosen=top[rng.int(0,top.count-1)]
            if history.records[chosen]?.fdClass.uppercased().hasSuffix("B") == true || rng.random()<0.25 {picked.append(chosen)}
        }
        return picked
    }
    /// Import an independently obtained, redistributable-by-the-user prefix CSV.
    /// Syntax: PREFIX,COUNTRY,CONTINENT,CQ_ZONE,ITU_ZONE. We do not ship CTY.DAT.
    public static func prefixCSV(_ text:String) throws -> [String:HistoryRecord] {
        let lines=text.replacingOccurrences(of:"\r",with:"").components(separatedBy:"\n")
        guard let first=lines.first?.uppercased().replacingOccurrences(of:" ",with:"").trimmingCharacters(in:.whitespacesAndNewlines),
              first == "PREFIX,COUNTRY,CONTINENT,CQ_ZONE,ITU_ZONE" else {
            throw ImportError.invalid("Expected PREFIX,COUNTRY,CONTINENT,CQ_ZONE,ITU_ZONE header")
        }
        let continents:Set<String>=["NA","SA","EU","AF","AS","OC","AN"]
        var prefixes:[String:HistoryRecord]=[:]
        for line in lines.dropFirst() {
            let row=line.trimmingCharacters(in:.whitespacesAndNewlines)
            if row.isEmpty || row.hasPrefix("#") {continue}
            let cells=row.uppercased().components(separatedBy:",").map{$0.trimmingCharacters(in:.whitespaces)}
            guard cells.count==5 else {throw ImportError.invalid("Invalid prefix CSV row: \(row)")}
            let key=ContestRules.normalizeCall(cells[0]);let country=cells[1],continent=cells[2]
            guard !key.isEmpty,key == cells[0],!key.contains("/"),
                  !country.isEmpty,continents.contains(continent),
                  let cq=Int(cells[3]), (1...40).contains(cq),
                  let itu=Int(cells[4]),(1...90).contains(itu) else {
                throw ImportError.invalid("Invalid geography for prefix: \(row)")
            }
            var record=HistoryRecord(call:key)
            record.country=country;record.continent=continent;record.cq=cq;record.itu=itu
            prefixes[key]=record
        }
        guard !prefixes.isEmpty else {throw ImportError.invalid("Prefix CSV is empty")}
        return prefixes
    }
    public static func callsText(_ text:String) throws -> ImportedHistory {
        var history=ImportedHistory();history.sourceName="Local callsign list"
        var seen:Set<String>=[]
        for token in text.uppercased().split(whereSeparator:{$0.isWhitespace || $0 == "," || $0 == ";"}) {
            let call=String(token)
            if isCall(call) && !seen.contains(call) {seen.insert(call);history.calls.append(call)}
        }
        guard !history.calls.isEmpty else {throw ImportError.invalid("No valid calls")}
        return history
    }
    /// Parse the published plain-text Super Check Partial caller list. The
    /// file contains calls as text, so ignore comment/header rows and accept
    /// only tokens that pass the same strict callsign checks as user imports.
    public static func superCheckPartial(_ text:String) throws -> ImportedHistory {
        let normalized=text.replacingOccurrences(of:"\r",with:"")
        let prefix=normalized.prefix(4096).lowercased()
        guard !prefix.contains("<!doctype html"), !prefix.contains("<html"),
              !prefix.contains("<head"), !prefix.contains("<body"),
              !prefix.contains("<script"), !prefix.contains("<title") else {
            throw ImportError.invalid("SCP response is HTML, not a callsign list")
        }
        var history=ImportedHistory();history.sourceName="Super Check Partial"
        var seen:Set<String>=[]
        var sawOfficialHeader=false
        for rawLine in normalized.components(separatedBy:"\n") {
            let line=rawLine.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !line.isEmpty,
                  !line.hasPrefix("#"),!line.hasPrefix(";") else {continue}
            // MASTER.SCP identifies its one-call-per-line format explicitly.
            if line.hasPrefix("!") {
                if line.uppercased() == "!!ORDER,1,1" { sawOfficialHeader=true }
                continue
            }
            let content=line.split(separator:";",maxSplits:1,omittingEmptySubsequences:false).first ?? ""
            for rawToken in content.split(whereSeparator:{$0.isWhitespace || $0 == ","}) {
                let call=String(rawToken).uppercased()
                guard isCall(call),!seen.contains(call) else {continue}
                seen.insert(call);history.calls.append(call)
            }
        }
        guard sawOfficialHeader else {throw ImportError.invalid("SCP list is missing the !!Order,1,1 header")}
        guard history.calls.count >= 2 else {throw ImportError.invalid("SCP list has fewer than two valid callsigns")}
        return history
    }
}
