//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import Foundation
import MorseJoggerCore

/// Writes the operator's current log using the app's established CSV format.
struct LogCSVExporter {
    func export(_ log: [QSOEntry]) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("MorseJogger-\(UUID().uuidString.prefix(8)).csv")
        let fields = ["Time", "Call", "Copied", "Sent", "Received", "Expected", "Verified", "Points", "Multipliers", "Note"]
        func quote(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let lines = log.reversed().map { entry in
            [String(format: "%.1f", entry.at), entry.call, entry.copiedCall, entry.sent,
             entry.received, entry.expected, entry.correct ? "YES" : "NO", String(entry.points),
             entry.multipliers.joined(separator: ";"), entry.note].map(quote).joined(separator: ",")
        }
        try ([fields.joined(separator: ",")] + lines).joined(separator: "\n")
            .write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }
}

enum ImportedHistoryFile {
    case countryPrefixes([String: HistoryRecord])
    case history(ImportedHistory, replacesCustomCalls: Bool)
}

/// Reads supported history files while holding any required security scope,
/// then delegates format parsing to MorseJoggerCore.
struct ImportedHistoryFileService {
    func read(_ url: URL, contest: ContestID) throws -> ImportedHistoryFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".csv"), let text = String(data: data, encoding: .utf8),
           text.uppercased().hasPrefix("PREFIX,COUNTRY,CONTINENT,CQ_ZONE,ITU_ZONE") {
            return .countryPrefixes(try HistoryImport.prefixCSV(text))
        }

        let imported: ImportedHistory
        if name.hasSuffix(".dta") {
            imported = try HistoryImport.masterDTA(Array(data))
        } else {
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                throw ImportError.invalid("Cannot read this text file")
            }
            if text.uppercased().contains("!!ORDER!!,") {
                imported = try HistoryImport.mrceHistory(text, contest: contest)
            } else if text.lowercased().contains("cabrillo_id\tyear\tcall") {
                imported = try HistoryImport.arrl10TSV(text)
            } else {
                imported = try HistoryImport.callsText(text)
            }
        }
        return .history(imported, replacesCustomCalls: name.hasSuffix(".dta") || imported.sourceName == "Local callsign list")
    }
}
