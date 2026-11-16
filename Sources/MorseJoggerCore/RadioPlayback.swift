//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import Foundation

/// Shared radio playback contract: the receiver is tuned, not the transmitted
/// station. These functions are usable in a WASI build and in SwiftUI audio.
public enum RadioTuning {
    /// MRCE PgUp/PgDn (`IncSpeed`/`DecSpeed`): two WPM at a time, or to the
    /// next multiple of five in HST.
    public static func steppedSpeed(_ wpm:Int,up:Bool,mode:SessionMode,range:ClosedRange<Int>) -> Int {
        let next:Int
        if mode == .hstCompetition { next = up ? (wpm/5)*5+5 : ((wpm+4)/5)*5-5 }
        else { next = wpm + (up ? 2 : -2) }
        return min(range.upperBound,max(range.lowerBound,next))
    }
    public static func signalFrequency(_ voice:RadioVoice) -> Double {Double(voice.tone)}
    public static func receiverCenter(pitch:Int,rit:Int) -> Double {Double(pitch+rit)}
    /// MRCE's RIT step (`Ini.RitStepIncr`), in hertz.
    public static let ritStep = 50
    public static func adjustedRIT(_ current:Int,direction:Int) -> Int {
        guard direction != 0 else { return min(500,max(-500,current)) }
        return min(500,max(-500,current + (direction < 0 ? -1 : 1) * ritStep))
    }
}

/// Placement for one locally keyed program in the source-node frame timeline.
public struct TransmitFrameSchedule:Sendable,Equatable {
    public var referenceFrame:Int64
    public var startDelaySamples:Int64
    public init(referenceFrame:Int64,startDelaySamples:Int64) {
        self.referenceFrame=referenceFrame;self.startDelaySamples=startDelaySamples
    }
}

/// Serializes adjacent home-station TX macros while leaving receiver voices
/// free to overlap. A generation change marks a stopped or reset audio queue.
public struct TransmitFrameScheduler:Sendable {
    private var generation:Int?
    private var queuedEndFrame:Int64=0
    public init() {}
    public mutating func schedule(currentFrame:Int64,generation:Int,durationFrames:Int64,
                                  spacingFrames:Int64) -> TransmitFrameSchedule {
        if self.generation != generation {
            self.generation=generation
            queuedEndFrame=currentFrame
        }
        let startFrame=max(currentFrame,queuedEndFrame)
        queuedEndFrame=startFrame+max(0,durationFrames)+max(0,spacingFrames)
        return TransmitFrameSchedule(referenceFrame:currentFrame,
                                     startDelaySamples:startFrame-currentFrame)
    }
    /// A queued macro changed length (a re-keyed call): what follows moves with it.
    public mutating func shift(by frames:Int64) { queuedEndFrame += frames }
}

/// MRCE's Fast 5NN selection from Station.SendText. The home station always
/// uses the selected rate when enabled; DX stations use their stable R1 draw
/// both for occurrence and the one of four speed factors.
public enum FastReportTiming {
    public static func rate(randomValue:Double,occurrenceRate:Int,isHomeStation:Bool) -> Double? {
        let rate=max(0,min(100,occurrenceRate))
        guard rate>0 else {return nil}
        let draw=min(0.9999999999999999,max(0,randomValue))
        if !isHomeStation {
            let occurrence=((100*draw).truncatingRemainder(dividingBy:1))*100
            guard occurrence<Double(rate) else {return nil}
        }
        let factor=((10_000*draw).truncatingRemainder(dividingBy:1))*4
        return 1.2+0.1*floor(factor)
    }
}

/// The visible training UI must never present an incoming Morse transcript.
/// TX text is already known to the operator; RX and unsanitized engine notices
/// are not. Valid post-QSO details belong in the log/results view.
public enum RadioActivityText {
    public static func visible(_ event:RadioEvent) -> String {
        switch event.kind {
        case .transmit:return event.text
        // Incoming CW stays in the audio channel; activity is not a transcript
        // or a status announcement about a caller's hidden simulation state.
        case .receive, .interference, .cancelReceive, .rekey, .advanceEntry:return ""
        case .stopAudio:return "Audio stopped"
        case .finished:return "Session complete"
        case .notice:
            if let safeText=event.noticeCode?.safeDisplayText {return safeText}
            switch event.text {
            case "Entry cleared.", "TX cancelled. Call or repeat to continue.",
                 "Type a callsign first.", "Fill in CALL and RECEIVED.":return event.text
            default:return ""
            }
        }
    }
}
