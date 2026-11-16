//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
/// Shared contest metadata. Wire IDs remain on ContestID; algorithms remain in ContestRules.
public struct ContestDefinition: Sendable {
    public let id: ContestID
    public var usesRST: Bool {
        switch id {
        case .fieldday, .sweepstakes, .naqp, .sst, .cwt: false
        default: true
        }
    }
    public var supportsCustomSerialRange: Bool { [.wpx,.hst,.sweepstakes,.arrl10].contains(id) }
    public var defaultOperatorProfile: OperatorExchangeProfile {
        var p=OperatorExchangeProfile()
        switch id {
        case .wpx,.hst: break
        case .cwt: p.name="DAVID";p.cwopsNumber="123"
        case .fieldday: p.fdClass="3A";p.section="OR"
        case .naqp: p.name="ALEX";p.state="ON"
        case .cqww: p.zone=3;p.zoneText="3"
        case .arrldx: p.state="ON";p.power="KW"
        case .sst: p.name="BRUCE";p.state="MA"
        case .allja: p.jaPrefecture="10";p.jaPower="H"
        case .acag: p.jaCity="1002";p.jaPower="H"
        case .iaru: p.ituZone=6;p.ituZoneText="6"
        case .sweepstakes: p.precedence="A";p.check="72";p.section="OR"
        case .arrl10: p.state="OR"
        case .pota: p.state="NY"
        }
        return p
    }
    public var label: String {
        switch id {
        case .wpx: "CQ WPX"
        case .cqww: "CQ WW CW"
        case .arrldx: "ARRL DX CW"
        case .fieldday: "ARRL Field Day"
        case .sweepstakes: "ARRL Sweepstakes"
        case .naqp: "NCJ NAQP CW"
        case .cwt: "CWops CWT"
        case .sst: "K1USN SST"
        case .iaru: "IARU HF Championship"
        case .allja: "JARL ALL JA"
        case .acag: "JARL ACAG"
        case .arrl10: "ARRL 10 Meter"
        case .hst: "HST competition"
        case .pota: "POTA (experimental)"
        }
    }
    public var exchangeLabel: String {
        switch id {
        case .wpx, .hst: "Serial received"
        case .cqww: "CQ zone"
        case .arrldx, .arrl10: "State / power / serial"
        case .fieldday: "Class + section"
        case .sweepstakes: "NR PREC CALL CK SEC"
        case .naqp, .sst: "Name + state"
        case .cwt: "Name + number/state"
        case .iaru: "ITU zone / society"
        case .allja: "Prefecture"
        case .acag: "City / county code"
        case .pota: "599 + state"
        }
    }
    /// MRCE-style exchange entry uses two controls after the callsign. Some
    /// contests have one logical value in each control; Sweepstakes keeps its
    /// multi-part copied exchange in the second control.
    public var receivedExchangeFields:(first:String?,second:String,secondAllowsSpaces:Bool) {
        switch id {
        case .wpx,.hst: ("RST","Serial",false)
        case .cqww: ("RST","CQ Zone",false)
        case .arrldx: ("RST","State / Power",false)
        case .arrl10: ("RST","State / Serial / Region",false)
        case .fieldday: ("Class","Section",false)
        case .sweepstakes: (nil,"NR PREC CALL CK SEC",true)
        case .naqp,.sst: ("Name","State",false)
        case .cwt: ("Name","Number / location",false)
        case .iaru: ("RST","ITU Zone / Society",false)
        case .allja: ("RST","Prefecture / Power",false)
        case .acag: ("RST","City Code / Power",false)
        case .pota: ("RST","State",false)
        }
    }
}

public extension ContestSettings {
    var hstConfigurationError: String? {
        if mode == .hstCompetition {
            if contest != .hst { return "Choose the HST contest to start HST competition." }
            if serialRange != .start { return "Choose Start serials to start HST competition." }
        }
        return nil
    }
    var configurationError: String? {
        hstConfigurationError ?? customSerialRangeError ?? sentExchangeConfigurationError
    }
    var sentExchangeConfigurationError: String? {
        guard contest != .hst else { return nil }
        if let error = ContestRules.defaultSentExchangeValidationError(self) { return error }
        if ContestRules.tokens(ContestRules.sentExchange(self,serial:1)).isEmpty {
            return "The sent exchange cannot be empty."
        }
        return nil
    }
}
