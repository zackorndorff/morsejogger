//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import Foundation
import MorseJoggerCore

/// Answers `api/v1/files` from `listingETag`, and counts those requests in
/// `listingHeaders`. Every other request is a download, counted in
/// `requestCount`/`requestHeaders` and answered by `requestHandler`; a status
/// of 0 drops the connection without any HTTP response.
final class RetryURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHeaders: [[String: String]] = []
    nonisolated(unsafe) static var responseBody = Data("valid".utf8)
    nonisolated(unsafe) static var requestHandler: ((URLRequest, Int) -> Int) = { _, _ in 200 }
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var listingHeaders: [[String: String]] = []
    nonisolated(unsafe) static var listingETag = "listed-tag"
    /// Fail the listing without any HTTP response, as when offline.
    nonisolated(unsafe) static var listingOffline = false

    static func reset() {
        requestHeaders = []; requestCount = 0; requestHandler = { _, _ in 200 }
        listingHeaders = []; listingETag = "listed-tag"; listingOffline = false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/api/v1/files" {
            Self.listingHeaders.append(["User-Agent": request.value(forHTTPHeaderField: "User-Agent") ?? ""])
            if Self.listingOffline {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let body = Data(#"[{"name":"MASTER.DTA","size":10,"etag":"other"},{"name":"MASTER.SCP","size":5,"etag":"\#(Self.listingETag)"}]"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let index = Self.requestCount
        Self.requestCount += 1
        Self.requestHeaders.append([
            "If-None-Match": request.value(forHTTPHeaderField: "If-None-Match") ?? "",
            "If-Modified-Since": request.value(forHTTPHeaderField: "If-Modified-Since") ?? "",
            "User-Agent": request.value(forHTTPHeaderField: "User-Agent") ?? ""
        ])
        let status = Self.requestHandler(request, index)
        if status == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: status == 200 ? ["ETag": "new-tag"] : nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status == 200 { client?.urlProtocol(self, didLoad: Self.responseBody) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
@main
struct NativeModelServiceTests {
    static func main() async throws {
        try testUnreadableDatasetsArePreserved()
        try testFailedImportRetriesOnPreferenceSave()
        try testImportedDatasetSaveKeepsRITTransient()
        try testDatasetOnlySaveDoesNotReplacePreferences()
        try testCallerSpeedSelectionPersists()
        try await test304WithoutCachedBodyRetriesUnconditionally()
        try testUserAgentRequiresVersion()
        try await testRefreshWithoutVersionSendsNoRequest()
        try await testUnchangedListingSkipsDownload()
        try await testServerIsContactedAtMostOncePerDay()
        try await testOfflineAttemptDoesNotCountTowardLimit()
        try await testUserRefreshIsNotLimited()
        try await testAutomaticRefreshBacksOffAfterTransportFailures()
        print("Native model/service checks passed (13).")
    }

    static func testCallerSpeedSelectionPersists() throws {
        let fixture = try Fixture()
        let store = SettingsStore(defaults: fixture.defaults, directory: fixture.directory)
        var settings = ContestSettings()
        settings.wpm = 10
        settings.dxMinWpm = -1
        settings.dxMaxWpm = 2
        // Seed the old payload directly, before normalization adds a selection.
        fixture.defaults.set(try JSONEncoder().encode(settings), forKey: "com.z10f.morsejogger.settings.v2")
        var loaded = store.load()
        try require(loaded.callerSpeedMode == .halfToFull, "old -1 settings must select percentage mode")
        loaded.callerSpeedMode = .custom
        loaded.dxMinWpm = 8
        store.save(loaded)
        store.flush()
        loaded = SettingsStore(defaults: fixture.defaults, directory: fixture.directory).load()
        try require(loaded.callerSpeedMode == .custom, "custom selection must persist")
        try require(loaded.dxMinWpm == 8 && loaded.dxMaxWpm == 2, "custom offsets must persist at low operating speeds")
    }

    static func testUnreadableDatasetsArePreserved() throws {
        for bytes in [Data("broken JSON".utf8), Data("{\"version\":999,\"customCalls\":[],\"customRecords\":{},\"contestHistories\":{},\"countryPrefixes\":{}}".utf8)] {
            let fixture = try Fixture()
            let path = fixture.directory.appendingPathComponent("Imported-Datasets-v1.json")
            try bytes.write(to: path)
            let store = SettingsStore(defaults: fixture.defaults, directory: fixture.directory)
            var settings = store.load()
            try require(store.loadWarning != nil, "unreadable data must be reported")
            settings.wpm = 30
            store.save(settings)
            store.flush()
            let backups = try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.contains("unreadable-") }
            try require(backups.count == 1, "original data must be preserved")
            let preserved = try Data(contentsOf: backups[0])
            try require(preserved == bytes, "backup must retain exact original bytes")
        }
    }

    static func testFailedImportRetriesOnPreferenceSave() throws {
        let fixture = try Fixture()
        let store = SettingsStore(defaults: fixture.defaults, directory: fixture.directory)
        var settings = store.load()
        store.save(settings)
        store.flush()
        let backup = fixture.root.appendingPathComponent("saved-support")
        try FileManager.default.moveItem(at: fixture.directory, to: backup)
        try Data("blocking file".utf8).write(to: fixture.directory)
        settings.customCalls = ["K1ABC"]
        let result = TestFlag()
        store.save(settings, datasetsChanged: true) { result.set($0) }
        store.flush()
        try require(!result.get(), "failed dataset writes must be reported")
        try FileManager.default.removeItem(at: fixture.directory)
        try FileManager.default.moveItem(at: backup, to: fixture.directory)
        settings.wpm = 30
        store.save(settings) { result.set($0) }
        store.flush()
        try require(result.get(), "preference save should retry pending data")
        let loaded = SettingsStore(defaults: fixture.defaults, directory: fixture.directory).load()
        try require(loaded.customCalls == ["K1ABC"], "retry must persist the imported calls")
        try require(loaded.wpm == 30, "retry must persist latest preferences")
    }

    static func testImportedDatasetSaveKeepsRITTransient() throws {
        let fixture = try Fixture()
        let store = SettingsStore(defaults: fixture.defaults, directory: fixture.directory)
        var settings = store.load()
        settings.customCalls = ["W1AW"]
        settings.customRecords["W1AW"] = HistoryRecord(call: "W1AW")
        settings.rit = 150
        let completed = DispatchSemaphore(value: 0)
        let succeeded = TestFlag()
        store.save(settings, datasetsChanged: true) { result in
            succeeded.set(result)
            completed.signal()
        }
        try require(completed.wait(timeout: .now() + 5) == .success, "background persistence should finish")
        store.flush()
        try require(succeeded.get(), "preferences and datasets should save")
        let reloaded = SettingsStore(defaults: fixture.defaults, directory: fixture.directory).load()
        try require(reloaded.customCalls == ["W1AW"], "new imported data should reload")
        try require(reloaded.customRecords["W1AW"]?.call == "W1AW", "new records should reload")
        try require(reloaded.rit == 0, "transient RIT must not persist")
    }

    static func testDatasetOnlySaveDoesNotReplacePreferences() throws {
        let fixture=try Fixture()
        let store=SettingsStore(defaults:fixture.defaults,directory:fixture.directory)
        var valid=store.load();valid.wpm=30
        store.save(valid);store.flush()

        var invalidDraft=valid
        invalidDraft.serialRange = .custom
        invalidDraft.serialMin=20
        invalidDraft.serialMax=10
        invalidDraft.customCalls=["K1ABC"]
        invalidDraft.customRecords["K1ABC"]=HistoryRecord(call:"K1ABC")
        let completed=DispatchSemaphore(value:0)
        let succeeded=TestFlag()
        store.saveDatasets(invalidDraft) { result in succeeded.set(result);completed.signal() }
        try require(completed.wait(timeout:.now()+5) == .success,"dataset-only persistence should finish")
        store.flush()

        let reloaded=SettingsStore(defaults:fixture.defaults,directory:fixture.directory).load()
        try require(succeeded.get(),"datasets should save without preferences")
        try require(reloaded.wpm==30,"last valid preferences should remain stored")
        try require(reloaded.serialRange == .start,"invalid serial draft must not replace preferences")
        try require(reloaded.customCalls == ["K1ABC"],"datasets should persist independently")
    }

    static func test304WithoutCachedBodyRetriesUnconditionally() async throws {
        let fixture = try Fixture()
        let metadata = SCPDataService.Metadata(etag: "old-tag", lastModified: "yesterday",
            checkedAt: Date(timeIntervalSince1970: 100), source: testSourceKey, downloadedHash: "old-hash")
        let metadataData = try PropertyListEncoder().encode(metadata)
        try metadataData.write(to: fixture.directory.appendingPathComponent("SCP-cache-metadata.plist"))

        RetryURLProtocol.reset()
        RetryURLProtocol.requestHandler = { _, index in index == 0 ? 304 : 200 }
        let service = makeService(fixture)
        let refreshed = await service.refresh(force: true)
        try require(refreshed, "unconditional retry should download SCP data")
        try require(RetryURLProtocol.listingHeaders.count == 1, "the file should be looked up in the listing first")
        try require(RetryURLProtocol.requestCount == 2, "304 without body should make one retry")
        try require(RetryURLProtocol.requestHeaders[0]["If-None-Match"] == "", "missing cache must not send ETag")
        try require(RetryURLProtocol.requestHeaders[1]["If-None-Match"] == "", "retry must be unconditional")
        try require(service.history?.calls == ["K1ABC"], "retry result should populate cache")
        try require((RetryURLProtocol.requestHeaders + RetryURLProtocol.listingHeaders)
                        .allSatisfy { $0["User-Agent"] == "MorseJogger/9.8.7 (+test@example.invalid)" },
                    "every request should carry the versioned User-Agent")
    }

    static let testSiteURL = URL(string: "https://scp.invalid/")!
    static let testSourceKey = "https://scp.invalid/downloads/MASTER.SCP"

    private static func makeService(_ fixture: Fixture, bundleInfo: [String: Any]? = nil,
                            decode: (@Sendable (Data) throws -> ImportedHistory)? = nil) -> SCPDataService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryURLProtocol.self]
        return SCPDataService(siteURL: testSiteURL, session: URLSession(configuration: configuration),
            directory: fixture.directory,
            decode: decode ?? { _ in var history = ImportedHistory(); history.calls = ["K1ABC"]; return history },
            bundleInfo: bundleInfo ?? testBundleInfo)
    }

    static func testUnchangedListingSkipsDownload() async throws {
        let fixture = try Fixture()
        try Data("cached".utf8).write(to: fixture.directory.appendingPathComponent("MASTER.SCP"))
        // Headers quote the ETag; the listing does not.
        let metadata = SCPDataService.Metadata(etag: "\"same-tag\"", lastModified: "yesterday",
            checkedAt: Date(timeIntervalSince1970: 100), source: testSourceKey, downloadedHash: nil)
        try PropertyListEncoder().encode(metadata).write(to: fixture.directory.appendingPathComponent("SCP-cache-metadata.plist"))
        RetryURLProtocol.reset()
        RetryURLProtocol.listingETag = "same-tag"
        let service = makeService(fixture)
        let refreshed = await service.refresh(force: true)
        try require(refreshed, "an unchanged file should count as a successful check")
        try require(RetryURLProtocol.listingHeaders.count == 1, "the listing should be checked")
        try require(RetryURLProtocol.requestCount == 0, "an unchanged ETag must not download the file")
        try require(service.history?.calls == ["K1ABC"], "the saved copy should stay in use")
    }

    static func testServerIsContactedAtMostOncePerDay() async throws {
        let fixture = try Fixture()
        RetryURLProtocol.reset()
        struct Unparseable: Error {}
        let start = Date(timeIntervalSince1970: 1_000_000)
        let failing = makeService(fixture, decode: { _ in throw Unparseable() })
        let first = await failing.refresh(force: true, automatic: true, now: start)
        try require(!first, "an unusable download should fail")
        try require(RetryURLProtocol.listingHeaders.count == 1 && RetryURLProtocol.requestCount == 1, "the first attempt should reach the server")
        _ = await failing.refresh(force: true, automatic: true, now: start.addingTimeInterval(60 * 60))
        try require(RetryURLProtocol.listingHeaders.count == 1 && RetryURLProtocol.requestCount == 1,
                    "a second attempt within a day must not contact the server")
        // The limit survives a relaunch.
        let relaunched = makeService(fixture)
        _ = await relaunched.refresh(force: true, automatic: true, now: start.addingTimeInterval(2 * 60 * 60))
        try require(RetryURLProtocol.listingHeaders.count == 1, "the saved contact time should hold after a relaunch")
        let later = await relaunched.refresh(force: true, automatic: true, now: start.addingTimeInterval(25 * 60 * 60))
        try require(later, "an attempt after a day should be allowed")
        try require(RetryURLProtocol.listingHeaders.count == 2, "the server should be contacted again after a day")
    }

    static func testUserRefreshIsNotLimited() async throws {
        let fixture = try Fixture()
        RetryURLProtocol.reset()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let service = makeService(fixture)
        let first = await service.refresh(force: true, automatic: true, now: start)
        try require(first, "the first check should download the file")
        _ = await service.refresh(force: true, now: start.addingTimeInterval(60))
        try require(RetryURLProtocol.listingHeaders.count == 2,
                    "a refresh the user asks for must go ahead within the day")
        _ = await service.refresh(force: true, automatic: true, now: start.addingTimeInterval(120))
        try require(RetryURLProtocol.listingHeaders.count == 2,
                    "the user's check should still count toward the automatic limit")
    }

    /// A download that drops after the listing answered must not use up the
    /// daily check; automatic retries wait one minute, then two.
    static func testAutomaticRefreshBacksOffAfterTransportFailures() async throws {
        let fixture = try Fixture()
        RetryURLProtocol.reset()
        RetryURLProtocol.requestHandler = { _, index in index < 2 ? 0 : 200 }
        let start = Date(timeIntervalSince1970: 1_000_000)
        func attempt(_ service: SCPDataService, at offset: TimeInterval, automatic: Bool = true) async -> Bool {
            await service.refresh(force: true, automatic: automatic, now: start.addingTimeInterval(offset))
        }
        let service = makeService(fixture)
        let dropped = await attempt(service, at: 0)
        try require(!dropped && RetryURLProtocol.requestCount == 1, "the first download should drop")
        _ = await attempt(service, at: 30)
        try require(RetryURLProtocol.listingHeaders.count == 1, "no automatic retry inside the first minute")
        // The wait survives a relaunch.
        let relaunched = makeService(fixture)
        _ = await attempt(relaunched, at: 45)
        try require(RetryURLProtocol.listingHeaders.count == 1, "the saved wait should hold after a relaunch")
        let second = await attempt(relaunched, at: 61)
        try require(!second && RetryURLProtocol.requestCount == 2, "after a minute the retry should run and drop again")
        _ = await attempt(relaunched, at: 61 + 90)
        try require(RetryURLProtocol.requestCount == 2, "the second wait should be two minutes")
        let third = await attempt(relaunched, at: 61 + 121)
        try require(third && RetryURLProtocol.requestCount == 3, "after two minutes the retry should succeed")
        try require(SCPDataService.retryDelay(afterFailures: 40) == SCPDataService.minimumContactInterval,
                    "the wait should stop growing at one day")
        // The user is never made to wait.
        let other = try Fixture()
        RetryURLProtocol.reset()
        RetryURLProtocol.listingOffline = true
        let manual = makeService(other)
        _ = await attempt(manual, at: 0, automatic: false)
        RetryURLProtocol.listingOffline = false
        let retried = await attempt(manual, at: 1, automatic: false)
        try require(retried, "a refresh the user asks for should ignore the wait")
    }

    static func testOfflineAttemptDoesNotCountTowardLimit() async throws {
        let fixture = try Fixture()
        RetryURLProtocol.reset()
        RetryURLProtocol.listingOffline = true
        let start = Date(timeIntervalSince1970: 1_000_000)
        let service = makeService(fixture)
        let offline = await service.refresh(force: true, now: start)
        try require(!offline, "an offline attempt should fail")
        RetryURLProtocol.listingOffline = false
        let online = await service.refresh(force: true, now: start.addingTimeInterval(60))
        try require(online, "an attempt that never reached the server must not block the next one")
        try require(RetryURLProtocol.listingHeaders.count == 2 && RetryURLProtocol.requestCount == 1,
                    "the retry should look up and download the file")
    }

    static let testBundleInfo: [String: Any] = ["CFBundleShortVersionString": "9.8.7", "SCPContact": "test@example.invalid"]

    static func testUserAgentRequiresVersion() throws {
        try require(SCPDataService.userAgent(info: testBundleInfo) == "MorseJogger/9.8.7 (+test@example.invalid)",
                    "User-Agent should carry version and contact")
        try require(SCPDataService.userAgent(info: ["CFBundleShortVersionString": "9.8.7", "SCPContact": " "]) == "MorseJogger/9.8.7",
                    "an empty contact should be left out")
        try require(SCPDataService.userAgent(info: ["CFBundleShortVersionString": "9.8.7"]) == "MorseJogger/9.8.7",
                    "a missing contact should be left out")
        try require(SCPDataService.userAgent(info: ["SCPContact": "test@example.invalid"]) == nil,
                    "no version should give no User-Agent")
        try require(SCPDataService.userAgent(info: ["CFBundleShortVersionString": " ", "SCPContact": "test@example.invalid"]) == nil,
                    "an empty version should give no User-Agent")
    }

    static func testRefreshWithoutVersionSendsNoRequest() async throws {
        let fixture = try Fixture()
        RetryURLProtocol.reset()
        let service = makeService(fixture, bundleInfo: ["SCPContact": "test@example.invalid"])
        let refreshed = await service.refresh(force: true)
        try require(!refreshed, "refresh without a version should fail")
        try require(RetryURLProtocol.requestCount == 0 && RetryURLProtocol.listingHeaders.isEmpty,
                    "no request may be sent without a version")
        try require(service.status == SCPDataService.CacheError.missingVersion.localizedDescription,
                    "status should say why SCP was not downloaded")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure(message) }
    }
    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw TestFailure(message) }
        return value
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private struct Fixture {
    let root: URL
    let directory: URL
    let defaults: UserDefaults
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        directory = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteName = "MorseJoggerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw TestFailure("could not create isolated defaults") }
        self.defaults = defaults
        defaults.removePersistentDomain(forName: suiteName)
    }
}
