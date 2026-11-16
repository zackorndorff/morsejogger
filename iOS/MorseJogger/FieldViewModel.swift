//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import Foundation
import SwiftUI
import MorseJoggerCore

/// Immutable values that the game screen can render without depending on the
/// simulator's mutable station/event models.
struct FieldSessionPresentation: Equatable {
    let running: Bool
    let radioState: FieldRadioState
    let remaining: Double
    let contacts: Int
    let verified: Int
    let multipliers: Int
    let score: Int
    let rate: Int
    let phase: String
    let serial: Int
    let selectedCall: String?
    let waitingCalls: [String]
    static let empty = FieldSessionPresentation(running:false,radioState:.stopped,remaining:0,contacts:0,verified:0,multipliers:0,score:0,rate:0,phase:"WAITING",serial:1,selectedCall:nil,waitingCalls:[])
}

enum ResultsPreviewPreset: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case zeroMultipliers = "Zero multipliers"
    case hst = "HST"
    case highScore = "High score"

    var id: String { rawValue }
}

enum FieldRadioState: Equatable {
    case onAir, paused, stopped
    var title: String {
        switch self { case .onAir: "ON AIR"; case .paused: "PAUSED"; case .stopped: "SESSION ENDED" }
    }
    var symbol: String {
        switch self { case .onAir: "circle.fill"; case .paused: "pause.circle.fill"; case .stopped: "stop.circle.fill" }
    }
    var color: Color {
        switch self { case .onAir: .green; case .paused: .purple; case .stopped: .secondary }
    }
}

struct FieldActivityPresentation: Equatable, Identifiable {
    let id: Int
    let channel: String
    let text: String
    let tone: ActivityTone
    enum ActivityTone: Equatable { case transmit, receive, system }
}

@MainActor final class FieldViewModel: ObservableObject {
    @Published var settings: ContestSettings {
        didSet {
            let normalized = SettingsStore.normalized(settings, after: oldValue)
            if preferencesChanged(settings, normalized) || settings.rit != normalized.rit { settings = normalized }
            let datasetsChanged = datasetSaveRequested
            datasetSaveRequested = false
            if preferencesChanged(oldValue, normalized) || datasetsChanged {
                scheduleSettingsSave(normalized, datasetsChanged: datasetsChanged)
            }
            guard radioSettingsChanged(from: oldValue, to: normalized) else { return }
            applyLiveRadioSettings(normalized)
        }
    }
    private var snapshot: SessionSnapshot?
    private var resultsPreviewContestOverride: ContestID?
    private var nextActivityID = 0
    @Published private(set) var presentation = FieldSessionPresentation.empty
    @Published private(set) var activity: [FieldActivityPresentation] = []
    @Published private(set) var log: [QSOEntry] = []
    @Published private(set) var selectedLogCall: String?
    @Published var callsign = "" {
        didSet { if callsign != oldValue { selectedLogCall=nil } }
    }
    @Published var exchangeFirst = ""
    @Published var exchangeSecond = ""
    @Published private(set) var sweepstakesHintToken = 0
    /// Bumped when MRCE's `Advance` runs; `entryAdvanceTarget` is the box to focus.
    @Published private(set) var entryAdvanceToken = 0
    private(set) var entryAdvanceTarget: QSOEntryField = .callsign
    @Published var showResults = false
    @Published var showingGame = false
    @Published var muted = false
    @Published private(set) var entryValidation: RadioNoticeCode?
    @Published var audioAlert: String?
    @Published var sessionControlsAlert: String?
    @Published private(set) var settingsLoadWarning: String?
    @Published private(set) var settingsSaveWarning: String?
    @Published private(set) var audioRecoveryAvailable = false
    @Published var importMessage = "No imported history for this contest"
    /// Older SST history payloads retain their unique calls and records but
    /// predate the ordered rows needed for duplicate weighting and row-linked
    /// exchange selection. Reimporting replaces this history and clears notice.
    var legacySSTHistoryNeedsReimport: Bool {
        guard let history = settings.contestHistories[ContestID.sst.rawValue] else { return false }
        return history.rows.isEmpty && (!history.calls.isEmpty || !history.records.isEmpty)
    }
    @Published private(set) var scpStatus = "Loading saved Super Check Partial data…"
    @Published private(set) var scpCallCount = 0
    @Published private(set) var scpIsRefreshing = false
    @Published private(set) var scpIsUsingCustomOverride = false
    @Published var automaticSCPDownloads: Bool {
        didSet {
            let consent: SettingsStore.SCPDownloadConsent = automaticSCPDownloads ? .allow : .deny
            scpDownloadConsent = consent
            settingsStore.saveConsent(consent)
            guard automaticSCPDownloads else {
                scpData?.cancelAutomaticRefresh()
                return
            }
            refreshSCPData(automatic: true)
        }
    }
    @Published private(set) var scpDownloadConsent: SettingsStore.SCPDownloadConsent
    @Published private(set) var requiresSCPDownloadConsent = false
    @Published private(set) var lastSessionSeed: UInt32?
    @Published private(set) var preparingSession = false
    @Published private(set) var scpStartError: String?
    @Published private(set) var scpImportError: String?
    @Published var recordedFile: URL?
    @Published var exportedLog: URL?
    @Published var currentlyRecording = false
    private let session = SessionDriver()
    private let audio = FieldAudio()
    private let settingsStore = SettingsStore()
    private let csvExporter = LogCSVExporter()
    private let importedHistoryFiles = ImportedHistoryFileService()
    private var scpData: SCPDataService?
    private var startupRefreshTask: Task<Bool, Never>?
    private var timer: Timer?
    private var settingsSaveTask: Task<Void, Never>?
    private var lastValidSettings=ContestSettings()
    private var hasValidSettingsSnapshot=false
    private var pendingDatasetSave = false
    private var datasetSaveRequested = false
    private var foregroundReconciliation=0
    private var foregroundReconciliationPending=false
    private var pendingSweepstakesHint:(call:String,value:String)?
    private var insertedSweepstakesHint:(call:String,value:String)?
    private var projectedSelectedCall:String?
    private var preHSTSelection:(contest:ContestID,serialRange:SerialRange)?
    init() {
        var loadedSettings=settingsStore.load()
        if loadedSettings.mode == .hstCompetition {
            loadedSettings.contest = .hst
            loadedSettings.serialRange = .start
        }
        settings = loadedSettings
        if loadedSettings.configurationError == nil {
            lastValidSettings=loadedSettings
            hasValidSettingsSnapshot=true
        } else {
            lastValidSettings=ContestSettings()
            lastValidSettings.customCalls=loadedSettings.customCalls
            lastValidSettings.customRecords=loadedSettings.customRecords
            lastValidSettings.contestHistories=loadedSettings.contestHistories
            lastValidSettings.countryPrefixes=loadedSettings.countryPrefixes
        }
        settingsLoadWarning = settingsStore.loadWarning
        let savedConsent = settingsStore.loadConsent() ?? .unresolved
        scpDownloadConsent = savedConsent
        automaticSCPDownloads = savedConsent == .allow
        scpData=SCPDataService(sourceURL:SCPDataService.officialSourceURL)
        startupRefreshTask = Task { @MainActor [weak self] in
            guard let self else {return false}
            guard let scpData=self.scpData else {return false}
            await scpData.loadCacheIfNeeded()
            self.syncSCPState()
            guard self.automaticSCPDownloads else { return scpData.history != nil }
            self.scpIsRefreshing=true
            guard self.automaticSCPDownloads else { return scpData.history != nil }
            await scpData.refresh(force:false, automatic:true)
            self.syncSCPState()
            return scpData.history != nil
        }
    }
    static func resultsPreview(preset: ResultsPreviewPreset = .standard) -> FieldViewModel {
        let vm=FieldViewModel()
        vm.log=[
            QSOEntry(id:1,at:0,call:"K1ABC",copiedCall:"K1ABC",sent:"599 001",received:"599 433",expected:"599 433",correct:true,points:2,multipliers:["K1"],note:"",dupe:false,callError:false,exchangeErrors:[],wpm:25),
            QSOEntry(id:2,at:30,call:"K2DEF",copiedCall:"K2DEF",sent:"599 002",received:"599 042",expected:"599 042",correct:true,points:2,multipliers:["K2"],note:"",dupe:false,callError:false,exchangeErrors:[],wpm:25),
            QSOEntry(id:3,at:60,call:"W2XYZ",copiedCall:"W2XZY",sent:"599 003",received:"599 117",expected:"599 071",correct:false,points:0,multipliers:[],note:"Busted call",dupe:false,callError:true,exchangeErrors:["Serial"],wpm:22),
            QSOEntry(id:4,at:120,call:"N3RST",copiedCall:"N3RST",sent:"599 004",received:"599 104",expected:"599 014",correct:false,points:0,multipliers:[],note:"Exchange differs",dupe:false,callError:false,exchangeErrors:["Serial"],wpm:24),
            QSOEntry(id:5,at:180,call:"K4RST",copiedCall:"K4RST",sent:"599 005",received:"559 027",expected:"599 027",correct:false,points:0,multipliers:[],note:"Exchange differs",dupe:false,callError:false,exchangeErrors:["RST"],wpm:20),
            QSOEntry(id:6,at:240,call:"W1DUP",copiedCall:"W1DUP",sent:"599 006",received:"599 066",expected:"599 066",correct:false,points:0,multipliers:[],note:"Duplicate",dupe:true,callError:false,exchangeErrors:[],wpm:26),
            QSOEntry(id:7,at:300,call:"K2PEND",copiedCall:"K2PEND",sent:"599 007",received:"599 083",expected:"599 083",correct:false,points:0,multipliers:[],note:"Pending TU confirmation",dupe:false,callError:false,exchangeErrors:[],wpm:23,status:.pendingTUConfirmation)
        ]
        let values: (contacts:Int, verified:Int, multipliers:Int, score:Int)
        switch preset {
        case .standard:
            values = (124, 89, 24, 9_176)
        case .zeroMultipliers:
            values = (18, 12, 0, 0)
        case .hst:
            values = (52, 49, 0, 786)
            vm.resultsPreviewContestOverride = .hst
        case .highScore:
            values = (842, 791, 132, 16_996_980)
        }
        vm.presentation=FieldSessionPresentation(running:false,radioState:.stopped,remaining:0,contacts:values.contacts,verified:values.verified,multipliers:values.multipliers,score:values.score,rate:0,phase:"RESULTS",serial:7,selectedCall:nil,waitingCalls:[])
        return vm
    }
    private func radioSettingsChanged(from old: ContestSettings, to new: ContestSettings) -> Bool {
        old.wpm != new.wpm || old.pitch != new.pitch || old.rit != new.rit ||
        old.bandwidth != new.bandwidth || old.monitor != new.monitor ||
        old.activity != new.activity ||
        old.volume != new.volume || old.qsk != new.qsk ||
        (new.mode != .wpxCompetition && new.mode != .hstCompetition && old.effects != new.effects)
    }
    private func preferencesChanged(_ old: ContestSettings, _ new: ContestSettings) -> Bool {
        var oldPreferences = old
        var newPreferences = new
        oldPreferences.rit = newPreferences.rit
        oldPreferences.customCalls = []; newPreferences.customCalls = []
        oldPreferences.customRecords = [:]; newPreferences.customRecords = [:]
        oldPreferences.contestHistories = [:]; newPreferences.contestHistories = [:]
        oldPreferences.countryPrefixes = [:]; newPreferences.countryPrefixes = [:]
        return oldPreferences != newPreferences
    }
    private func scheduleSettingsSave(_ value: ContestSettings, datasetsChanged: Bool) {
        pendingDatasetSave = pendingDatasetSave || datasetsChanged
        settingsSaveTask?.cancel()
        let persistable:ContestSettings
        let savePreferences:Bool
        if value.configurationError == nil {
            lastValidSettings=value
            hasValidSettingsSnapshot=true
            persistable=value
            savePreferences=true
        } else {
            persistable=settingsSnapshot(lastValidSettings,includingDatasetsFrom:value)
            savePreferences=hasValidSettingsSnapshot
        }
        guard savePreferences || pendingDatasetSave else { settingsSaveTask=nil; return }
        settingsSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            let includeDatasets = self.pendingDatasetSave
            self.pendingDatasetSave = false
            if savePreferences { self.persistSettings(persistable, datasetsChanged: includeDatasets) }
            else if includeDatasets { self.persistDatasets(value) }
            self.settingsSaveTask = nil
        }
    }
    private func settingsSnapshot(_ preferences:ContestSettings,includingDatasetsFrom current:ContestSettings)->ContestSettings {
        var snapshot=preferences
        snapshot.customCalls=current.customCalls
        snapshot.customRecords=current.customRecords
        snapshot.contestHistories=current.contestHistories
        snapshot.countryPrefixes=current.countryPrefixes
        return snapshot
    }
    private func persistSettings(_ value: ContestSettings, datasetsChanged: Bool) {
        settingsStore.save(value, datasetsChanged: datasetsChanged) { [weak self] succeeded in
            Task { @MainActor [weak self] in
                if succeeded { self?.settingsSaveWarning=nil }
                else { self?.settingsSaveWarning = "Settings could not be saved. Free storage and change a setting to retry." }
            }
        }
    }
    private func persistDatasets(_ value:ContestSettings) {
        settingsStore.saveDatasets(value) { [weak self] succeeded in
            Task { @MainActor [weak self] in
                if succeeded { self?.settingsSaveWarning=nil }
                else { self?.settingsSaveWarning="Settings could not be saved. Free storage and change a setting to retry." }
            }
        }
    }
    private func flushSettingsSave() {
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        let includeDatasets = pendingDatasetSave
        pendingDatasetSave = false
        if settings.configurationError == nil {
            lastValidSettings=settings
            hasValidSettingsSnapshot=true
            persistSettings(settings, datasetsChanged: includeDatasets)
        } else if hasValidSettingsSnapshot {
            persistSettings(settingsSnapshot(lastValidSettings,includingDatasetsFrom:settings),datasetsChanged:includeDatasets)
        } else if includeDatasets {
            persistDatasets(settings)
        }
        settingsStore.flush()
    }
    private func applyLiveRadioSettings(_ settings: ContestSettings) {
        guard session.running else { return }
        session.updateRadio(settings)
        let effective = session.settings ?? settings
        audio.monitorDecibels = effective.monitor
        if session.audioHasStarted { audio.configureReceiver(settings: effective) }
    }
    var currentContest: ContestID {settings.contest}
    var hstConfigurationError: String? { settings.hstConfigurationError }
    var sentExchangeConfigurationError: String? { settings.sentExchangeConfigurationError }
    var startConfigurationError: String? { settings.configurationError }
    func selectContest(_ contest:ContestID) {
        guard settings.mode != .hstCompetition || settings.hstConfigurationError != nil else { return }
        var updated=settings
        updated.contest=contest
        settings=updated
    }
    func selectSerialRange(_ range:SerialRange) {
        guard settings.mode != .hstCompetition || settings.hstConfigurationError != nil else { return }
        var updated=settings
        updated.serialRange=range
        settings=updated
    }
    func selectSessionMode(_ mode:SessionMode) {
        var updated=settings
        if mode == .hstCompetition {
            if settings.mode != .hstCompetition {
                let rememberedRange=settings.serialRange == .custom && !settings.contest.definition.supportsCustomSerialRange
                    ? SerialRange.start : settings.serialRange
                if settings.customSerialRangeError == nil {
                    preHSTSelection=(settings.contest,rememberedRange)
                } else {
                    preHSTSelection=nil
                }
            }
            updated.mode=mode
            updated.contest = .hst
            updated.serialRange = .start
        } else if settings.mode == .hstCompetition && mode != .hstCompetition {
            updated.mode=mode
            if let previous=preHSTSelection {
                updated.contest=previous.contest
                updated.serialRange=previous.serialRange
            }
            preHSTSelection=nil
        } else {
            updated.mode=mode
        }
        settings=updated
    }
    var activeSettings:ContestSettings {
        if let resultsPreviewContestOverride {
            var preview = settings.effective()
            preview.contest = resultsPreviewContestOverride
            return preview
        }
        return session.settings ?? settings.effective()
    }
    var callsignInformation:ContestRules.CallsignInformation? {
        guard let call=ContestRules.callsignInformationCall(typedCall:callsign,
            selectedLogCall:selectedLogCall,activeCall:presentation.selectedCall,
            latestLogCall:log.last?.call) else { return nil }
        return ContestRules.callsignInformation(call,settings:settings)
    }
    func selectLogCall(_ call:String) { selectedLogCall=ContestRules.normalizeCall(call) }
    var naqpCallerIsDX: Bool {
        let meta = ContestRules.callMeta(callsign, settings: activeSettings)
        return currentContest == .naqp && meta.known && !meta.isNAQPLocal
    }
    var exchange:String {ContestRules.joinReceivedExchangeFields(first:exchangeFirst,second:exchangeSecond)}
    var callerSummary: (selected: String?, waiting: [String]) {
        (session.target?.call, session.pileup.map(\.call))
    }
    /// Ground truth for the active callers, projected as immutable display data.
    var callerAnswers: [(call: String, exchange: String)] {
        let active = session.pileup.filter { ![.done, .failed].contains($0.opState) }
        guard !active.isEmpty else { return [] }
        let target = session.target.flatMap { station in
            active.first(where: { $0.call == station.call })
        }
        let ordered = target.map { selected in [selected] + active.filter { $0.call != selected.call } } ?? active
        return ordered.map { ($0.call, $0.exchange) }
    }
    var sentExchange:String {ContestRules.sentExchange(settings,ownSerial:(snapshot?.serial ?? 1))}
    var ssProgress:SweepstakesProgress? {
        settings.contest == .sweepstakes ? SweepstakesParser.parse(call:callsign,exchange:exchange) : nil
    }
    func start() {
        guard settings.configurationError == nil else { return }
        guard !preparingSession else {return}
        guard scpDownloadConsent != .unresolved else {
            requiresSCPDownloadConsent = true
            return
        }
        requiresSCPDownloadConsent = false
        scpStartError=nil
        preparingSession=true
        Task { @MainActor [weak self] in
            guard let self else {return}
            guard let scpData=self.scpData else {
                self.beginSession()
                self.preparingSession=false
                return
            }
            // Cache parsing is shared with the launch-time task. If it yields
            // usable data, continue directly to session construction.
            await scpData.loadCacheIfNeeded()
            self.syncSCPState()
            guard self.scpDownloadConsent != .unresolved else {
                self.preparingSession = false
                self.requiresSCPDownloadConsent = true
                return
            }
            if self.automaticSCPDownloads && scpData.history == nil {
                // Join the one launch-time annual check. Only after that check
                // has failed do a single on-demand retry; refresh() coalesces
                // any simultaneous caller onto its in-flight request.
                if let startupRefreshTask = self.startupRefreshTask {
                    _ = await startupRefreshTask.value
                }
                self.syncSCPState()
                guard self.automaticSCPDownloads else {
                    self.beginSession()
                    self.preparingSession = false
                    return
                }
                if scpData.history == nil && self.automaticSCPDownloads {
                    _ = await scpData.refresh(force:true, automatic:true)
                    self.syncSCPState()
                }
                guard self.automaticSCPDownloads else {
                    self.beginSession()
                    self.preparingSession = false
                    return
                }
                guard scpData.history != nil else {
                    self.scpStartError = scpData.status
                    self.preparingSession = false
                    return
                }
            }
            self.beginSession()
            self.preparingSession=false
        }
    }
    /// Resolves the first-run choice and continues the pending Start action.
    func resolveSCPDownloadConsent(_ consent: SettingsStore.SCPDownloadConsent) {
        guard consent != .unresolved else { return }
        scpDownloadConsent = consent
        settingsStore.saveConsent(consent)
        automaticSCPDownloads = consent == .allow
        requiresSCPDownloadConsent = false
        start()
    }
    func startOfflineAfterSCPFailure() {
        scpStartError=nil
        preparingSession=true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.beginSession()
            self.preparingSession=false
        }
    }
    func retrySCPFromError() {
        scpStartError=nil
        start()
    }
    func dismissSCPStartError() { scpStartError=nil }
    private func beginSession() {
        guard settings.configurationError == nil else { return }
        timer?.invalidate()
        // The receiver offset is a transient in-game control.
        if settings.rit != 0 { settings.rit = 0 }
        configureSessionDriver()
        var startup=settings
        // The app always plays a fresh session; fixed seeds are for the core's tests.
        startup.seed=UInt32.random(in:1...UInt32.max)
        lastSessionSeed = startup.seed
        callsign="";exchangeFirst="";exchangeSecond="";activity=[];nextActivityID=0;log=[];muted=false;audio.muted=false;showResults=false;showingGame=true
        recordedFile=nil;exportedLog=nil;currentlyRecording=false
        audio.monitorDecibels=activeSettings.monitor
        session.start(settings:startup,genericHistory:scpData?.history)
        if session.running {
            // .common modes keep the tick running while a scroll gesture holds the run loop in tracking mode.
            let tickTimer=Timer(timeInterval:512.0/11_025.0,repeats:true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.session.tick() }
            }
            RunLoop.main.add(tickTimer,forMode:.common)
            timer=tickTimer
        }
    }
    func refreshSCPData(automatic: Bool = false) {
        guard !scpIsRefreshing else {return}
        scpIsRefreshing=true
        Task { @MainActor [weak self] in
            guard let self else {return}
            guard let scpData=self.scpData else {
                self.scpStatus="Super Check Partial data service is unavailable."
                self.scpIsRefreshing=false
                return
            }
            await scpData.refresh(force:true, automatic:automatic)
            self.syncSCPState()
        }
    }
    func importCustomSCP(_ url: URL) {
        Task { @MainActor [weak self] in
            guard let self, let scpData = self.scpData else { return }
            do {
                try await scpData.importCustomOverride(from: url)
                self.scpImportError = nil
            } catch {
                self.scpImportError = "Could not import SCP file: \(error.localizedDescription)"
            }
            self.syncSCPState()
        }
    }
    func clearCustomSCP() {
        Task { @MainActor [weak self] in
            guard let self, let scpData = self.scpData else { return }
            await scpData.clearCustomOverride()
            self.syncSCPState()
        }
    }
    private func syncSCPState() {
        scpStatus=scpData?.status ?? "Super Check Partial data service is unavailable."
        scpCallCount=scpData?.history?.calls.count ?? 0
        scpIsRefreshing=scpData?.isRefreshing ?? false
        scpIsUsingCustomOverride=scpData?.isUsingCustomOverride ?? false
    }
    func send(_ command:Command) {
        // Keep keyboard shortcuts and buttons from changing the simulator
        // while lifecycle or session-controls pause is active. STOP remains
        // available to clear any audio that was already queued.
        guard !session.isPaused || command == .stop else { return }
        entryValidation = nil
        let mayLog = command == .log || command == .esm || command == .saveOnly
        let didLog=session.send(command,call:callsign,exchange:exchange,exchangeFirst:exchangeFirst,exchangeSecond:exchangeSecond)
        if command == .wipe || (mayLog && didLog) {
            callsign="";exchangeFirst="";exchangeSecond=""
        }
        syncSessionProjection()
    }
    /// Game screen intent: Enter uses ESM, which may transmit first and only
    /// logs after the simulator's provisional contact is reconciled.
    @discardableResult func submitEntry() -> Bool {
        let previousCount=log.count
        send(.esm)
        return log.count > previousCount
    }
    func saveEntryOnly() { send(.saveOnly) }
    func performGameCommand(_ command:Command) { send(command) }
    func updateCallsignInput(_ value:String) {
        let typed=ContestRules.normalizeCall(value)
        // A key typed into a full box is refused, as in MRCE.
        let normalized=typed.count > ContestRules.callEntryMaxLength && callsign.count == ContestRules.callEntryMaxLength
            ? callsign : String(typed.prefix(ContestRules.callEntryMaxLength))
        guard callsign != normalized else { return }
        entryValidation = nil
        callsign=normalized
        // MRCE Edit1Change: a call still being keyed is corrected on the air.
        session.callEdited(normalized) { [audio] in audio.transmitSecondsBuffered(pieceID:$0) }
    }
    func updateExchangeInput(_ value:String, field:QSOEntryField) {
        // MRCE filters each box key by key: cut-number keys become digits
        // and keys the field does not take are dropped.
        let current=field == .exchangeFirst ? exchangeFirst : exchangeSecond
        let normalized=ContestRules.filterReceivedEntry(value,previous:current,field:field,settings:activeSettings)
        if current != normalized { entryValidation = nil }
        switch field {
        case .exchangeFirst: exchangeFirst=normalized
        case .exchangeSecond: exchangeSecond=normalized
        case .callsign: updateCallsignInput(value)
        }
    }
    func applySpaceEntryDefault(after field:QSOEntryField) {
        // MRCE ProcessSpace: moving on by hand cancels the pending move.
        session.cancelEntryAdvance()
        guard settings.contest.definition.usesRST else { return }
        if field == .callsign && exchangeFirst.isEmpty { exchangeFirst="599" }
        if field == .exchangeFirst && exchangeFirst.isEmpty { exchangeFirst="599" }
    }
    /// MRCE `MainForm.Advance`: the piece being sent has ended after an Enter
    /// that did not log. Fills an empty report and moves the cursor on.
    private func advanceEntryAfterTransmission() {
        if settings.contest.definition.usesRST && exchangeFirst.isEmpty { exchangeFirst="599" }
        entryAdvanceTarget=ContestRules.entryFieldOnAdvance(call:callsign,contest:currentContest)
        entryAdvanceToken &+= 1
    }
    func callEntryBinding() -> Binding<String> {
        Binding(get:{ self.callsign },set:{ self.updateCallsignInput($0) })
    }
    func exchangeEntryBinding(_ field:QSOEntryField) -> Binding<String> {
        Binding(get:{ field == .exchangeFirst ? self.exchangeFirst : self.exchangeSecond },set:{ self.updateExchangeInput($0,field:field) })
    }
    private func dispatchAudio(for event:RadioEvent,settings:ContestSettings,simulationNow:Double,
                               completion:@escaping SessionDriver.AudioCompletion) {
        switch event.kind {
        case .transmit:
            let message=FieldAudio.KeyedMessage(text:event.text,wpm:settings.wpm,characterWpm:event.characterWpm,
                                                fastReportStart:event.fastReportStart,fastReportRate:event.fastReportRate,
                                                fastReportStarts:event.effectiveFastReportStarts)
            audio.playTransmit(message,pitch:settings.pitch,effects:settings.effects,qsk:settings.qsk,pieceID:event.pieceID) { result in
                switch result { case .success(let duration): completion(.transmit(duration:duration)); case .failure(let failure): completion(.failed(failure)) }
            }
        case .receive:
            // Use the event's immutable operator messages. The aggregate text
            // and mutable pileup are presentation/state, not playback sources.
            audio.playReceive(event:event,settings:settings) { result in
                switch result { case .success(let duration): completion(.receive(duration:duration)); case .failure(let failure): completion(.failed(failure)) }
            }
        case .interference:
            // QRM keeps its event timestamp for future audio scheduling, while
            // remaining audio-only (it does not advance the simulator reply timer).
            audio.playReceive(event:event,settings:settings,simulationNow:simulationNow) { [weak self] result in
                if case .failure(let failure) = result { self?.presentAudioFailure(failure.userMessage) }
                completion(.none)
            }
        case .cancelReceive:
            for call in event.stationCalls {audio.cancelReceive(call:call)}
            completion(.none)
        case .rekey:
            if let piece=event.pieceID {audio.rekeyTransmit(pieceID:piece,text:event.text,wpm:settings.wpm,characterWpm:event.characterWpm)}
            completion(.none)
        default:
            completion(.none)
        }
    }
    private func configureSessionDriver() {
        session.dispatchAudio = { [weak self] event, settings, now, completion in
            guard let self else { completion(.none); return }
            self.dispatchAudio(for:event,settings:settings,simulationNow:now,completion:completion)
        }
        session.onEvent = { [weak self] event in
            guard let self else { return }
            let tone: FieldActivityPresentation.ActivityTone
            switch event.kind { case .transmit: tone = .transmit; case .receive: tone = .receive; default: tone = .system }
            let activityText=RadioActivityText.visible(event)
            if event.kind == .notice, let code=event.noticeCode { self.entryValidation=code }
            if !activityText.isEmpty {
                self.activity.insert(FieldActivityPresentation(id:self.nextActivityID,
                    channel:tone == .transmit ? "TX" : tone == .receive ? "RX" : "SYS",
                    text:activityText,tone:tone),at:0)
                self.nextActivityID &+= 1
                if self.activity.count > 100 { self.activity.removeLast() }
            }
            if event.kind == .notice,let hint=self.sweepstakesHint(from:event.text) {
                self.pendingSweepstakesHint=hint
                self.sweepstakesHintToken &+= 1
            }
            if event.kind == .advanceEntry {self.advanceEntryAfterTransmission()}
            if event.kind == .finished {self.showResults=true}
            self.syncSessionProjection()
        }
        session.onStopAudio = { [weak self] in self?.audio.stopPlayback() }
        session.onAudioStart = { [weak self] effective, completion in
            guard let self else { completion(.failure(.suspended)); return }
            self.audio.configureReceiver(settings:effective, completion:completion)
        }
        session.onAudioSuspend = { [weak self] in
            guard let self else { return }; self.audio.suspend()
        }
        session.onAudioResume = { [weak self] completion in
            guard let self else { completion(.failure(.suspended)); return }
            self.audio.resume { result in
                if case .success = result {
                    self.audioRecoveryAvailable=false
                }
                completion(result)
            }
        }
        session.onAudioFailure = { [weak self] failure in
            self?.presentAudioFailure(failure.userMessage)
            self?.audioRecoveryAvailable=true
        }
        session.onFinished = { [weak self] in self?.finishSession() }
        session.onChange = { [weak self] in self?.syncSessionProjection() }
    }
    private func syncSessionProjection() {
        snapshot=session.snapshot
        if log != session.log { log=session.log }
        let state=session.snapshot
        let callers=callerSummary
        if projectedSelectedCall != callers.selected {
            if pendingSweepstakesHint?.call != callers.selected { pendingSweepstakesHint=nil }
            if let insertedSweepstakesHint,exchangeSecond == insertedSweepstakesHint.value {
                exchangeSecond=""
            }
            insertedSweepstakesHint=nil
            projectedSelectedCall=callers.selected
        }
        let radioState:FieldRadioState=session.running ? (session.isPaused ? .paused : .onAir) : .stopped
        let nextPresentation=FieldSessionPresentation(running:state?.running == true,radioState:radioState,remaining:(state?.remaining ?? 0).rounded(.down),contacts:state?.contacts ?? 0,verified:state?.verified ?? 0,multipliers:state?.multipliers ?? 0,score:state?.score ?? 0,rate:state?.rate ?? 0,phase:state?.phase.rawValue.uppercased() ?? "WAITING",serial:state?.serial ?? 1,selectedCall:callers.selected,waitingCalls:callers.waiting)
        if presentation != nextPresentation { presentation=nextPresentation }
    }
    private func sweepstakesHint(from text:String)->(call:String,value:String)? {
        let prefix="History hint for "
        guard text.hasPrefix(prefix),let separator=text.range(of:": ",options:.backwards) else{return nil}
        let call=String(text.dropFirst(prefix.count).prefix(upTo:separator.lowerBound)).uppercased()
        let value=String(text[separator.upperBound...]).uppercased()
        let parts=value.split(separator:" ").map(String.init)
        guard ContestRules.normalizeCall(call)==callerSummary.selected,
              settings.contest == .sweepstakes,settings.showCheckSection > 0,
              let history=settings.contestHistories[ContestID.sweepstakes.rawValue],
              HistoryImport.sweepstakesCheckSection(for:call,in:history) != nil,
              parts.count == 2,parts[0].count == 2,Int(parts[0]) != nil,
              SweepstakesParser.sections.contains(parts[1]) else{return nil}
        return (call,value)
    }
    /// Applies MRCE's selected-call hint only while the exchange control is
    /// focused and empty. A hint arriving earlier remains available until the
    /// operator reaches this field; populated user input always wins.
    func applyPendingSweepstakesHint(exchangeFieldIsFocused:Bool) {
        guard exchangeFieldIsFocused else{return}
        guard let hint=pendingSweepstakesHint else{return}
        guard hint.call == presentation.selectedCall,
              ContestRules.normalizeCall(callsign) == hint.call else { pendingSweepstakesHint=nil; return }
        pendingSweepstakesHint=nil
        guard exchangeSecond.isEmpty else{return}
        entryValidation=nil
        exchangeSecond=hint.value+" "
        insertedSweepstakesHint=(hint.call,exchangeSecond)
    }
    func sceneDidChange(active:Bool,clearStaleInterruption:Bool = false) {
        session.sceneDidChange(active:active)
        if !active {flushSettingsSave();foregroundReconciliation += 1;foregroundReconciliationPending=false}
        // Catalyst may not deliver an AVAudioSession interruption-ended event
        // for an ordinary app switch. On an explicit app activation, discard
        // only that stale audio latch; iOS scene transitions retain the normal
        // interruption notification contract.
        if active && clearStaleInterruption && session.isAudioInterrupted {
            session.clearStaleInterruption()
        } else if active && session.isAudioInterrupted && !session.areSessionControlsPresented {
            reconcileForegroundAudioInterruption()
        }
        // Returning to the foreground is sufficient to resume the clock and
        // audio. Session controls and an active audio interruption still hold
        // their own pause until their corresponding lifecycle event ends.
    }
    func audioInterruption(began:Bool) {
        foregroundReconciliation += 1;foregroundReconciliationPending=false
        session.audioInterruption(began:began)
    }
    /// Session controls are modal: freeze simulator time and all radio audio
    /// for the full lifetime of the sheet, including while it is animating.
    func setSessionControlsPresented(_ presented:Bool) {
        session.setSessionControlsPresented(presented)
        if presented {foregroundReconciliation += 1}
        else if session.isSceneActive && session.isAudioInterrupted {reconcileForegroundAudioInterruption()}
    }
    private func reconcileForegroundAudioInterruption() {
        // iOS can suspend the process before interruptionEnded is delivered.
        // Reconcile against AVAudioSession asynchronously; activation succeeds
        // only when the system permits playback.
        guard !foregroundReconciliationPending else {return}
        foregroundReconciliation += 1
        let generation=foregroundReconciliation
        foregroundReconciliationPending=true
        audio.reconcileForegroundInterruption { [weak self] canActivate in
            guard let self, generation == self.foregroundReconciliation else {return}
            self.foregroundReconciliationPending=false
            guard self.session.isSceneActive, !self.session.areSessionControlsPresented,
                  self.session.isAudioInterrupted else {return}
            guard canActivate else {return}
            self.session.clearStaleInterruption()
        }
    }
    func stop() { session.stop() }
    private func presentAudioFailure(_ text:String) {
        if session.areSessionControlsPresented { sessionControlsAlert=text }
        else { audioAlert=text }
    }
    func retryAudio() {
        audioRecoveryAvailable=false
        audioAlert=nil
        sessionControlsAlert=nil
        session.retryAudio()
    }
    private func finishSession() {
        timer?.invalidate();timer=nil
        syncSessionProjection()
        if currentlyRecording {stopRecording()}
        audio.shutdown()
        showResults=true
    }
    func returnToSetup() {stop();showResults=false;showingGame=false;audio.shutdown();session.reset();activity=[]}
    func toggleMute() {muted.toggle();audio.muted=muted}
    func updateRadio(wpm:Int?=nil, pitch:Int?=nil, rit:Int?=nil, bandwidth:Int?=nil,monitor:Int?=nil,activity:Int?=nil) {
        var updated = settings
        if let wpm { updated.wpm=wpm }; if let pitch { updated.pitch=pitch }
        if let rit { updated.rit=rit }; if let bandwidth { updated.bandwidth=bandwidth }
        if let monitor { updated.monitor=monitor }
        if let activity { updated.activity=activity }
        settings = updated
    }
    func adjustRIT(direction:Int) {
        settings.rit = RadioTuning.adjustedRIT(settings.rit,direction:direction)
    }
    func resetRIT() { settings.rit = 0 }
    func stepSpeed(up:Bool) {
        settings.wpm=RadioTuning.steppedSpeed(activeSettings.wpm,up:up,mode:activeSettings.mode,range:SettingsStore.cwSpeedRange)
    }
    func startRecording() {
        audio.beginRecording { [weak self] result in
            guard let self else {return}
            switch result {
            case .success(let url):
                self.recordedFile=url;self.currentlyRecording=true
            case .failure:
                self.currentlyRecording=false;self.sessionControlsAlert="Could not start WAV recording."
            }
        }
    }
    func stopRecording() {
        audio.endRecording { [weak self] in
            guard let self else {return}
            self.currentlyRecording=false
        }
    }
    func exportCSV() {
        do { exportedLog = try csvExporter.export(log) }
        catch {sessionControlsAlert="Could not export the QSO log. Try again."}
    }
    func importData(_ url:URL) {
        do {
            switch try importedHistoryFiles.read(url, contest: settings.contest) {
            case .countryPrefixes(let prefixes):
                datasetSaveRequested = settings.countryPrefixes != prefixes
                settings.countryPrefixes = prefixes
                importMessage="Imported \(settings.countryPrefixes.count) geographic prefixes"
            case .history(let imported, let replacesCustomCalls):
                if replacesCustomCalls {
                    datasetSaveRequested = settings.customCalls != imported.calls || settings.customRecords != imported.records
                    settings.customCalls = imported.calls
                    settings.customRecords = imported.records
                } else {
                    datasetSaveRequested = settings.contestHistories[settings.contest.rawValue] != imported
                    settings.contestHistories[settings.contest.rawValue] = imported
                }
                importMessage="Imported \(imported.calls.count) calls from \(url.lastPathComponent)"
            }
        } catch {importMessage="Import failed: \(error.localizedDescription)"}
    }
}
