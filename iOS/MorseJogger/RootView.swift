//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import SwiftUI
import UniformTypeIdentifiers
import MorseJoggerCore

private enum FieldTheme {
    static let text=Color.primary
    // Use the standard link/action blue on light backgrounds while keeping
    // the warmer, higher-contrast accent in dark mode.
    static let amber=Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .light ? .systemBlue : .systemOrange
    })
    static let secondary=Color.secondary
}

struct RootView: View {
    @EnvironmentObject private var vm:FieldViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        Group {
            if vm.showingGame {GameView().transition(.opacity)} else {SetupView().transition(.opacity)}
        }
        .sheet(isPresented:Binding(
            get:{vm.showResults && UIDevice.current.userInterfaceIdiom != .pad},
            set:{if !$0 {vm.showResults=false}}
        ),onDismiss:finishResultsDismissal) {
            ResultsSheet(onDone:prepareSetupBehindResults)
                .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented:Binding(
            get:{vm.showResults && UIDevice.current.userInterfaceIdiom == .pad},
            set:{if !$0 {vm.showResults=false}}
        ),onDismiss:finishResultsDismissal) {
            ResultsSheet(onDone:prepareSetupBehindResults)
                .interactiveDismissDisabled()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration:0.25),value:vm.showingGame)
        .background(Color(uiColor:.systemGroupedBackground).ignoresSafeArea())
        .foregroundStyle(FieldTheme.text)
    }

    private func prepareSetupBehindResults() {
        // Switch the route while the results presentation is still attached to
        // this stable root host. Keep that covered route change out of the
        // animation transaction so only the system sheet dismissal animates.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            vm.showingGame=false
        }
    }

    private func finishResultsDismissal() {
        guard !vm.showingGame else { return }
        // The setup route is already in place behind the results presentation.
        // Cleanup should not start a second animation as the system finishes
        // dismissing the results sheet.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            vm.returnToSetup()
        }
    }
}

private struct SetupView:View {
    private enum SetupAlert: Equatable { case hstConfiguration, serialRangeConfiguration, sentExchangeConfiguration, scpUnavailable }
    @EnvironmentObject private var vm:FieldViewModel
    @State private var showImport=false
    @State private var showSCPImport=false
    @State private var showAbout=false
    @State private var setupAlert:SetupAlert?
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment:.top) {
                        VStack(alignment:.leading) {
                            Text("Morse Jogger").font(.system(.largeTitle, design: .rounded).weight(.bold))
                            Text("Amateur radio CW contest simulator").font(.subheadline).foregroundStyle(FieldTheme.secondary)
                        }
                        Spacer()
                        Button { showAbout=true } label: {
                            Label("About",systemImage:"info.circle").labelStyle(.iconOnly).font(.title3)
                                .foregroundStyle(FieldTheme.amber).frame(width:44,height:44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("About Morse Jogger")
                        .accessibilityHint("Shows project information and attributions")
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Session") {
                    if let error=vm.startConfigurationError {
                        Label(error,systemImage:"exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    if let warning=vm.settingsLoadWarning {
                        Label(warning,systemImage:"exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    if let warning=vm.settingsSaveWarning {
                        Label(warning,systemImage:"exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    Picker("Contest",selection:Binding(get:{vm.settings.contest},set:{vm.selectContest($0)})) {
                        ForEach(ContestID.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(vm.settings.mode == .hstCompetition && vm.hstConfigurationError == nil)
                    .tint(FieldTheme.amber)
                    LabeledContent("Exchange",value:vm.settings.contest.exchangeLabel)
                    Picker("Operating mode",selection:Binding(get:{vm.settings.mode},set:{vm.selectSessionMode($0)})) {
                        ForEach(SessionMode.allCases,id:\.self) { Text($0.label).tag($0) }
                    }
                    .tint(FieldTheme.amber)
                    valueSlider("CW speed",value:Binding(get:{Double(vm.settings.effective().wpm)},set:{vm.settings.wpm=Int($0)}),range:Double(SettingsStore.cwSpeedRange.lowerBound)...Double(SettingsStore.cwSpeedRange.upperBound),step:1,suffix:" WPM")
                    // In competition the length comes from Advanced settings.
                    valueSlider(
                        "Session length",
                        value: Binding(get: { Double(vm.settings.effective().duration) }, set: { vm.settings.duration = Int($0) }),
                        range: Double(SettingsStore.practiceDurationRange.lowerBound)...Double(SettingsStore.practiceDurationRange.upperBound),
                        step: 1,
                        suffix: " min"
                    )
                    .disabled(vm.settings.mode == .wpxCompetition || vm.settings.mode == .hstCompetition)
                }
                Section("Setup") {
                    NavigationLink { OperatorSettingsView() } label: {
                        HStack {
                            Label("Operator info",systemImage:"person.text.rectangle").foregroundStyle(FieldTheme.amber)
                            Spacer()
                            Text(vm.settings.myCall.isEmpty ? "Add your callsign" : vm.settings.myCall)
                                .foregroundStyle(FieldTheme.secondary)
                        }
                    }
                    NavigationLink { RadioSettingsView() } label: {
                        Label("Band conditions & radio",systemImage:"antenna.radiowaves.left.and.right").foregroundStyle(FieldTheme.amber)
                    }
                    NavigationLink { StationSettingsView() } label: {
                        Label("Caller behavior",systemImage:"waveform.path").foregroundStyle(FieldTheme.amber)
                    }
                    NavigationLink { CallDatabaseSettingsView(showImport:$showImport,showSCPImport:$showSCPImport) } label: {
                        Label("Callsign data",systemImage:"person.2").foregroundStyle(FieldTheme.amber)
                    }
                    NavigationLink { AdvancedSettingsView() } label: {
                        Label("Advanced settings",systemImage:"gearshape.2").foregroundStyle(FieldTheme.amber)
                    }
                }
                Section {
                    Button {
                        if vm.hstConfigurationError != nil {
                            setupAlert = .hstConfiguration
                        } else if vm.settings.customSerialRangeError != nil {
                            setupAlert = .serialRangeConfiguration
                        } else if vm.sentExchangeConfigurationError != nil {
                            setupAlert = .sentExchangeConfiguration
                        } else {
                            vm.start()
                        }
                    } label: {
                        HStack {
                            Text(vm.preparingSession ? "Preparing caller list…" : "Start Session")
                            Spacer()
                            if vm.preparingSession { ProgressView() } else { Image(systemName:"arrow.up.right") }
                        }
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(FieldTheme.amber)
                        .frame(maxWidth:.infinity,alignment:.leading)
                        .padding(.vertical,4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.preparingSession || vm.settings.configurationError != nil)
                    .alert("Can we download SCP data?", isPresented: Binding(
                        get: { vm.requiresSCPDownloadConsent },
                        set: { _ in }
                    )) {
                        Button("Allow Download") {
                            vm.resolveSCPDownloadConsent(.allow)
                        }
                        Button("Don't Allow", role: .cancel) {
                            vm.resolveSCPDownloadConsent(.deny)
                        }
                    } message: {
                        Text("Morse Jogger can download the Super Check Partial callsign list to make simulated callers more realistic. You can change your choice later in Callsign data settings.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .foregroundStyle(FieldTheme.text)
            .tint(FieldTheme.amber)
            .toolbar(.hidden,for:.navigationBar)
            .sheet(isPresented:$showAbout) { AboutView() }
            .alert(alertTitle, isPresented: Binding(
                get: { setupAlert != nil },
                set: { if !$0 { dismissSetupAlert() } }
            )) {
                switch setupAlert {
                case .hstConfiguration:
                    Button("OK", role:.cancel) { dismissSetupAlert() }
                case .serialRangeConfiguration:
                    Button("OK", role:.cancel) { dismissSetupAlert() }
                case .sentExchangeConfiguration:
                    Button("OK", role:.cancel) { dismissSetupAlert() }
                case .scpUnavailable:
                    Button("Retry") { setupAlert = nil; vm.retrySCPFromError() }
                    Button("Start Offline") { setupAlert = nil; vm.startOfflineAfterSCPFailure() }
                case nil:
                    Button("OK", role:.cancel) { dismissSetupAlert() }
                }
            } message: {
                Text(alertMessage)
            }
            .onChange(of: vm.scpStartError) { _, error in
                if error != nil { setupAlert = .scpUnavailable }
            }
            .fileImporter(isPresented:$showImport,allowedContentTypes:[.data,.plainText,.commaSeparatedText],allowsMultipleSelection:false) { outcome in
                switch outcome {
                case .success(let urls):if let url=urls.first {vm.importData(url)}
                case .failure(let error):vm.importMessage="Import error: \(error.localizedDescription)"
                }
            }
            .fileImporter(isPresented:$showSCPImport,allowedContentTypes:[.data,.plainText],allowsMultipleSelection:false) { outcome in
                switch outcome {
                case .success(let urls): if let url=urls.first { vm.importCustomSCP(url) }
                case .failure(let error): vm.importMessage="SCP import error: \(error.localizedDescription)"
                }
            }
        }
    }

    private var alertTitle: String {
        switch setupAlert {
        case .hstConfiguration: "HST configuration required"
        case .serialRangeConfiguration: "Custom serial range is invalid"
        case .sentExchangeConfiguration: "Sent exchange is invalid"
        case .scpUnavailable: "SCP call list unavailable"
        case nil: ""
        }
    }

    private var alertMessage: String {
        switch setupAlert {
        case .hstConfiguration:
            vm.hstConfigurationError ?? "Choose the HST contest and Start serials before starting HST competition."
        case .serialRangeConfiguration:
            vm.settings.customSerialRangeError ?? "Custom serial bounds must be from 1 to 9999."
        case .sentExchangeConfiguration:
            vm.sentExchangeConfigurationError ?? "Review the sent exchange for this contest before starting."
        case .scpUnavailable:
            "\(vm.scpStartError ?? "The Super Check Partial call list could not be loaded.")\n\nYou can continue with generated callers, or cancel and try again later."
        case nil: ""
        }
    }

    private func dismissSetupAlert() {
        if setupAlert == .scpUnavailable { vm.dismissSCPStartError() }
        setupAlert = nil
    }
}

private struct AboutView:View {
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    VStack(alignment:.leading,spacing:6) {
                        Text("How to set up")
                            .font(.headline)
                        Text("First, choose a contest to practice. I personally like the K1USN SST. Different contests have different exchanges.")
                            .font(.subheadline)
                            .foregroundStyle(FieldTheme.secondary)
                        Text("Next, set a speed to practice at.")
                            .font(.subheadline)
                            .foregroundStyle(FieldTheme.secondary)
                        Text("If you're new to the app, go into Operator info and input your callsign and name for more realistic practice.")
                            .font(.subheadline)
                            .foregroundStyle(FieldTheme.secondary)
                        Text("Then click \"Start Session\".")
                            .font(.subheadline)
                            .foregroundStyle(FieldTheme.secondary)
                    }
                    VStack(alignment:.leading,spacing:6) {
                        Text("How to operate")
                            .font(.headline)
                        Text("Click CQ to start, then work the simulated stations.")
                            .font(.subheadline)
                            .foregroundStyle(FieldTheme.secondary)
                        Text("Enter sends the next message. Space moves between fields.")
                            .font(.subheadline)
                            .foregroundStyle(FieldTheme.secondary)
                    }
                    VStack(alignment:.leading,spacing:10) {
                        Text("Open source acknowledgments")
                            .font(.headline)
                        Text("Morse Jogger is heavily inspired by Morse Runner by Alex Shovkoplyas, VE3NEA, and by the Community Edition fork. All good ideas are theirs, and all bugs are mine.")
                            .font(.subheadline)
                            .foregroundStyle(FieldTheme.secondary)
                        Text("Morse Jogger incorporates upstream work released under the Mozilla Public License 2.0 (MPL-2.0).")
                            .font(.subheadline)
                            .foregroundStyle(FieldTheme.secondary)
                        Link("Morse Runner by Alex Shovkoplyas, VE3NEA",destination:URL(string:"https://github.com/VE3NEA/MorseRunner")!)
                            .font(.subheadline)
                            .foregroundStyle(FieldTheme.secondary)
                        Link("Morse Runner Community Edition contributors",destination:URL(string:"https://github.com/w7sst/MorseRunner")!)
                            .font(.subheadline)
                            .foregroundStyle(FieldTheme.secondary)
                        Link("MPL-2.0 license text",destination:URL(string:"https://www.mozilla.org/en-US/MPL/2.0/")!)
                            .font(.subheadline)
                            .foregroundStyle(FieldTheme.secondary)
                        Text("Morse Jogger (by default) uses data from the Super Check Partial database for generating realistic QSOs.")
                            .font(.subheadline)
                            .foregroundStyle(FieldTheme.secondary)
                    }
                    VStack(alignment:.leading,spacing:8) {
                        Text("Source code")
                            .font(.headline)
                        Text("Source code is available at:")
                            .font(.subheadline)
                            .foregroundStyle(FieldTheme.secondary)
                        Link("https://github.com/zackorndorff/morsejogger",destination:URL(string:"https://github.com/zackorndorff/morsejogger")!)
                    }
                    VStack(alignment:.leading,spacing:8) {
                        Text("Privacy policy")
                            .font(.headline)
                        Text("Privacy policy is available at:")
                            .font(.subheadline)
                            .foregroundStyle(FieldTheme.secondary)
                        Link("https://morsejogger.zackorndorff.com/privacypolicy/",destination:URL(string:"https://morsejogger.zackorndorff.com/privacypolicy/")!)
                    }
                }
                .frame(maxWidth:.infinity,alignment:.leading)
                .padding(20)
            }
            .background(Color(uiColor:.systemGroupedBackground).ignoresSafeArea())
            .foregroundStyle(FieldTheme.text)
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityHint("Closes About")
                }
            }
        }
        .presentationDetents([.medium,.large])
        .presentationDragIndicator(.visible)
    }
}
/// Moves between a form's text fields with the keyboard's Next key: the
/// last field shows Done and closes the keyboard.
private struct FormFieldFocus:ViewModifier {
    let focus:FocusState<String?>.Binding?
    let id:String?
    let next:((String)->String?)?
    func body(content:Content)->some View {
        if let focus,let id {
            let target=next?(id)
            content.focused(focus,equals:id).submitLabel(target == nil ? .done : .next).onSubmit { focus.wrappedValue=target }
        } else { content }
    }
}
/// `caption` is a second, smaller line under the title, used to say why a field is disabled.
private func labeledEntry(_ title:String,text:Binding<String>,placeholder:String="",caption:String?=nil,
                          focus:FocusState<String?>.Binding?=nil,id:String?=nil,next:((String)->String?)?=nil) -> some View {
    HStack(alignment:.center) {
        VStack(alignment:.leading,spacing:2) {
            Text(title)
            if let caption { Text(caption).font(.caption).foregroundStyle(FieldTheme.secondary) }
        }
        Spacer()
        TextField(placeholder.isEmpty ? title : placeholder,text:text)
            .textInputAutocapitalization(.characters).autocorrectionDisabled()
            .textFieldStyle(.roundedBorder).foregroundStyle(.primary)
            .frame(width: 150)
            .modifier(FormFieldFocus(focus:focus,id:id,next:next))
    }
}
private func valueSlider(_ title:String,value:Binding<Double>,range:ClosedRange<Double>,step:Double,suffix:String,prefix:String="") -> some View {
    VStack(spacing:4) {
        HStack {
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Text(prefix+String(format:"%.0f",value.wrappedValue)+suffix).font(.subheadline.monospacedDigit()).foregroundStyle(FieldTheme.amber)
        }
        Slider(value:value,in:range,step:step)
            .accessibilityLabel(title)
            .accessibilityValue(String(format:"%.0f",value.wrappedValue)+suffix)
    }
}
private struct SettingsPage<Content:View>:View {
    let title:String
    @ViewBuilder let content:Content
    var body:some View {
        Form { content }
        .listStyle(.insetGrouped)
        .foregroundStyle(FieldTheme.text)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible,for:.navigationBar)
    }
}

private struct OperatorSettingsView:View {
    @EnvironmentObject private var vm:FieldViewModel
    @FocusState private var focus:String?
    var body:some View {
        let order=["call"]+OperatorExchangeFieldsView.fieldIDs(vm.settings.contest,settings:vm.settings)
        SettingsPage(title:"Operator info") {
            Section {
                NavigationLink {
                    AllOperatorContestInfoView()
                } label: {
                    Label("Edit all contest info",systemImage:"list.bullet.rectangle.portrait")
                }
                labeledEntry("Callsign",text:Binding(get:{vm.settings.myCall},set:{vm.settings.myCall=$0.uppercased()}),placeholder:"K1ABC",
                             focus:$focus,id:"call",next:{nextField(after:$0,in:order)})
            }
            OperatorExchangeFieldsView(contest:vm.settings.contest,focus:$focus,next:{nextField(after:$0,in:order)})
            Section("Cheats") {
                Toggle("Show correct answers",isOn:$vm.settings.showCorrectAnswers)
            }
        }
    }
}
private func nextField(after id:String,in order:[String])->String? {
    guard let index=order.firstIndex(of:id),index+1 < order.count else { return nil }
    return order[index+1]
}

private struct AllOperatorContestInfoView:View {
    @EnvironmentObject private var vm:FieldViewModel
    @FocusState private var focus:String?
    var body:some View {
        let order=["call"]+ContestID.allCases.flatMap { OperatorExchangeFieldsView.fieldIDs($0,settings:vm.settings) }
        SettingsPage(title:"All contest info") {
            Section("Station") {
                labeledEntry("Callsign",text:Binding(get:{vm.settings.myCall},set:{vm.settings.myCall=$0.uppercased()}),placeholder:"K1ABC",
                             focus:$focus,id:"call",next:{nextField(after:$0,in:order)})
            }
            ForEach(ContestID.allCases) { contest in
                OperatorExchangeFieldsView(contest:contest,focus:$focus,next:{nextField(after:$0,in:order)})
            }
        }
    }
}

private struct OperatorExchangeFieldsView:View {
    @EnvironmentObject private var vm:FieldViewModel
    let contest:ContestID
    let focus:FocusState<String?>.Binding
    let next:(String)->String?

    /// The text fields this contest shows for this callsign, in order, as
    /// focus identifiers. Kept beside `body`, which shows the same fields.
    static func fieldIDs(_ contest:ContestID,settings base:ContestSettings)->[String] {
        var settings=base;settings.contest=contest
        let meta=ContestRules.callMeta(settings.myCall,settings:settings)
        let maritime=ContestRules.normalizeCall(settings.myCall).hasSuffix("/MM")
        let keys:[String]
        switch contest {
        case .naqp: keys=meta.isNAQPLocal ? ["name","state"] : ["name"]
        case .sst: keys=["name","state"]
        case .cwt: keys=["name","cwops"]
        case .wpx, .hst, .cqww: keys=[]
        case .arrldx: keys=meta.usve ? ["state"] : ["power"]
        case .fieldday: keys=["class","section"]
        case .sweepstakes: keys=["section","check","precedence"]
        case .pota: keys=["state"]
        case .iaru: keys=settings.exchangeProfile(for:contest).iaruExchangeMode == .society ? ["society"] : []
        case .allja: keys=["prefecture","power"]
        case .acag: keys=["city","power"]
        case .arrl10: keys=maritime || meta.isARRL10Local ? ["state"] : []
        }
        return keys.map { "\(contest.rawValue).\($0)" }
    }
    private func entry(_ title:String,_ key:String,_ keyPath:WritableKeyPath<OperatorExchangeProfile,String>,placeholder:String="",caption:String?=nil)->some View {
        labeledEntry(title,text:profileBinding(keyPath),placeholder:placeholder,caption:caption,focus:focus,id:"\(contest.rawValue).\(key)",next:next)
    }
    private func profileBinding<Value>(_ keyPath:WritableKeyPath<OperatorExchangeProfile,Value>)->Binding<Value> {
        Binding(get:{vm.settings.exchangeProfile(for:contest)[keyPath:keyPath]},set:{value in
            var profile=vm.settings.exchangeProfile(for:contest);profile[keyPath:keyPath]=value
            vm.settings.setExchangeProfile(profile,for:contest)
        })
    }
    private func zoneBinding(text textKeyPath:WritableKeyPath<OperatorExchangeProfile,String>,
                             number numberKeyPath:WritableKeyPath<OperatorExchangeProfile,Int>)->Binding<Int> {
        Binding(get:{Int(vm.settings.exchangeProfile(for:contest)[keyPath:textKeyPath]) ?? 0},set:{value in
            var profile=vm.settings.exchangeProfile(for:contest)
            profile[keyPath:textKeyPath]=String(value)
            profile[keyPath:numberKeyPath]=value
            vm.settings.setExchangeProfile(profile,for:contest)
        })
    }
    private func zonePicker(_ title:String,range:ClosedRange<Int>,text keyPath:WritableKeyPath<OperatorExchangeProfile,String>,number numberKeyPath:WritableKeyPath<OperatorExchangeProfile,Int>)->some View {
        let raw=vm.settings.exchangeProfile(for:contest)[keyPath:keyPath]
        let selected=Int(raw) ?? 0
        return Picker(title,selection:zoneBinding(text:keyPath,number:numberKeyPath)) {
            if !range.contains(selected) { Text(raw.isEmpty ? "Select a value" : "Invalid: \(raw)").tag(selected) }
            ForEach(range,id:\.self) { value in Text("\(value)").tag(value) }
        }
    }
    private var contestSettings:ContestSettings {
        var settings=vm.settings
        settings.contest=contest
        return settings
    }
    /// Whether this contest and callsign send a serial number that can be given a first value.
    private var sendsSerial:Bool {
        switch contest {
        case .wpx, .sweepstakes: return true
        case .arrl10:
            return !(ContestRules.normalizeCall(vm.settings.myCall).hasSuffix("/MM")
                     || ContestRules.callMeta(vm.settings.myCall,settings:contestSettings).isARRL10Local)
        default: return false
        }
    }
    private var firstSerialText:Binding<String> {
        Binding(get:{vm.settings.exchangeProfile(for:contest).firstSerial.map(String.init) ?? ""},set:{ text in
            var profile=vm.settings.exchangeProfile(for:contest)
            profile.firstSerial=Int(String(text.filter(\.isNumber).prefix(4))).flatMap { $0 >= 1 ? $0 : nil }
            vm.settings.setExchangeProfile(profile,for:contest)
        })
    }
    var body:some View {
        Section(contest.label) {
                switch contest {
                case .naqp:
                    entry("Operator name","name",\.name)
                    if ContestRules.callMeta(vm.settings.myCall,settings:contestSettings).isNAQPLocal {
                        entry("State / province","state",\.state)
                    } else {
                        Text("Outside North America and Hawaii, send your name only.").font(.footnote)
                    }
                case .sst:
                    entry("Operator name","name",\.name);entry("SPC","state",\.state)
                case .cwt:
                    entry("Operator name","name",\.name);entry("CWops number / location","cwops",\.cwopsNumber)
                case .wpx: EmptyView()
                case .hst: EmptyView()
                case .cqww: zonePicker("CQ zone",range:1...40,text:\.zoneText,number:\.zone)
                case .arrldx:
                    // Both stay visible; the one this callsign does not send is disabled.
                    let sendsState=ContestRules.callMeta(vm.settings.myCall,settings:contestSettings).usve
                    entry("State / province","state",\.state,caption:sendsState ? nil : "DX calls send power.").disabled(!sendsState)
                    entry("Power","power",\.power,caption:sendsState ? "W/VE calls send state or province." : nil).disabled(sendsState)
                case .fieldday:
                    entry("Field Day class","class",\.fdClass);entry("ARRL section","section",\.section)
                case .sweepstakes:
                    entry("ARRL section","section",\.section);entry("Check","check",\.check);entry("Precedence","precedence",\.precedence)
                case .pota: entry("State","state",\.state)
                case .iaru:
                    Picker("Send",selection:profileBinding(\.iaruExchangeMode)) {
                        Text("ITU zone").tag(IARUExchangeMode.zone)
                        Text("Society").tag(IARUExchangeMode.society)
                    }
                    if vm.settings.exchangeProfile(for:contest).iaruExchangeMode == .zone {
                        zonePicker("ITU zone",range:1...90,text:\.ituZoneText,number:\.ituZone)
                    } else {
                        entry("IARU society","society",\.ituSociety,placeholder:"ARRL")
                    }
                case .allja:
                    entry("Japan prefecture","prefecture",\.jaPrefecture);entry("Japan power","power",\.jaPower)
                case .acag:
                    entry("Japan city code","city",\.jaCity);entry("Japan power","power",\.jaPower)
                case .arrl10:
                    if ContestRules.normalizeCall(vm.settings.myCall).hasSuffix("/MM") {
                        entry("ITU region (1–3)","state",\.state)
                    } else if ContestRules.callMeta(vm.settings.myCall,settings:contestSettings).isARRL10Local {
                        entry("State / province","state",\.state)
                    } else {
                        Text("DX stations send an advancing serial number.").font(.footnote)
                    }
                }
                if sendsSerial {
                    HStack(alignment:.center) {
                        Text("First serial")
                        Spacer()
                        TextField("From serial range",text:firstSerialText)
                            .keyboardType(.numberPad).textFieldStyle(.roundedBorder).frame(width:150)
                    }
                }
                if let error=contestSettings.sentExchangeConfigurationError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                if contestSettings.sentExchangeConfigurationError == nil {
                    let serial=ContestRules.initialOwnSerial(contestSettings)
                    HStack(alignment:.center) {
                        Text("Sample exchange")
                        Spacer()
                        Text(ContestRules.sentExchange(contestSettings,ownSerial:serial))
                            .font(.body.monospaced()).multilineTextAlignment(.trailing)
                    }
                }
        }
    }
}

private struct RadioSettingsView:View {
    @EnvironmentObject private var vm:FieldViewModel
    var body:some View {
        SettingsPage(title:"Band conditions & radio") {
            Section("Simulated band") {
                valueSlider("Band activity",value:Binding(get:{Double(vm.settings.effective().activity)},set:{vm.settings.activity=Int($0)}),range:1...9,step:1,suffix:" / 9",
                            prefix:vm.settings.effective().activity == ContestSettings().activity ? "(default) " : "")
                    // HST fixes it; in single calls there is always exactly one caller.
                    .disabled(vm.settings.mode == .hstCompetition || vm.settings.mode == .single)
                Text("About half this many stations answer each CQ.")
                    .font(.footnote).foregroundStyle(FieldTheme.secondary)
                Toggle("QRN (atmospheric noise)",isOn:effectBinding(\.qrn))
                    .disabled(isCompetition)
                Toggle("QRM (interference)",isOn:effectBinding(\.qrm))
                    .disabled(isCompetition)
                Toggle("QSB (fading)",isOn:effectBinding(\.qsb))
                    .disabled(isCompetition)
                Toggle("Flutter",isOn:effectBinding(\.flutter))
                    .disabled(isCompetition)
                Toggle("LIDs (copying errors)",isOn:effectBinding(\.lids))
                    .disabled(isCompetition)
            }
            if isCompetition {
                Text(vm.settings.mode == .hstCompetition ? "HST competition fixes activity, bandwidth, QRN, QRM, QSB, flutter and LIDs." : "WPX competition fixes QRN, QRM, QSB, flutter and LIDs.")
                    .font(.footnote).foregroundStyle(FieldTheme.secondary)
            }
            Section("Radio") {
                valueSlider("Pitch",value:Binding(get:{Double(vm.settings.pitch)},set:{vm.settings.pitch=Int($0)}),range:300...900,step:50,suffix:" Hz")
                valueSlider("Receiver bandwidth",value:Binding(get:{Double(vm.settings.effective().bandwidth)},set:{vm.settings.bandwidth=Int($0)}),range:100...600,step:50,suffix:" Hz")
                    .disabled(vm.settings.mode == .hstCompetition)
                valueSlider("Monitor level",value:Binding(get:{Double(min(0,max(-60,vm.settings.monitor)))},set:{vm.settings.monitor=Int($0)}),range:(-60)...0,step:1,suffix:" dB")
                valueSlider("Receive volume",value:Binding(get:{min(1,max(0,vm.settings.volume))*100},set:{vm.settings.volume=$0/100}),range:0...100,step:5,suffix:" %")
                Toggle("Full break-in (QSK)",isOn:$vm.settings.qsk)
            }
        }
    }
    private func effectBinding(_ keyPath: WritableKeyPath<Effects, Bool>) -> Binding<Bool> {
        Binding(get: { vm.settings.effective().effects[keyPath: keyPath] }, set: { value in
            vm.settings.effects[keyPath: keyPath] = value
        })
    }
    private var isCompetition: Bool {
        vm.settings.mode == .wpxCompetition || vm.settings.mode == .hstCompetition
    }
}

private struct StationSettingsView:View {
    @EnvironmentObject private var vm:FieldViewModel
    private var hstSerialsLocked:Bool {
        vm.settings.mode == .hstCompetition && vm.hstConfigurationError == nil
    }
    /// MRCE's wording for the serial range menu.
    private static func label(_ range:SerialRange)->String {
        switch range {
        case .start: "Start of contest"
        case .mid: "Mid-contest (50–500)"
        case .end: "End of contest (500–5000)"
        case .custom: "Custom range"
        }
    }
    private var minimumText:Binding<String> { endpointText(isMinimum:true) }
    private var maximumText:Binding<String> { endpointText(isMinimum:false) }

    private func endpointText(isMinimum:Bool)->Binding<String> {
        Binding(get:{
            let value=isMinimum ? vm.settings.serialMin : vm.settings.serialMax
            guard value > 0 else { return "" }
            let width=isMinimum ? vm.settings.serialMinDigitWidth : vm.settings.serialMaxDigitWidth
            let digits=String(value)
            return String(repeating:"0",count:max(0,width-digits.count))+digits
        },set:{ text in
            var updated=vm.settings
            if text.isEmpty {
                if isMinimum { updated.serialMin=0;updated.serialMinDigits=1 }
                else { updated.serialMax=0;updated.serialMaxDigits=1 }
            } else if let value=Int(text), text.allSatisfy(\.isNumber) {
                if isMinimum { updated.serialMin=value;updated.serialMinDigits=text.count }
                else { updated.serialMax=value;updated.serialMaxDigits=text.count }
            }
            vm.settings=updated
        })
    }

    var body:some View {
        SettingsPage(title:"Caller behavior") {
            Section("Caller behavior") {
                Picker("Caller speed", selection: $vm.settings.callerSpeedMode) {
                    Text("50–100% of my speed").tag(CallerSpeedMode.halfToFull)
                    Text("Custom range").tag(CallerSpeedMode.custom)
                }
                .disabled(vm.settings.mode == .hstCompetition)
                if vm.settings.mode == .hstCompetition {
                    Text("HST callers use your speed.")
                        .font(.footnote).foregroundStyle(FieldTheme.secondary)
                } else if vm.settings.callerSpeedMode == .custom {
                    Stepper("Up to \(vm.settings.dxMinWpm) WPM slower",value:$vm.settings.dxMinWpm,in:0...80)
                    Stepper("Up to \(vm.settings.dxMaxWpm) WPM faster",value:$vm.settings.dxMaxWpm,in:0...80)
                    // Below 15 WPM callers are at most 4 WPM slower (MRCE UpdCWMinRxSpeed).
                    Text("Caller range: \(max(5, vm.settings.wpm - (vm.settings.wpm < 15 ? min(4, vm.settings.dxMinWpm) : vm.settings.dxMinWpm)))–\(vm.settings.wpm + vm.settings.dxMaxWpm) WPM")
                        .font(.footnote).foregroundStyle(FieldTheme.secondary)
                }
                Toggle("Caller QRS after repeats",isOn:$vm.settings.callerQrs)
                Toggle("Caller never gives up mid-contact",isOn:$vm.settings.callerStays)
                Toggle("Remove caller on NIL",isOn:$vm.settings.nilInstant)
                Toggle("Faster 5NN",isOn:$vm.settings.fast5nn)
            }
            Section("Serial number") {
                Picker("Serial range",selection:Binding(get:{vm.settings.serialRange},set:{vm.selectSerialRange($0)})) { ForEach(SerialRange.allCases,id:\.self){Text(Self.label($0)).tag($0)} }
                    .disabled(hstSerialsLocked || !vm.settings.customSerialRangeIsRelevant)
                if vm.settings.serialRange == .custom {
                    // Bordered, like every other text field here, so they read as editable.
                    // Shown but disabled in a contest that has no serial number.
                    HStack(alignment:.center) {
                        Text("Custom range")
                        Spacer()
                        TextField("Min",text:minimumText).keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder).frame(width:70)
                            .accessibilityLabel("Custom serial minimum")
                        Text("to").foregroundStyle(FieldTheme.secondary)
                        TextField("Max",text:maximumText).keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder).frame(width:70)
                            .accessibilityLabel("Custom serial maximum")
                    }
                    .disabled(hstSerialsLocked || !vm.settings.customSerialRangeIsRelevant)
                    Text("Choose 1 to 9999, with the maximum exclusive.")
                        .font(.footnote).foregroundStyle(FieldTheme.secondary)
                    if let error=vm.settings.customSerialRangeError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                if hstSerialsLocked {
                    Text("HST competition locks serial settings to the required Start range.")
                        .font(.footnote).foregroundStyle(FieldTheme.secondary)
                }
            }
            Section("SST") {
                Stepper("Farnsworth character speed \(vm.settings.farnsworthCharRate) WPM",value:$vm.settings.farnsworthCharRate,in:5...80).disabled(vm.settings.contest != .sst)
            }
        }
    }
}

/// Settings MRCE keeps out of its menus (they are lines in its ini file, or
/// a hotkey in the case of the continuous pile-up).
private struct AdvancedSettingsView:View {
    @EnvironmentObject private var vm:FieldViewModel
    var body:some View {
        SettingsPage(title:"Advanced settings") {
            Section("Callers") {
                Picker("Call speed distribution",selection:$vm.settings.gaussianSpeed) {
                    Text("Uniform").tag(false)
                    Text("Gaussian").tag(true)
                }
                .disabled(vm.settings.mode == .hstCompetition || vm.settings.callerSpeedMode != .custom)
                Stepper("Faster 5NN rate \(vm.settings.fast5nnOccurrenceRate)%",value:$vm.settings.fast5nnOccurrenceRate,in:0...100)
                    .disabled(!vm.settings.fast5nn)
                Toggle("Continuous pile-up",isOn:Binding(get:{vm.settings.continuousPileup ?? false},set:{vm.settings.continuousPileup=$0}))
            }
            Section("Session") {
                Stepper("Competition length \(vm.settings.competitionDuration) min",value:$vm.settings.competitionDuration,in:1...60)
                Stepper("Single-call delay \(vm.settings.singleCallStartDelay) ms",value:$vm.settings.singleCallStartDelay,in:0...2500,step:100)
                    .disabled(vm.settings.mode != .single)
            }
            Section("Operator behavior") {
                Stepper(vm.settings.stationIdRate == 0 ? "Station ID: never" : "Station ID every \(vm.settings.stationIdRate) QSOs",value:$vm.settings.stationIdRate,in:0...20)
                    // SST always signs with the call; single calls and HST never do.
                    .disabled(vm.settings.contest == .sst || ![.pileup,.wpxCompetition].contains(vm.settings.mode))
                HStack {
                    Text("NIL message (F8)")
                    TextField("NIL",text:Binding(get:{vm.settings.nilText ?? ""},set:{vm.settings.nilText=String($0.uppercased().filter{$0.isASCII && ($0.isLetter || $0.isNumber || $0 == " " || $0 == "?" || $0 == "/")}.prefix(20))}))
                        .textInputAutocapitalization(.characters).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                }
            }
            Section("Sweepstakes") {
                Stepper("Prefill check and section: \(vm.settings.showCheckSection)%",value:$vm.settings.showCheckSection,in:0...100,step:5).disabled(vm.settings.contest != .sweepstakes)
                Toggle("Show exchange summary",isOn:$vm.settings.showExchangeSummary).disabled(vm.settings.contest != .sweepstakes)
            }
        }
    }
}

private struct CallDatabaseSettingsView:View {
    @EnvironmentObject private var vm:FieldViewModel
    @Binding var showImport:Bool
    @Binding var showSCPImport:Bool
    var body:some View {
        SettingsPage(title:"Callsign data") {
            Section("Display") {
                Toggle("Show callsign information",isOn:$vm.settings.showCallsignInfo)
            }
            Section("Callsign and history data") {
                Text("Import a call list or contest history. Files stay on this device.").font(.footnote)
                    Button("Import callsign / history file",systemImage:"square.and.arrow.down") {showImport=true}.buttonStyle(.bordered)
                    Text(vm.importMessage).font(.footnote).foregroundStyle(FieldTheme.secondary)
                    if vm.legacySSTHistoryNeedsReimport {
                        Label("Saved SST history predates row preservation. Its calls and records remain usable, but duplicate weighting and selected-row associations are unavailable. Reimport the original SST history file to restore them.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(FieldTheme.secondary)
                    }
                    if !vm.settings.customCalls.isEmpty {Text("MASTER/custom calls: \(vm.settings.customCalls.count)").font(.footnote)}
                if let history=vm.settings.contestHistories[vm.settings.contest.rawValue] {Text("\(history.sourceName): \(history.calls.count) calls").font(.footnote)}
            }
            Section("Super Check Partial callers") {
                    Toggle("Allow automatic SCP downloads",isOn:$vm.automaticSCPDownloads)
                    Text(vm.scpImportError ?? vm.scpStatus).font(.footnote)
                    // Most status lines already give the count.
                    if vm.scpCallCount > 0, !(vm.scpImportError ?? vm.scpStatus).contains(vm.scpCallCount.formatted()) {Text("Cached list: \(vm.scpCallCount.formatted()) calls").font(.footnote).foregroundStyle(FieldTheme.secondary)}
                    Button("Import custom MASTER.SCP",systemImage:"doc.badge.arrow.up") {showSCPImport=true}.buttonStyle(.bordered)
                    if vm.scpIsUsingCustomOverride {
                        Button("Use downloaded SCP list",systemImage:"arrow.uturn.backward") {vm.clearCustomSCP()}.buttonStyle(.bordered)
                    }
                Button {vm.refreshSCPData()} label: {if vm.scpIsRefreshing {Label("Downloading latest SCP data…",systemImage:"arrow.clockwise")} else {Label("Download latest SCP data",systemImage:"arrow.down.circle")}}.buttonStyle(.bordered).disabled(vm.scpIsRefreshing)
            }
        }
    }
}

#Preview {
    SetupView()
        .environmentObject(FieldViewModel())
}

#Preview {
    AboutView()
}
