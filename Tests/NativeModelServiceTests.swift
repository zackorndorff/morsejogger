//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------
import Foundation
import MorseJoggerCore

final class RetryURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHeaders: [[String: String]] = []
    nonisolated(unsafe) static var responseBody = Data("valid".utf8)
    nonisolated(unsafe) static var requestHandler: ((URLRequest, Int) -> Int) = { _, _ in 200 }
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let index = Self.requestCount
        Self.requestCount += 1
        Self.requestHeaders.append([
            "If-None-Match": request.value(forHTTPHeaderField: "If-None-Match") ?? "",
            "If-Modified-Since": request.value(forHTTPHeaderField: "If-Modified-Since") ?? "",
            "User-Agent": request.value(forHTTPHeaderField: "User-Agent") ?? ""
        ])
        let status = Self.requestHandler(request, index)
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
        print("Native model/service checks passed (8).")
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
        let source = URL(string: "https://scp.invalid/MASTER.SCP")!
        let metadata = SCPDataService.Metadata(etag: "old-tag", lastModified: "yesterday",
            checkedAt: Date(timeIntervalSince1970: 100), source: source.absoluteString, downloadedHash: "old-hash")
        let metadataData = try PropertyListEncoder().encode(metadata)
        try metadataData.write(to: fixture.directory.appendingPathComponent("SCP-cache-metadata.plist"))

        RetryURLProtocol.requestCount = 0
        RetryURLProtocol.requestHeaders = []
        RetryURLProtocol.requestHandler = { _, index in index == 0 ? 304 : 200 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryURLProtocol.self]
        let service = SCPDataService(sourceURL: source, session: URLSession(configuration: configuration),
            directory: fixture.directory, decode: { _ in
                var history = ImportedHistory()
                history.calls = ["K1ABC"]
                return history
            }, bundleInfo: testBundleInfo)
        let refreshed = await service.refresh(force: true)
        try require(refreshed, "unconditional retry should download SCP data")
        try require(RetryURLProtocol.requestCount == 2, "304 without body should make one retry")
        try require(RetryURLProtocol.requestHeaders[0]["If-None-Match"] == "", "missing cache must not send ETag")
        try require(RetryURLProtocol.requestHeaders[1]["If-None-Match"] == "", "retry must be unconditional")
        try require(service.history?.calls == ["K1ABC"], "retry result should populate cache")
        try require(RetryURLProtocol.requestHeaders.allSatisfy { $0["User-Agent"] == "Morse Jogger v9.8.7 (+test@example.invalid)" },
                    "every request should carry the versioned User-Agent")
    }

    static let testBundleInfo: [String: Any] = ["CFBundleShortVersionString": "9.8.7", "SCPContact": "test@example.invalid"]

    static func testUserAgentRequiresVersion() throws {
        try require(SCPDataService.userAgent(info: testBundleInfo) == "Morse Jogger v9.8.7 (+test@example.invalid)",
                    "User-Agent should carry version and contact")
        try require(SCPDataService.userAgent(info: ["CFBundleShortVersionString": "9.8.7", "SCPContact": " "]) == "Morse Jogger v9.8.7",
                    "an empty contact should be left out")
        try require(SCPDataService.userAgent(info: ["CFBundleShortVersionString": "9.8.7"]) == "Morse Jogger v9.8.7",
                    "a missing contact should be left out")
        try require(SCPDataService.userAgent(info: ["SCPContact": "test@example.invalid"]) == nil,
                    "no version should give no User-Agent")
        try require(SCPDataService.userAgent(info: ["CFBundleShortVersionString": " ", "SCPContact": "test@example.invalid"]) == nil,
                    "an empty version should give no User-Agent")
    }

    static func testRefreshWithoutVersionSendsNoRequest() async throws {
        let fixture = try Fixture()
        RetryURLProtocol.requestCount = 0
        RetryURLProtocol.requestHeaders = []
        RetryURLProtocol.requestHandler = { _, _ in 200 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryURLProtocol.self]
        let service = SCPDataService(sourceURL: URL(string: "https://scp.invalid/MASTER.SCP")!,
            session: URLSession(configuration: configuration), directory: fixture.directory,
            decode: { _ in var history = ImportedHistory(); history.calls = ["K1ABC"]; return history },
            bundleInfo: ["SCPContact": "test@example.invalid"])
        let refreshed = await service.refresh(force: true)
        try require(!refreshed, "refresh without a version should fail")
        try require(RetryURLProtocol.requestCount == 0, "no request may be sent without a version")
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
