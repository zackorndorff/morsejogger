//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
/// What each received-exchange box accepts while typing. Ported from MRCE's
/// `ExchFields.pas` (field lengths) and `Main.pas` `Edit2KeyPress` /
/// `Edit3KeyPress` (accepted keys and the cut-number key mapping).
public enum ReceivedFieldKind: Equatable, Sendable {
    case rst, name, fdClass
    case serial, cqZone, generic, section, stateProv, power, naqp, jaPref, jaCity, sweepstakes

    public var maxLength: Int {
        switch self {
        case .rst: 3
        case .name: 10
        case .fdClass: 3
        case .serial: 4
        case .cqZone: 2
        case .generic: 12
        case .section: 3
        case .stateProv: 6
        case .power: 4
        case .naqp: 6
        case .jaPref: 4
        case .jaCity: 7
        case .sweepstakes: 32
        }
    }
    /// Keys MRCE rewrites as they are typed, outside HST competition.
    var cutDigits: [Character: Character] {
        switch self {
        case .rst: ["A": "1", "E": "5", "N": "9"]
        case .serial: ["A": "1", "N": "9", "T": "0"]
        case .cqZone: ["A": "1", "N": "9", "O": "0", "T": "0"]
        default: [:]
        }
    }
    func accepts(_ c: Character) -> Bool {
        let digit = c >= "0" && c <= "9", letter = c >= "A" && c <= "Z"
        switch self {
        case .rst, .serial, .cqZone: return digit
        case .name, .section, .stateProv: return letter
        case .fdClass: return digit || (c >= "A" && c <= "F") || c == "X"
        case .generic: return digit || letter
        case .power: return digit || "KWANOT".contains(c)
        case .naqp: return digit || letter || c == "/"
        case .jaPref, .jaCity: return digit || "LMHP".contains(c)
        case .sweepstakes: return digit || letter || c == "/" || c == " "
        }
    }
}

public extension ContestRules {
    /// MRCE's callsign box holds twelve characters.
    static let callEntryMaxLength = 12

    static func receivedFieldKind(_ field: QSOEntryField, settings: ContestSettings) -> ReceivedFieldKind? {
        switch (settings.contest, field) {
        case (_, .callsign), (.sweepstakes, .exchangeFirst): return nil
        case (.sweepstakes, .exchangeSecond): return .sweepstakes
        case (.fieldday, .exchangeFirst): return .fdClass
        case (.naqp, .exchangeFirst), (.sst, .exchangeFirst), (.cwt, .exchangeFirst): return .name
        case (_, .exchangeFirst): return .rst
        case (.wpx, _), (.hst, _): return .serial
        case (.cqww, _): return .cqZone
        // A W/VE operator copies power; a DX operator copies a state or province.
        case (.arrldx, _): return callMeta(settings.myCall, settings: settings).usve ? .power : .stateProv
        case (.arrl10, _), (.iaru, _), (.sst, _), (.cwt, _): return .generic
        case (.fieldday, _): return .section
        case (.naqp, _): return .naqp
        case (.allja, _): return .jaPref
        case (.acag, _): return .jaCity
        case (.pota, _): return .stateProv
        }
    }

    /// The text an exchange box holds after the operator's edit, as MRCE would
    /// have built it key by key: cut-number keys become digits, other keys the
    /// field does not take are dropped, and the field stops at its length.
    static func filterReceivedEntry(_ text: String, field: QSOEntryField, settings: ContestSettings) -> String {
        guard let kind = receivedFieldKind(field, settings: settings) else { return text.uppercased() }
        let mapping = settings.mode == .hstCompetition ? [:] : kind.cutDigits
        var out = ""
        for raw in text.uppercased() {
            let c = mapping[raw] ?? raw
            if kind.accepts(c) { out.append(c) }
            if out.count == kind.maxLength { break }
        }
        return out
    }

    /// As above, but a key typed into a box that is already full is refused
    /// (MRCE's `MaxLength`), so nothing is pushed out of the end.
    static func filterReceivedEntry(_ text: String, previous: String, field: QSOEntryField, settings: ContestSettings) -> String {
        guard let kind = receivedFieldKind(field, settings: settings) else { return text.uppercased() }
        let mapping = settings.mode == .hstCompetition ? [:] : kind.cutDigits
        let accepted = text.uppercased().filter { kind.accepts(mapping[$0] ?? $0) }.count
        if accepted > kind.maxLength, previous.count == kind.maxLength { return previous }
        return filterReceivedEntry(text, field: field, settings: settings)
    }

    /// Where the cursor goes after an Enter that did not log the contact
    /// (`TMainForm.ProcessEnter` sets `MustAdvance` only for a complete call,
    /// and `Advance` skips the report box). With a partial call it stays put.
    static func entryFieldAfterEnter(from field: QSOEntryField, call: String, contest: ContestID) -> QSOEntryField {
        guard !call.contains("?"), ContestSimulator.isValidCall(call) else { return field }
        return contest.definition.usesRST || contest == .sweepstakes ? .exchangeSecond : .exchangeFirst
    }

    /// `TMainForm.Advance`, run when the piece being sent ends after such an
    /// Enter: back to the call box if the call is empty or has a `?` by then,
    /// otherwise on to the exchange, skipping the report.
    static func entryFieldOnAdvance(call: String, contest: ContestID) -> QSOEntryField {
        if call.isEmpty || call.contains("?") { return .callsign }
        return contest.definition.usesRST || contest == .sweepstakes ? .exchangeSecond : .exchangeFirst
    }

    /// What MRCE selects when a box gains focus from the keyboard, as character
    /// offsets: the first `?` of a call, the middle digit of a full report, or
    /// the whole of any other exchange box. Nil leaves the cursor alone.
    static func entrySelectionOnFocus(_ field: QSOEntryField, text: String, contest: ContestID) -> Range<Int>? {
        switch field {
        case .callsign:
            guard let index = text.firstIndex(of: "?") else { return nil }
            let offset = text.distance(from: text.startIndex, to: index)
            return offset..<offset+1
        case .exchangeFirst where contest.definition.usesRST:
            return text.count == 3 ? 1..<2 : nil
        case .exchangeFirst, .exchangeSecond:
            return text.isEmpty ? nil : 0..<text.count
        }
    }
}
