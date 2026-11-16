//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import Foundation
import SwiftUI
import CryptoKit
import MorseJoggerCore

/// Owns the downloaded SCP cache and an optional, explicitly imported override.
/// Both files live in Application Support; no user Documents directory is read.
@MainActor
final class SCPDataService: ObservableObject {
    static let officialSourceURL = URL(string: "https://www.supercheckpartial.com/downloads/MASTER.SCP")
    /// "Morse Jogger v<version> (+<contact>)", or nil when `info` has no
    /// version. No request is sent without one. The version is
    /// MARKETING_VERSION and the contact is SCP_CONTACT from the gitignored
    /// iOS/Local.xcconfig, both from Info.plist; an empty contact is left out.
    nonisolated static func userAgent(info: [String: Any]) -> String? {
        func value(_ key: String) -> String? {
            guard let text = (info[key] as? String)?.trimmingCharacters(in: .whitespaces),
                  !text.isEmpty else { return nil }
            return text
        }
        guard let version = value("CFBundleShortVersionString") else { return nil }
        var agent = "Morse Jogger v\(version)"
        if let contact = value("SCPContact") { agent += " (+\(contact))" }
        return agent
    }
    nonisolated static let maximumDatabaseBytes = 64 * 1024 * 1024

    nonisolated static func decodePublishedText(_ data: Data) throws -> ImportedHistory {
        guard data.count <= maximumDatabaseBytes else {
            throw ImportError.invalid("SCP database exceeds the 64 MiB limit")
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw ImportError.invalid("SCP text is not valid UTF-8 or ASCII")
        }
        return try HistoryImport.superCheckPartial(text)
    }

    struct Metadata: Codable, Sendable {
        var etag: String?
        var lastModified: String?
        var checkedAt: Date
        var source: String?
        var downloadedHash: String?
    }

    enum CacheError: LocalizedError {
        case sourceUnavailable
        case invalidResponse
        case missingCachedData
        case missingVersion
        var errorDescription: String? {
            switch self {
            case .sourceUnavailable: "SCP source is not configured."
            case .missingVersion: "SCP download is disabled: this build has no version number."
            case .invalidResponse: "The SCP server returned an unexpected response."
            case .missingCachedData: "No validated SCP cache is available."
            }
        }
    }

    @Published private(set) var history: ImportedHistory?
    @Published private(set) var isRefreshing = false
    @Published private(set) var status = "SCP data has not been loaded."
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isUsingCustomOverride = false

    private let sourceURL: URL?
    private let userAgent: String?
    private let decode: @Sendable (Data) throws -> ImportedHistory
    private let directory: URL
    private let session: URLSession
    private var metadata = Metadata(etag: nil, lastModified: nil, checkedAt: .distantPast, source: nil)
    private var refreshTask: Task<Bool, Never>?
    private var refreshTaskIsForced = false
    private var refreshTaskIsAutomatic = false
    private var refreshID: UUID?
    private var cacheLoaded = false
    private var cachedHistory: ImportedHistory?
    private var cacheLoadTask: Task<CacheSnapshot, Never>?

    private struct CacheSnapshot: Sendable {
        var downloadedHistory: ImportedHistory?
        var customHistory: ImportedHistory?
        var metadata: Metadata
        var customError: String?
    }

    private struct CacheReader: Sendable {
        let databaseURL: URL
        let overrideURL: URL
        let metadataURL: URL
        let sourceKey: String?
        let maximumBytes: Int
        let decode: @Sendable (Data) throws -> ImportedHistory

        func parse(_ url: URL) throws -> ImportedHistory? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            guard data.count <= maximumBytes else {
                throw ImportError.invalid("SCP database exceeds the 64 MiB limit")
            }
            let parsed = try decode(data)
            guard !parsed.calls.isEmpty else { throw ImportError.invalid("SCP database contains no calls") }
            return parsed
        }

        func load() -> CacheSnapshot {
            var metadata = Metadata(etag: nil, lastModified: nil, checkedAt: .distantPast, source: sourceKey)
            if let saved = try? Data(contentsOf: metadataURL),
               let restored = try? PropertyListDecoder().decode(Metadata.self, from: saved),
               restored.source == sourceKey { metadata = restored }
            let downloaded = try? parse(databaseURL)
            var custom: ImportedHistory?
            var customError: String?
            do { custom = try parse(overrideURL) }
            catch { customError = error.localizedDescription }
            return CacheSnapshot(downloadedHistory: downloaded ?? nil, customHistory: custom ?? nil,
                                 metadata: metadata, customError: customError)
        }

        nonisolated static func hash(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    private var databaseURL: URL { directory.appendingPathComponent("MASTER.SCP") }
    private var customOverrideURL: URL { directory.appendingPathComponent("Custom-MASTER.SCP") }
    private var metadataURL: URL { directory.appendingPathComponent("SCP-cache-metadata.plist") }
    private var sourceKey: String? { sourceURL?.absoluteString }

    init(sourceURL: URL?, session: URLSession = .shared,
         directory: URL? = nil,
         decode: (@Sendable (Data) throws -> ImportedHistory)? = nil,
         bundleInfo: [String: Any]? = nil) {
        self.sourceURL = sourceURL
        self.userAgent = Self.userAgent(info: bundleInfo ?? Bundle.main.infoDictionary ?? [:])
        self.session = session
        self.decode = decode ?? { data in try Self.decodePublishedText(data) }
        let fileManager = FileManager.default
        let homeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if let directory { self.directory = directory }
        else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true))
                ?? homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.directory = base.appendingPathComponent("MorseJogger/SCP", isDirectory: true)
        }
    }

    /// Loads only app-owned files.
    func loadCacheIfNeeded() async {
        if cacheLoaded { return }
        let task: Task<CacheSnapshot, Never>
        if let inFlight = cacheLoadTask { task = inFlight }
        else {
            let reader = CacheReader(databaseURL: databaseURL, overrideURL: customOverrideURL,
                                     metadataURL: metadataURL, sourceKey: sourceKey,
                                     maximumBytes: Self.maximumDatabaseBytes, decode: decode)
            let created = Task.detached(priority: .utility) { reader.load() }
            cacheLoadTask = created
            task = created
        }
        let snapshot = await task.value
        if !cacheLoaded {
            metadata = snapshot.metadata
            cachedHistory = snapshot.downloadedHistory
            history = snapshot.customHistory ?? snapshot.downloadedHistory
            isUsingCustomOverride = snapshot.customHistory != nil
            lastChecked = metadata.checkedAt == .distantPast ? nil : metadata.checkedAt
            if let history {
                status = isUsingCustomOverride
                    ? "Using imported custom SCP list: \(history.calls.count.formatted()) calls."
                    : "Using saved SCP data: \(history.calls.count.formatted()) calls."
            }
            if let error = snapshot.customError {
                status = snapshot.downloadedHistory == nil
                    ? "Imported SCP override is invalid (\(error)); no saved SCP data is available."
                    : "Imported SCP override is invalid (\(error)); using last good SCP data."
            }
            cacheLoaded = true
        }
        cacheLoadTask = nil
    }

    /// Validates a user-selected file and stores a private app-owned copy.
    func importCustomOverride(from sourceURL: URL) async throws {
        // Resolve the durable downloaded cache before installing an override.
        // Otherwise an early import can leave `cachedHistory` empty (or cause
        // it to be populated from the active custom history below).
        await loadCacheIfNeeded()
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: sourceURL)
        guard data.count <= Self.maximumDatabaseBytes else {
            throw ImportError.invalid("SCP database exceeds the 64 MiB limit")
        }
        let decode = self.decode
        let parsed = try await Task.detached(priority: .utility) { try decode(data) }.value
        guard !parsed.calls.isEmpty else { throw ImportError.invalid("SCP database contains no calls") }
        let destination = customOverrideURL
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        }.value
        history = parsed
        isUsingCustomOverride = true
        cacheLoaded = true
        status = "Using imported custom SCP list: \(parsed.calls.count.formatted()) calls."
    }

    /// Removes the explicitly imported override and returns to the downloaded cache.
    func clearCustomOverride() async {
        await loadCacheIfNeeded()
        do {
            try FileManager.default.removeItem(at: customOverrideURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // The override may already have been removed externally.
        } catch {
            status = "Could not remove imported SCP override: \(error.localizedDescription)"
            return
        }
        isUsingCustomOverride = false
        history = cachedHistory
        status = cachedHistory.map { "Using saved SCP data: \($0.calls.count.formatted()) calls." }
            ?? CacheError.missingCachedData.localizedDescription
    }

    @discardableResult
    func refresh(force: Bool = false, automatic: Bool = false, now: Date = Date()) async -> Bool {
        await loadCacheIfNeeded()
        if isUsingCustomOverride && !force { return history != nil }
        while true {
            if let inFlight = refreshTask {
                let inFlightID = refreshID
                let inFlightWasForced = refreshTaskIsForced
                let firstResult = await inFlight.value
                if refreshID == inFlightID {
                    refreshTask = nil
                    refreshTaskIsForced = false
                    refreshTaskIsAutomatic = false
                    refreshID = nil
                    isRefreshing = false
                }
                if !force || inFlightWasForced { return firstResult }
                continue
            }
            if !force, history != nil {
                let age = now.timeIntervalSince(metadata.checkedAt)
                if age >= 0 && age < 365 * 24 * 60 * 60 { return true }
            }
            let id = UUID()
            let task = Task { @MainActor in await self.performRefresh(now: now, automatic: automatic) }
            refreshID = id
            refreshTask = task
            refreshTaskIsForced = force
            refreshTaskIsAutomatic = automatic
            isRefreshing = true
            let result = await task.value
            if refreshID == id {
                refreshTask = nil
                refreshTaskIsForced = false
                refreshTaskIsAutomatic = false
                refreshID = nil
                isRefreshing = false
            }
            return result
        }
    }

    /// Stops a background consent-based refresh without cancelling a refresh
    /// that the user explicitly requested.
    func cancelAutomaticRefresh() {
        guard refreshTaskIsAutomatic else { return }
        refreshTask?.cancel()
    }

    private func performRefresh(now: Date, automatic: Bool, unconditionalRetry: Bool = false) async -> Bool {
        guard let sourceURL else {
            status = history == nil ? CacheError.sourceUnavailable.localizedDescription : "Using saved SCP data; refresh source is unavailable."
            return history != nil
        }
        guard let userAgent else {
            status = history == nil ? CacheError.missingVersion.localizedDescription : "Using saved SCP data; this build has no version number to download with."
            return history != nil
        }
        do {
            var request = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            // Validators are meaningful only when the corresponding downloaded
            // body was parsed successfully from our durable cache.
            if !unconditionalRetry, cachedHistory != nil, metadata.source == sourceKey {
                if let etag = metadata.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
                if let modified = metadata.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
            }
            let (data, response) = try await session.data(for: request)
            if automatic && Task.isCancelled { return history != nil }
            guard let response = response as? HTTPURLResponse else { throw CacheError.invalidResponse }
            if response.statusCode == 304 {
                guard cachedHistory != nil, metadata.source == sourceKey else {
                    if !unconditionalRetry { return await performRefresh(now: now, automatic: automatic, unconditionalRetry: true) }
                    throw CacheError.missingCachedData
                }
                let saved = await updateMetadata(response: response, checkedAt: now)
                status = saved ? "SCP data checked; saved database is current." : "SCP data checked, but cache metadata could not be saved."
                return history != nil
            }
            guard response.statusCode == 200 else { throw CacheError.invalidResponse }
            guard data.count <= Self.maximumDatabaseBytes else {
                throw ImportError.invalid("SCP database exceeds the 64 MiB limit")
            }
            let decode = self.decode
            let parsed = try await Task.detached(priority: .utility) { try decode(data) }.value
            if automatic && Task.isCancelled { return history != nil }
            guard !parsed.calls.isEmpty else { throw ImportError.invalid("SCP database contains no calls") }
            let databaseURL = self.databaseURL
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: databaseURL, options: .atomic)
            }.value
            if automatic && Task.isCancelled { return history != nil }
            cachedHistory = parsed
            if !isUsingCustomOverride { history = parsed }
            let saved = await updateMetadata(response: response, checkedAt: now,
                                             downloadedHash: CacheReader.hash(data))
            status = isUsingCustomOverride
                ? "Downloaded SCP cache updated: \(parsed.calls.count.formatted()) calls; custom list remains active."
                : (saved ? "SCP data updated: \(parsed.calls.count.formatted()) calls."
                         : "SCP data updated: \(parsed.calls.count.formatted()) calls, but cache metadata could not be saved.")
            return true
        } catch is CancellationError {
            return history != nil
        } catch {
            status = history == nil
                ? "SCP data unavailable: \(error.localizedDescription)"
                : "SCP update failed; using saved data (\(error.localizedDescription))."
            return history != nil
        }
    }

    @discardableResult
    private func updateMetadata(response: HTTPURLResponse, checkedAt: Date, downloadedHash: String? = nil) async -> Bool {
        let prior = metadata
        let updated = Metadata(etag: response.value(forHTTPHeaderField: "ETag") ?? metadata.etag,
                               lastModified: response.value(forHTTPHeaderField: "Last-Modified") ?? metadata.lastModified,
                               checkedAt: checkedAt, source: sourceKey,
                               downloadedHash: downloadedHash ?? metadata.downloadedHash)
        guard let data = try? PropertyListEncoder().encode(updated) else { return false }
        let metadataURL = self.metadataURL
        do {
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: metadataURL, options: .atomic)
            }.value
            metadata = updated
            lastChecked = checkedAt
            return true
        } catch {
            metadata = prior
            lastChecked = prior.checkedAt == .distantPast ? nil : prior.checkedAt
            return false
        }
    }
}
