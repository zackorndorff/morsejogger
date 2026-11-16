//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

public struct SweepstakesProgress: Sendable {
    public var serial="", precedence="", call="", check="", section="", correctedCall=""
    public var errors:[String]=[]
    public var complete:Bool { !serial.isEmpty && !precedence.isEmpty && check.count == 2 && !section.isEmpty && errors.isEmpty }
    public var next:String { serial.isEmpty ? "Serial" : precedence.isEmpty ? "Precedence" : check.isEmpty ? "Check" : section.isEmpty ? "Section" : complete ? "Complete" : "Correct the exchange" }
    public var summary:String { "NR: \(serial) · PREC: \(precedence) · CALL: \(call) · CK: \(check) · SEC: \(section)" }
}

/// Port of MRCE's `TSSExchParser` (`Util/SSExchParser.pas`), which follows
/// N1MM's Sweepstakes entry rules: fields may be typed in any order, run
/// together (`10A20OR`), and corrected by typing the field again, with the
/// later value winning. Numbers are digits only. Checked against MRCE's own
/// test cases in `MRCESweepstakesParserTests`.
public enum SweepstakesParser {
    public static let sections:Set<String> = Set(orderedSections)
    /// `ArrlSections.SectionsTbl`: the current ARRL and RAC sections.
    public static let orderedSections:[String] = ("CO IA KS MN MO ND NE SD CT EMA ME NH RI VT WMA ENY NLI NNJ NNY SNJ WNY DE EPA MDC WPA " +
        "AL GA KY NC NFL SC SFL TN VA WCF PR VI AR LA MS NM NTX OK STX WTX EB LAX ORG SB SCV SDG SF SJV SV PAC " +
        "AK AZ EWA ID MT NV OR UT WWA WY MI OH WV IL IN WI AB BC GH MB NB NL NS ONE ONN ONS PE QC SK TER")
        .split(separator:" ").map(String.init)

    private enum Kind { case digit1, digit2, digits, alpha, callsign, precedence, section }
    private struct Token { var kind:Kind, value:String }

    private static func isLetter(_ c:Character) -> Bool { c >= "A" && c <= "Z" }
    private static func isDigit(_ c:Character) -> Bool { c >= "0" && c <= "9" }
    private static func isWord(_ c:Character) -> Bool { isLetter(c) || isDigit(c) || c == "_" }

    /// The lexer's callsign rule at `start`, or nil. The Pascal pattern is
    /// `(?<=\b)([A-Z\d]{2,}/)?([A-Z]{1,2}|\d[A-Z]|[A-Z]\d|\d[A-Z]{2})([0-9])([A-Z\d]*[A-Z])(/[A-Z\d]+)?(/[A-Z\d]+)?\b`.
    private static func callsignEnd(_ text:[Character], at start:Int) -> Int? {
        if start > 0 && isWord(text[start-1]) { return nil }
        func alnum(_ i:Int) -> Bool { i < text.count && (isLetter(text[i]) || isDigit(text[i])) }
        func run(from i:Int) -> Int { var j=i; while alnum(j) { j+=1 }; return j }
        func body(from i:Int) -> Int? {
            // prefix alternatives in pattern order, then a digit, then a run ending in a letter
            let letter={ (k:Int) in k < text.count && isLetter(text[k]) }, digit={ (k:Int) in k < text.count && isDigit(text[k]) }
            var prefixEnds:[Int]=[]
            if letter(i) && letter(i+1) { prefixEnds.append(i+2) }
            if letter(i) { prefixEnds.append(i+1) }
            if digit(i) && letter(i+1) { prefixEnds.append(i+2) }
            if letter(i) && digit(i+1) { prefixEnds.append(i+2) }
            if digit(i) && letter(i+1) && letter(i+2) { prefixEnds.append(i+3) }
            for p in prefixEnds where digit(p) {
                var end=run(from:p+1)
                guard end > p+1, isLetter(text[end-1]) else { continue }
                for _ in 0..<2 where end < text.count && text[end] == "/" && alnum(end+1) { end=run(from:end+1) }
                return end
            }
            return nil
        }
        let lead=run(from:start)
        if lead-start >= 2, lead < text.count, text[lead] == "/", let end=body(from:lead+1) { return end }
        return body(from:start)
    }

    /// `TSSLexer.NextToken` over the whole text. Nil means the lexer raised
    /// "Invalid data", with the offending character and its 1-based position.
    private static func lex(_ text:[Character]) -> (tokens:[Token], error:String?) {
        var tokens:[Token]=[], i=0
        while true {
            while i < text.count, text[i].isWhitespace { i+=1 }
            guard i < text.count else { return (tokens,nil) }
            if let end=callsignEnd(text,at:i) { tokens.append(Token(kind:.callsign,value:String(text[i..<end])));i=end;continue }
            if isDigit(text[i]) {
                var j=i; while j < text.count, isDigit(text[j]) { j+=1 }
                // `\d\d\d+`, then `\d\d`, then `\d`
                let length=j-i >= 3 ? j-i : min(j-i,2)
                let value=String(text[i..<i+length])
                if length >= 3 { tokens.append(Token(kind:.digits,value:value)) }
                else if length == 2 { tokens.append(Token(kind:.digit2,value:value)) }
                else if value == "0" { tokens.append(Token(kind:.digit2,value:"00")) }
                else { tokens.append(Token(kind:.digit1,value:value)) }
                i+=length;continue
            }
            if isLetter(text[i]) {
                var j=i; while j < text.count, isLetter(text[j]) { j+=1 }
                let value=String(text[i..<j])
                let kind:Kind = value.count == 1 && "QABUMS".contains(value) ? .precedence : sections.contains(value) ? .section : .alpha
                tokens.append(Token(kind:kind,value:value));i=j;continue
            }
            return (tokens,"Invalid data (\(text[i])) at position \(i+1)")
        }
    }

    public static func parse(call:String, exchange:String) -> SweepstakesProgress {
        var result=SweepstakesProgress(); result.call=ContestRules.normalizeCall(call)
        let lexed=lex(Array(exchange.uppercased()))
        if let error=lexed.error { result.errors=[error];return result }

        // Pass 1: a callsign in the exchange replaces the call; the last one wins.
        var tokens:[Token]=[]
        for token in lexed.tokens {
            if token.kind == .callsign { result.correctedCall=token.value;result.call=token.value }
            else { tokens.append(token) }
        }

        // Pass 2: token indices stand in for the Pascal token references.
        var nr:Int?, precedence:Int?, check:Int?, section:Int?
        var twoDigit:[Int]=[], checkStack=0, unboundNRs:[Int]=[]
        var nrIsBound=false, skipNext=false
        func next(_ i:Int, _ kinds:[Kind], lengths:ClosedRange<Int>) -> Bool {
            i+1 < tokens.count && kinds.contains(tokens[i+1].kind) && lengths.contains(tokens[i+1].value.count)
        }
        for i in tokens.indices {
            if skipNext { skipNext=false;continue }
            switch tokens[i].kind {
            case .digit1,.digits:
                if (Int(tokens[i].value) ?? 10_001) > 10_000 { tokens[i].value="10000" }
                if next(i,[.section,.alpha],lengths:2...3) {
                    if (Int(tokens[i].value) ?? 100) < 100 {
                        check=i;checkStack=0;twoDigit.removeAll();nrIsBound=true;unboundNRs.append(i)
                        if tokens[i+1].kind == .section { section=i+1 }
                    }
                    skipNext=true
                } else {
                    nr=i;nrIsBound=true;unboundNRs.append(i)
                    if next(i,[.precedence,.alpha],lengths:1...1) {
                        if tokens[i+1].kind == .precedence { precedence=i+1 }
                        skipNext=true
                    }
                }
            case .digit2:
                twoDigit.append(i)
                if next(i,[.precedence,.alpha],lengths:1...1) {
                    nr=i;twoDigit.removeAll();checkStack=0;nrIsBound=true
                    if tokens[i+1].kind == .precedence { precedence=i+1;skipNext=true }
                } else if next(i,[.section,.alpha],lengths:2...3) {
                    if !nrIsBound && checkStack > 0 { nr=check }
                    check=i;checkStack=0
                    if tokens[i+1].kind == .section { section=i+1 }
                    skipNext=true
                } else {
                    // Both remaining Pascal branches do the same thing here:
                    // the old check becomes the number unless one is bound.
                    if check != nil && !nrIsBound && checkStack > 0 { nr=check }
                    check=i;checkStack+=1
                }
            case .alpha:
                guard tokens[i].value.count == 2 else { break }
                if let last=twoDigit.last, nr != nil { check=last;checkStack+=1 }
                else if let popped=unboundNRs.popLast() {
                    check=popped;checkStack+=1
                    if let top=unboundNRs.last { nr=top }
                }
            case .precedence:
                precedence=i
                if nr != nil { nrIsBound=true }
            case .section: section=i
            case .callsign: break
            }
        }
        if let nr { result.serial=String(Int(tokens[nr].value) ?? 0) }
        if let precedence { result.precedence=tokens[precedence].value }
        if let check {
            let value=Int(tokens[check].value) ?? 0
            result.check=value < 10 ? "0\(value)" : String(value)
        }
        if let section { result.section=tokens[section].value }
        if nr == nil { result.errors=["Missing/Invalid Serial Number"] }
        else if precedence == nil { result.errors=["Missing/Invalid Precedence"] }
        else if check == nil { result.errors=["Missing/Invalid Check"] }
        else if section == nil { result.errors=["Missing/Invalid Section"] }
        return result
    }
}
