//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import Foundation

/// Sample-clock Morse plan, independent of AudioKit, browser APIs and iOS.
/// Element placement mirrors the two MRCE keyers sample for sample
/// (`MorseKey.pas` and, for Farnsworth spacing, `FarnsKeyer.pas`); the
/// compiled-Pascal vectors in `MRCEKeyerOracleTests` hold it there.
public enum MorseTimeline {
    public struct Mark: Sendable, Equatable {
        public var start: Double, duration: Double
        public init(start:Double,duration:Double) {self.start=start;self.duration=duration}
    }
    /// MRCE `Round(60/48 * Rate / Wpm)`: samples in one unit at 48 units per word.
    private static func unitSamples(_ rate:Double,wpm:Int)->Int {
        max(1,Int((60.0/48*rate/Double(max(1,wpm))).rounded(.toNearestOrEven)))
    }
    private struct Layout {
        var marks:[(start:Int,length:Int)]=[]
        var samples=0
    }
    /// `farnsworthKeyer` selects MRCE's SST keyer. When nil it is inferred
    /// from a character rate above the sending rate, which is the only case
    /// where the two keyers space single-spaced text differently.
    private static func layout(_ message:String,wpm:Int,characterWpm:Int?,fastReportRate:Double,
                               fastReportStarts:[Int],sampleRate:Double,farnsworthKeyer:Bool?) -> Layout {
        let rate=max(1,sampleRate),sendWpm=max(5,wpm),requestedChar=characterWpm ?? sendWpm
        let farnsworth=farnsworthKeyer ?? (requestedChar > sendWpm)
        // FarnsKeyer: characters at WpmC, spacing stretched so a 48-unit word
        // takes 60/WpmS seconds. With WpmS above WpmC it keys at WpmS.
        let stretched=farnsworth && sendWpm <= requestedChar
        let charWpm=stretched ? requestedChar : sendWpm
        let unit=unitSamples(rate,wpm:charWpm)
        let adjust=stretched
            ? max(1,Int(((60.0/Double(sendWpm)-31*60.0/Double(charWpm)/48)*rate/17).rounded(.toNearestOrEven)))
            : unit
        let fastWpm=Int((Double(sendWpm)*max(1,fastReportRate)).rounded())
        let fastUnit=unitSamples(rate,wpm:fastWpm)
        func elementUnit(at offset:Int)->Int {
            guard !farnsworth,fastWpm > sendWpm,
                  fastReportStarts.contains(where:{offset >= $0 && offset < $0+3}) else {return unit}
            return fastUnit
        }
        var layout=Layout(),position=0,offset=0
        // Samples owed after the last keyed element: its own trailing unit
        // plus the character space, at that character's speed.
        var pendingSpace=0,lastCharacterUnit=unit,previousWasSpace=false,sawCharacter=false
        for char in message.uppercased().trimmingCharacters(in:.whitespacesAndNewlines) {
            if char.isWhitespace || char == "_" {
                // Each space is a keyer token: 2 units in MorseKey; in FarnsKeyer the
                // first widens the character gap to 5 and every further one adds 5.
                if farnsworth {pendingSpace += previousWasSpace ? 5*adjust : 2*adjust}
                else {pendingSpace += 2*unit}
                if !previousWasSpace {offset+=1}
                previousWasSpace=true
                continue
            }
            previousWasSpace=false
            let symbols=ContestRules.morseSymbols(char)
            defer {offset+=1}
            guard !symbols.isEmpty else {continue}
            position+=pendingSpace
            let characterUnit=elementUnit(at:offset)
            for (index,symbol) in symbols.enumerated() {
                if index>0 {position+=characterUnit}
                let length=(symbol == "." ? 1 : 3)*characterUnit
                layout.marks.append((position,length));position+=length
            }
            // One unit after the last element, then two more to make the
            // three-unit character space (three stretched units in FarnsKeyer).
            pendingSpace=farnsworth ? 3*adjust : 3*characterUnit
            lastCharacterUnit=characterUnit;sawCharacter=true
        }
        guard sawCharacter else {return layout}
        // The final character space becomes the four-unit end-of-message gap.
        layout.samples=position+(farnsworth ? 4*adjust : 4*lastCharacterUnit)
        return layout
    }
    public static func marks(_ message:String,wpm:Int,characterWpm:Int?=nil,fastReportStart:Int?=nil,fastReportRate:Double=1.0,fastReportStarts:[Int]?=nil,sampleRate:Double=44_100,farnsworthKeyer:Bool?=nil) -> [Mark] {
        let rate=max(1,sampleRate)
        let starts=fastReportStarts ?? fastReportStart.map{[$0]} ?? []
        return layout(message,wpm:wpm,characterWpm:characterWpm,fastReportRate:fastReportRate,fastReportStarts:starts,
                      sampleRate:rate,farnsworthKeyer:farnsworthKeyer).marks.map {
            Mark(start:Double($0.start)/rate,duration:Double($0.length)/rate)
        }
    }
    /// MRCE sends in whole 512-sample blocks at 11,025 Hz: a station is still
    /// "sending" until the block holding the end of its envelope has been
    /// played. This rounds a keyed length up to that boundary.
    /// Whether two keyings are identical over the first `seconds`: the test
    /// MRCE applies to the part of a call already sent before it re-keys the
    /// rest from an edited call (`MyStn.UpdateCallInMessage`).
    public static func sameKeying(_ first:[Mark],_ second:[Mark],until seconds:Double) -> Bool {
        let tolerance=1e-9
        for index in 0..<max(first.count,second.count) {
            let a=index < first.count ? first[index] : nil,b=index < second.count ? second[index] : nil
            guard let a,let b else {return (a ?? b)!.start >= seconds-tolerance}
            if a.start >= seconds-tolerance && b.start >= seconds-tolerance {return true}
            guard abs(a.start-b.start) < tolerance else {return false}
            if abs(a.duration-b.duration) >= tolerance {
                return min(a.start+a.duration,b.start+b.duration) >= seconds-tolerance
            }
        }
        return true
    }
    public static func blockPadded(_ seconds:Double) -> Double {
        let block=512.0/11_025.0
        return (seconds/block-1e-6).rounded(.up)*block
    }
    public static func duration(_ message:String,wpm:Int,characterWpm:Int?=nil,fastReportStart:Int?=nil,fastReportRate:Double=1.0,fastReportStarts:[Int]?=nil,sampleRate:Double=44_100,farnsworthKeyer:Bool?=nil) -> Double {
        let rate=max(1,sampleRate)
        let starts=fastReportStarts ?? fastReportStart.map{[$0]} ?? []
        let result=layout(message,wpm:wpm,characterWpm:characterWpm,fastReportRate:fastReportRate,fastReportStarts:starts,
                          sampleRate:rate,farnsworthKeyer:farnsworthKeyer)
        guard !result.marks.isEmpty else {return 0.15}
        return Double(result.samples)/rate
    }
}
