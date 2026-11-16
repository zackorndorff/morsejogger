//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import Foundation
import MorseJoggerCore

/// Owns compact preferences and the separately versioned imported datasets.
/// Failed writes remain retryable; unreadable datasets are preserved separately.
final class SettingsStore: @unchecked Sendable {
    static let cwSpeedRange = 5...120
    static let practiceDurationRange = 1...240

    private let defaults: UserDefaults
    private let directory: URL
    private let writeQueue = DispatchQueue(label: "com.z10f.morsejogger.settings-write", qos: .utility)
    private static let settingsKey = "com.z10f.morsejogger.settings.v2"
    private static let consentKey = "com.z10f.morsejogger.automaticSCPDownloadsConsent.v1"
    private static let datasetVersion = 1

    private struct ImportedDatasets: Codable, Equatable, Sendable {
        var version = SettingsStore.datasetVersion
        var customCalls: [String] = []
        var customRecords: [String: HistoryRecord] = [:]
        var contestHistories: [String: ImportedHistory] = [:]
        var countryPrefixes: [String: HistoryRecord] = [:]
        init(_ settings: ContestSettings) {
            customCalls = settings.customCalls
            customRecords = settings.customRecords
            contestHistories = settings.contestHistories
            countryPrefixes = settings.countryPrefixes
        }
        func apply(to settings: inout ContestSettings) {
            settings.customCalls = customCalls
            settings.customRecords = customRecords
            settings.contestHistories = contestHistories
            settings.countryPrefixes = countryPrefixes
        }
    }

    private let datasetsURL: URL
    // Access only on writeQueue, including during load.
    private var savedDatasets: ImportedDatasets?
    private var datasetRecoveryBlocked = false
    private(set) var loadWarning: String?

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        if let directory { self.directory = directory }
        else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.directory = base.appendingPathComponent("MorseJogger", isDirectory: true)
        }
        self.datasetsURL = self.directory.appendingPathComponent("Imported-Datasets-v1.json")
    }

    func load() -> ContestSettings {
        writeQueue.sync {
            var settings = defaults.data(forKey: Self.settingsKey)
                .flatMap { try? JSONDecoder().decode(ContestSettings.self, from: $0) } ?? ContestSettings()
            if let datasets = Self.loadDatasets(at: datasetsURL) {
                datasets.apply(to: &settings)
                savedDatasets = datasets
            } else if FileManager.default.fileExists(atPath: datasetsURL.path) {
                // Preserve unreadable bytes before any future save can replace them.
                let backup = datasetsURL.appendingPathExtension("unreadable-" + UUID().uuidString)
                do {
                    try FileManager.default.moveItem(at: datasetsURL, to: backup)
                    loadWarning = "Imported data could not be read. The original file was preserved as \(backup.lastPathComponent). Reimport the data to use it."
                } catch {
                    datasetRecoveryBlocked = true
                    loadWarning = "Imported data could not be read or preserved. Saving is blocked to protect the original file."
                }
            }
            settings = Self.normalized(settings)
            settings.rit = 0
            return settings
        }
    }

    /// Compare against the last successful write on the serial queue. A failed
    /// import therefore remains dirty even when the next save is preferences-only.
    func save(_ settings: ContestSettings, datasetsChanged: Bool = false,
              completion: (@Sendable (Bool) -> Void)? = nil) {
        writeQueue.async { [self] in
            var stored = Self.normalized(settings)
            stored.rit = 0
            let datasets = ImportedDatasets(stored)
            guard !datasetRecoveryBlocked else { completion?(false); return }
            if datasets != savedDatasets {
                guard Self.writeDatasets(datasets, to: datasetsURL) else { completion?(false); return }
                savedDatasets = datasets
            }
            guard let data = Self.encode(Self.preferencesOnly(stored)) else { completion?(false); return }
            defaults.set(data, forKey: Self.settingsKey)
            completion?(true)
        }
    }

    /// Persist imported datasets without replacing the saved preference
    /// snapshot. This keeps an invalid editable settings draft out of storage.
    func saveDatasets(_ settings: ContestSettings, completion: (@Sendable (Bool) -> Void)? = nil) {
        writeQueue.async { [self] in
            let datasets = ImportedDatasets(settings)
            guard !datasetRecoveryBlocked else { completion?(false); return }
            if datasets != savedDatasets {
                guard Self.writeDatasets(datasets, to: datasetsURL) else { completion?(false); return }
                savedDatasets = datasets
            }
            completion?(true)
        }
    }

    func flush() { writeQueue.sync {} }

    enum SCPDownloadConsent: String { case unresolved, allow, deny }

    func loadConsent() -> SCPDownloadConsent? {
        defaults.string(forKey: Self.consentKey).flatMap(SCPDownloadConsent.init(rawValue:))
    }

    func saveConsent(_ consent: SCPDownloadConsent) {
        defaults.set(consent.rawValue, forKey: Self.consentKey)
    }

    private static func loadDatasets(at url: URL) -> ImportedDatasets? {
        guard let data = try? Data(contentsOf: url),
              let datasets = try? JSONDecoder().decode(ImportedDatasets.self, from: data),
              datasets.version == datasetVersion else { return nil }
        return datasets
    }

    private static func writeDatasets(_ datasets: ImportedDatasets, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(datasets) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return loadDatasets(at: url) != nil
        } catch { return false }
    }

    private static func encode(_ settings: ContestSettings) -> Data? {
        try? JSONEncoder().encode(settings)
    }

    private static func preferencesOnly(_ settings: ContestSettings) -> ContestSettings {
        var preferences = settings
        preferences.rit = 0
        preferences.customCalls = []
        preferences.customRecords = [:]
        preferences.contestHistories = [:]
        preferences.countryPrefixes = [:]
        return preferences
    }

    /// Settings that must agree before session construction, regardless of which
    /// SwiftUI binding changed them.
    static func normalized(_ settings: ContestSettings, after previous: ContestSettings? = nil) -> ContestSettings {
        var result = settings
        result.myCall = result.myCall.uppercased()
        result.monitor = min(0, max(-60, result.monitor))
        result.rit = min(500, max(-500, result.rit))
        result.wpm = min(cwSpeedRange.upperBound, max(cwSpeedRange.lowerBound, result.wpm))
        result.duration = min(practiceDurationRange.upperBound, max(practiceDurationRange.lowerBound, result.duration))
        result.callerSpeedMode = settings.callerSpeedMode
        result.serialMinDigits = result.serialMinDigitWidth
        result.serialMaxDigits = result.serialMaxDigitWidth
        result.pitch = ContestSettings.nearestChoice(result.pitch, choices: Array(stride(from: 300, through: 900, by: 50)))
        result.bandwidth = ContestSettings.nearestChoice(result.bandwidth, choices: Array(stride(from: 100, through: 600, by: 50)))
        if var profiles=result.operatorExchangeProfiles {
            for key in profiles.keys {
                guard var profile=profiles[key] else { continue }
                profile.ituSociety=profile.ituSociety.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
                profiles[key]=profile
            }
            result.operatorExchangeProfiles=profiles
        }
        return result
    }
}
