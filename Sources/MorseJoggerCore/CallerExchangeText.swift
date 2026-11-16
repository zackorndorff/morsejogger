//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import Foundation

/// On-air rendering of a caller's exchange, a Swift port of the text rules in
/// MRCE `TStation.NrAsText` for DX stations. `Station.exchange` stays canonical
/// (scoring and the answer display); only the keyed text passes through here.
///
/// Rules that MRCE draws with `Random` are drawn again on every transmission
/// (MRCE calls `NrAsText` each time `<#>` is sent), from the station's own
/// `exchangeRNGState` stream. Rules keyed on `R1` use the station's stable
/// `stationDraw`.
enum CallerExchangeText {
    enum Field2 { case other, serial, cqZone, power, jaPref, jaCity }

    static func field2(contest:ContestID,station st:Station) -> Field2 {
        switch contest {
        case .wpx,.hst: return .serial
        case .cqww: return .cqZone
        case .allja: return .jaPref
        case .acag: return .jaCity
        case .arrldx: return st.country == "K" || st.country == "VE" ? .other : .power
        case .arrl10:
            if st.call.hasSuffix("/MM") {return .other}
            let last=st.exchange.split(separator:" ").last.map(String.init) ?? ""
            return !last.isEmpty && last.allSatisfy({$0.isNumber}) ? .serial : .other
        default: return .other
        }
    }
    static func sendsRST(_ contest:ContestID) -> Bool {
        [.wpx,.hst,.cqww,.iaru,.arrldx,.arrl10,.allja,.acag,.pota].contains(contest)
    }

    static func runsReportIntoSerial(_ contest:ContestID) -> Bool { contest == .wpx || contest == .hst }
    static func joinedReportAndSerial(_ exchange:String) -> String {
        let words=exchange.split(separator:" ",omittingEmptySubsequences:true)
        return words.count == 2 ? String(words[0]+words[1]) : exchange
    }

    /// `NrAsText` for the operator's own station (`MyCall = Ini.Call`): no
    /// `ENN`, and numeric fields are always cut. `r1` is the station's `R1`.
    static func renderOwn(_ exchange:String,settings:ContestSettings,r1:Double) -> String {
        let contest=settings.contest
        if contest == .cwt {
            return exchange.split(separator:" ",omittingEmptySubsequences:true).joined(separator:"  ")
        }
        guard sendsRST(contest) else {return exchange}
        var text=(runsReportIntoSerial(contest) ? joinedReportAndSerial(exchange) : exchange)
            .replacingOccurrences(of:"599",with:"5NN")
        let call=ContestRules.normalizeCall(settings.myCall)
        let mine=ContestRules.callMeta(call,settings:settings)
        let kind:Field2
        switch contest {
        case .wpx: kind = .serial
        case .cqww: kind = .cqZone
        case .arrldx: kind = mine.usve ? .other : .power
        case .arrl10: kind = call.hasSuffix("/MM") || mine.isARRL10Local ? .other : .serial
        // The HST contest never cuts numbers here (see docs/INTENTIONAL_DIFFERENCES.md).
        default: kind = .other
        }
        guard kind != .other,settings.mode != .hstCompetition else {return text}
        text=text.replacingOccurrences(of:"0",with:"T").replacingOccurrences(of:"9",with:"N")
        if kind == .cqZone || (kind == .power && r1<0.70) {text=text.replacingOccurrences(of:"1",with:"A")}
        return text
    }

    /// One `NrAsText` call. Clears `nrWithError` after the first serial send.
    static func render(_ st:inout Station,contest:ContestID,mode:SessionMode) -> String {
        guard st.exchangeRNGState != 0 else {return st.exchange}
        // `NrAsText` for CWT: '<name>  <number>' with two spaces, keyed as a wider gap.
        if contest == .cwt {
            let text=st.exchange.split(separator:" ",omittingEmptySubsequences:true).joined(separator:"  ")
            st.transmittedExchange=text
            return text
        }
        guard sendsRST(contest) else {return st.exchange}
        var stream=ContestRNG(seed:st.exchangeRNGState)
        defer {st.exchangeRNGState=stream.state}
        let kind=field2(contest:contest,station:st)
        let hst=mode == .hstCompetition || contest == .hst
        // `Format('%d%.3d', [RST, NR])`: in WPX and HST the report and the
        // serial are one word, keyed without a word gap.
        var text=runsReportIntoSerial(contest) ? joinedReportAndSerial(st.exchange) : st.exchange

        if st.nrWithError && kind == .serial {
            var chars=Array(text)
            var index=chars.count-1
            if index >= 0, !("2"..."7").contains(chars[index]) {index-=1}
            if index >= 0, ("2"..."7").contains(chars[index]) {
                let digit=chars[index].wholeNumberValue ?? 0
                chars[index]=Character(String(digit+(stream.random()<0.5 ? -1 : 1)))
                // `Format('EEEEE %.3d', [NR])`: always at least three digits.
                let serial=st.exchange.split(separator:" ").last.map(String.init) ?? ""
                text=String(chars)+"EEEEE "+String(repeating:"0",count:max(0,3-serial.count))+serial
            }
            st.nrWithError=false
        }

        if !hst && stream.random()<0.05 {text=text.replacingOccurrences(of:"599",with:"ENN")}
        text=text.replacingOccurrences(of:"599",with:"5NN")

        if !hst && kind != .other && kind != .jaPref && kind != .jaCity {
            text=text.replacingOccurrences(of:"000",with:"TTT").replacingOccurrences(of:"00",with:"TT")
            if kind == .serial && stream.random()<0.98 {text=text.replacingOccurrences(of:"0",with:"T")}
            if kind != .cqZone && stream.random()<0.4 {text=text.replacingOccurrences(of:"0",with:"O")}
            else if kind != .cqZone && stream.random()<0.97 {text=text.replacingOccurrences(of:"0",with:"T")}
            if kind == .cqZone || kind == .power {
                if st.stationDraw<0.70 {
                    text=text.replacingOccurrences(of:"0",with:"T").replacingOccurrences(of:"1",with:"A")
                        .replacingOccurrences(of:"9",with:"N")
                }
            } else if stream.random()<0.97 {text=text.replacingOccurrences(of:"9",with:"N")}
        }
        if !hst && (kind == .jaPref || kind == .jaCity) {
            if stream.random()<0.4 {
                text=text.replacingOccurrences(of:"00",with:"TT").replacingOccurrences(of:"0",with:"O")
            } else if stream.random()<0.8 {text=text.replacingOccurrences(of:"0",with:"T")}
            if stream.random()<0.1 {text=text.replacingOccurrences(of:"9",with:"N")}
        }
        st.transmittedExchange=text
        return text
    }
}
