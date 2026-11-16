//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import SwiftUI
import MorseJoggerCore
import UIKit

struct GameView:View {
    @EnvironmentObject private var vm:FieldViewModel
    private var userInterfaceIdiom: UIUserInterfaceIdiom { UIDevice.current.userInterfaceIdiom }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection=0
    @State private var showRadio=false
    @State private var showSession=false
    @StateObject private var entryFocus=EntryFieldFocus()
    private var entryIsFocused:Bool { entryFocus.isFocused }
    private var entryModalPresented:Bool { showSession || showRadio || vm.showResults }
    private var columns:[GridItem] {Array(repeating:GridItem(.flexible(),spacing:7),count:dynamicTypeSize.isAccessibilitySize ? 3 : 4)}
    private var scoreColumns:[GridItem] {Array(repeating:GridItem(.flexible(),spacing:8),count:dynamicTypeSize.isAccessibilitySize ? 2 : 4)}
    private let controls:[Command]=[.cq,.exchange,.tu,.mycall,.hiscall,.b4,.repeatMessage,.nil,.numberAgain,.wipe,.stop]
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:15) {
                    topHeader
                    scoreboard
                    LazyVGrid(columns:columns,spacing:8) {
                        ForEach(controls,id:\.self) { command in commandButton(command) }
                    }
                    entryFields
                    if vm.audioRecoveryAvailable {
                        Button("Retry audio",systemImage:"arrow.clockwise") { vm.retryAudio() }
                            .buttonStyle(.bordered)
                            .accessibilityHint("Retries audio playback and resumes the session")
                    }
                    HStack {
                        Spacer()
                        Text("\(vm.activeSettings.wpm) WPM · \(vm.activeSettings.pitch) HZ · BW \(vm.activeSettings.bandwidth)")
            Button {
                entryFocus.setFocusEnabled(false)
                entryFocus.resign()
                showRadio=true
            } label:{Image(systemName:"gearshape.fill")}
                            .accessibilityLabel("Quick radio settings")
                    }.font(.footnote).foregroundStyle(.secondary)
                    Picker("Session view",selection:$selection) {
                        Text("Activity").tag(0)
                        Text("Log · \(vm.log.count)").tag(1)
                    }.pickerStyle(.segmented)
                    if selection==0 {activityView}else{logView}
                }
                .padding(14)
            }
            .toolbar(.hidden,for:.navigationBar)
            // Handles keys when neither entry field is first responder.
            .background(GameKeyCommandHost(isEnabled:!entryIsFocused,onSaveOnly:{vm.saveEntryOnly()}) { vm.performGameCommand($0) }
                .frame(width:0,height:0))
            .onReceive(NotificationCenter.default.publisher(for:radioKeyNotification)) { note in
                switch note.userInfo?["input"] as? String {
                case UIKeyCommand.inputUpArrow: vm.adjustRIT(direction:1)
                case UIKeyCommand.inputDownArrow: vm.adjustRIT(direction:-1)
                case UIKeyCommand.inputPageUp: vm.stepSpeed(up:true)
                case UIKeyCommand.inputPageDown: vm.stepSpeed(up:false)
                default: break
                }
            }
            .sheet(isPresented:$showRadio,onDismiss:{updateEntryFocusForModalState()}) { RadioSheet() }
            .sheet(isPresented:$showSession,onDismiss:{updateEntryFocusForModalState()}) { SessionSheet() }
            .alert("Audio problem",isPresented:Binding(
                get:{vm.audioAlert != nil},set:{if !$0 {vm.audioAlert=nil}}
            )) {
                if vm.audioRecoveryAvailable {
                    Button("Retry audio") { vm.retryAudio() }
                }
                Button("OK",role:.cancel) { vm.audioAlert=nil }
            } message: {
                Text(vm.audioAlert ?? "Audio is unavailable.")
            }
        }
        .onAppear {
            entryFocus.setFocusEnabled(!entryModalPresented)
            if !entryModalPresented { entryFocus.focus(.callsign) }
        }
        .onChange(of:showSession) { _,showing in
            if showing { updateEntryFocusForModalState() }
        }
        .onChange(of:showRadio) { _,showing in
            if showing { updateEntryFocusForModalState() }
        }
        .onChange(of:vm.showResults) { _,_ in
            updateEntryFocusForModalState()
        }
        .onChange(of:vm.entryAdvanceToken) { _,_ in
            if !entryModalPresented { entryFocus.focus(vm.entryAdvanceTarget) }
        }
        .onChange(of:vm.sweepstakesHintToken) { _,_ in
            vm.applyPendingSweepstakesHint(exchangeFieldIsFocused:entryFocus.focusedRole == .exchangeSecond)
        }
        .onChange(of:entryFocus.focusedRole) { _,role in
            guard role == .exchangeSecond else { return }
            vm.applyPendingSweepstakesHint(exchangeFieldIsFocused:true)
        }
        .onChange(of:scenePhase) {_,phase in
            if phase == .active && !entryModalPresented && !entryIsFocused {entryFocus.focus(.callsign)}
        }
    }
    private func updateEntryFocusForModalState() {
        let shouldEnable = !entryModalPresented && vm.showingGame
        entryFocus.setFocusEnabled(shouldEnable)
        if !shouldEnable {
            entryFocus.resign()
        } else if !entryIsFocused {
            entryFocus.focus(.callsign)
        }
    }
    @ViewBuilder private func commandButton(_ command:Command)->some View {
        let title=commandTitle(command)
        let button=Button {vm.performGameCommand(command)} label: {
            Text(title).font(.callout.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                .frame(maxWidth:.infinity,minHeight:46)
        }
        .buttonStyle(.bordered)
        .tint(command == .stop ? .red : command == .cq ? cqTint : .gray)
        .accessibilityLabel(commandAccessibilityLabel(command))
        .accessibilityHint(command == .tu ? "Long press or use the Save QSO without transmitting accessibility action." : "")
        .accessibilityIdentifier("command.\(command.rawValue)")
        if command == .tu {
            button
                .contextMenu {
                    Button("Save QSO (no transmit)",systemImage:"tray.and.arrow.down") {
                        vm.saveEntryOnly()
                    }
                }
                .accessibilityAction(named:Text("Save QSO without transmitting")) {
                    vm.saveEntryOnly()
                }
        } else {
            button
        }
    }
    private var cqTint: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .light
                ? UIColor(red:0.62,green:0.43,blue:0.00,alpha:1)
                : .systemYellow
        })
    }
    private func commandTitle(_ command:Command)->String {
        switch command {
        case .cq: "F1 CQ"
        case .exchange: "F2 EXCH"
        case .tu: "F3 TU"
        case .mycall: "F4 <my>"
        case .hiscall: "F5 <his>"
        case .b4: "F6 B4"
        case .repeatMessage: "F7 ?"
        case .nil: "F8 NIL"
        case .numberAgain: "F12 NR?"
        case .wipe: "F11 WIPE"
        case .stop: "Esc STOP"
        case .saveOnly: "Save QSO"
        default: command.label
        }
    }
    private func commandAccessibilityLabel(_ command: Command) -> String {
        switch command {
        case .cq: "Transmit CQ"
        case .exchange: "Transmit exchange"
        case .tu: "Transmit TU"
        case .mycall: "Transmit my callsign"
        case .hiscall: "Transmit his callsign"
        case .b4: "Transmit B4"
        case .repeatMessage: "Transmit ?"
        case .nil: "Transmit NIL"
        case .numberAgain: "Transmit NR?"
        case .wipe: "Wipe entry fields"
        case .stop: "Stop transmitting"
        case .saveOnly: "Save QSO without transmitting"
        default: {
            assertionFailure("Missing accessibility label for \(command.label)")
            return ""
        }()
        }

    }
    private var topHeader:some View {
        HStack {
            VStack(alignment:.leading,spacing:3) {
                Text("Morse Jogger").font(.system(.largeTitle, design: .rounded).weight(.bold))
                HStack(spacing:10) {
                    Label(vm.presentation.radioState.title,systemImage:vm.presentation.radioState.symbol)
                        .font(.caption.weight(.semibold)).foregroundStyle(vm.presentation.radioState.color)
                    if vm.currentlyRecording {
                        Label("WAV",systemImage:"record.circle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.red)
                            .accessibilityLabel("Recording WAV audio")
                    }
                }
            }
            Spacer()
            Button {vm.toggleMute()} label:{Image(systemName:vm.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")}
                .accessibilityLabel(vm.muted ? "Unmute" : "Mute")
            Button {
                entryFocus.setFocusEnabled(false)
                entryFocus.resign()
                showSession=true
            } label:{Image(systemName:"ellipsis.circle.fill")}
                .accessibilityLabel("Session controls")
        }.buttonStyle(.bordered)
    }
    private var scoreboard:some View {
        let s=vm.presentation
        return LazyVGrid(columns:scoreColumns,spacing:8) {
            instrument("Time left",timeString(s.remaining))
            instrument("QSOs","\(s.contacts)")
            instrument("Verified","\(s.verified)")
            instrument("Score","\(s.score)")
        }
    }
    private func instrument(_ label:String,_ value:String)->some View {
        VStack(spacing:6) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
                .minimumScaleFactor(0.7).lineLimit(1)
        }.frame(maxWidth:.infinity).padding(.vertical,11)
            .background(Color.primary.opacity(0.07),in:RoundedRectangle(cornerRadius:10))
            .accessibilityElement(children:.combine)
    }
    private func timeString(_ seconds:Double)->String {
        let n=max(0,Int(seconds));return String(format:"%02d:%02d",n/60,n%60)
    }
    private var entryFields:some View {
        VStack(alignment:.leading,spacing:10) {
            let exchangeFields=vm.settings.contest.receivedExchangeFields
            ViewThatFits(in:.horizontal) {
                if !dynamicTypeSize.isAccessibilitySize {
                    HStack(alignment:.top,spacing:8) {
                        callsignEntry.frame(minWidth:150)
                        exchangeEntryRow(exchangeFields).frame(minWidth:210)
                    }
                }
                VStack(alignment:.leading,spacing:8) {
                    callsignEntry
                    exchangeEntryRow(exchangeFields)
                }
            }
            if let code=vm.entryValidation {
                Label(code.safeDisplayText,systemImage:"exclamationmark.circle.fill")
                    .font(.footnote).foregroundStyle(.red)
                    .fixedSize(horizontal:false,vertical:true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if vm.settings.showCorrectAnswers {
                VStack(alignment:.leading,spacing:5) {
                    if vm.callerAnswers.isEmpty {
                        Text("No active callers")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(vm.callerAnswers.enumerated()),id:\.offset) { item in
                            Text("Answer: \(item.element.call) — \(item.element.exchange)")
                                .font(.footnote.monospaced())
                                .lineLimit(1).minimumScaleFactor(0.75)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if let progress=vm.ssProgress,vm.settings.showExchangeSummary {
                Text(progress.summary).font(.footnote).foregroundStyle(.secondary)
                Text("Next: \(progress.next)").font(.footnote).foregroundStyle(.yellow)
            }
            HStack {
                Text("NR \(vm.presentation.serial)").font(.footnote)
                Spacer()
                Text("TX \(vm.sentExchange)").font(.footnote.monospaced()).lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.07),in:RoundedRectangle(cornerRadius:12))
    }
    private var callsignEntry:some View {
        VStack(alignment:.leading,spacing:5) {
            Text("Callsign").font(.footnote)
            AccessoryEntryField(text:vm.callEntryBinding(),placeholder:"_ _ _ _ _",identifier:"entry.callsign",returnLabel:"GO",focus:entryFocus,role:.callsign,contest:vm.settings.contest) {
                vm.submitEntry()
            } onSaveOnly: {vm.saveEntryOnly()} onSpaceAdvance: { vm.applySpaceEntryDefault(after:.callsign) }
                onHardwareCommand: { vm.performGameCommand($0) } onEditingChanged: { entryEditingChanged($0,role:.callsign) }
                .frame(minHeight:44)
        }
        .frame(maxWidth:.infinity,alignment:.leading)
    }
    @ViewBuilder private func exchangeEntryRow(_ fields:(first:String?,second:String,secondAllowsSpaces:Bool))->some View {
        HStack(alignment:.top,spacing:8) {
            if let firstLabel=fields.first {
                exchangeEntry(label:firstLabel,placeholder:vm.settings.contest.definition.usesRST ? "599" : "",identifier:"entry.exchange.first",role:.exchangeFirst,text:vm.exchangeEntryBinding(.exchangeFirst),contest:vm.settings.contest)
            }
            exchangeEntry(label:vm.naqpCallerIsDX ? "State (blank or DX)" : fields.second,placeholder:"",identifier:"entry.exchange.second",role:.exchangeSecond,text:vm.exchangeEntryBinding(.exchangeSecond),contest:vm.settings.contest)
        }
    }
    private func exchangeEntry(label:String,placeholder:String,identifier:String,role:EntryFieldFocus.Role,text:Binding<String>,contest:ContestID)->some View {
        VStack(alignment:.leading,spacing:5) {
            Text(label).font(.footnote).lineLimit(1).minimumScaleFactor(0.75)
            AccessoryEntryField(text:text,placeholder:placeholder,identifier:identifier,returnLabel:"Enter",focus:entryFocus,role:role,contest:contest) {
                vm.submitEntry()
            } onSaveOnly: {vm.saveEntryOnly()} onSpaceAdvance: { vm.applySpaceEntryDefault(after:role) }
                onHardwareCommand: { vm.performGameCommand($0) } onEditingChanged: { entryEditingChanged($0,role:role) }
                .frame(minHeight:44)
        }
        .frame(maxWidth:.infinity)
    }
    private var activityView:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("\(vm.presentation.rate) QSOs/HR")
                    .font(.title3.monospacedDigit().weight(.semibold))
                Spacer()
                Text(vm.presentation.phase)
                    .font(.footnote).foregroundStyle(.yellow)
            }
            if vm.activity.isEmpty {Text("Call CQ to start.").foregroundStyle(.secondary)}
            ForEach(vm.activity.prefix(30)) { entry in
                HStack(alignment:.firstTextBaseline,spacing:12) {
                    Text(entry.channel)
                        .foregroundStyle(entry.tone == .transmit ? .yellow : entry.tone == .receive ? .green : .gray)
                        .font(.caption.weight(.semibold))
                    Text(entry.text).font(.footnote.monospaced()).frame(maxWidth:.infinity,alignment:.leading)
                }.padding(.vertical,4)
            }
            if vm.settings.showCallsignInfo {
                if let info=vm.callsignInformation {
                    Text(info.contestHistory == nil && info.geography == nil
                         ? "CALL INFO: \(info.call)"
                         : "CALL INFO: \(info.call) · \(info.displayText)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:12))
    }
    private var logView:some View {
        QSOLogView(entries:vm.log)
    }
    private func entryEditingChanged(_ isEditing:Bool,role:EntryFieldFocus.Role) {
        entryFocus.setFocused(isEditing,role:role)
    }
}

private struct AccessoryEntryField:UIViewRepresentable {
    @Binding var text:String
    let placeholder:String
    let identifier:String
    let returnLabel:String
    let focus:EntryFieldFocus
    let role:EntryFieldFocus.Role
    let contest:ContestID
    let onSubmit:()->Bool
    let onSaveOnly:()->Void
    let onSpaceAdvance:()->Void
    let onHardwareCommand:(Command)->Void
    let onEditingChanged:(Bool)->Void

    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeUIView(context:Context)->UITextField {
        let field=CommandEntryTextField()
        // Keep the border and keyboard focus treatment owned by UIKit. In
        // Mac Catalyst the system focus ring is drawn around the control, so
        // a separately rounded/clipped CALayer border can make the visible
        // field shape disagree with that ring.
        field.borderStyle = .roundedRect
        field.backgroundColor = .secondarySystemBackground
        field.font = UIFontMetrics(forTextStyle:.body).scaledFont(for:.monospacedSystemFont(ofSize:17,weight:.regular))
        field.adjustsFontForContentSizeCategory = true
        field.placeholder=placeholder
        field.autocapitalizationType = .allCharacters
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.keyboardType = .asciiCapable
        field.returnKeyType = returnLabel == "GO" ? .go : .send
        field.accessibilityIdentifier=identifier
        field.tag=role.rawValue
        field.delegate=context.coordinator
        field.entryRole=role
        field.entryContest=contest
        field.entryFocus=focus
        field.onSpaceAdvance=onSpaceAdvance
        field.onHardwareCommand=onHardwareCommand
        field.onSaveOnly=onSaveOnly
        focus.register(field,role:role)
        _=context.coordinator.makeAccessory(for:field)
        field.addTarget(context.coordinator,action:#selector(Coordinator.changed(_:)),for:.editingChanged)
        return field
    }
    func updateUIView(_ field:UITextField,context:Context) {
        context.coordinator.parent=self
        (field as? CommandEntryTextField)?.onHardwareCommand=onHardwareCommand
        (field as? CommandEntryTextField)?.onSaveOnly=onSaveOnly
        (field as? CommandEntryTextField)?.entryContest=contest
        (field as? CommandEntryTextField)?.onSpaceAdvance=onSpaceAdvance
        focus.register(field,role:role)
        // SwiftUI refreshes this representable as the session timer publishes
        // snapshots. Replacing UITextField.text resets its insertion point,
        // including when normalization has just changed the bound value.
        // Only synchronize an actual value change, and restore the selection
        // by character offsets so edits in the middle stay in place.
        if field.text != text {
            let selection=field.selectedTextRange.map { range in
                (field.offset(from:field.beginningOfDocument,to:range.start),
                 field.offset(from:field.beginningOfDocument,to:range.end))
            }
            field.text=text
            if let (start,end)=selection,
               let startPosition=field.position(from:field.beginningOfDocument,offset:min(start,(text as NSString).length)),
               let endPosition=field.position(from:field.beginningOfDocument,offset:min(end,(text as NSString).length)) {
                field.selectedTextRange=field.textRange(from:startPosition,to:endPosition)
            }
        }
        if field.placeholder != placeholder {field.placeholder=placeholder}
    }
    final class Coordinator:NSObject,UITextFieldDelegate {
        var parent:AccessoryEntryField
        private weak var field:UITextField?
        private var accessoryView:UIView?
        private var accessoryHeightConstraint:NSLayoutConstraint?
        private var softwareKeyboardVisible=false
        private var keyboardObservers:[NSObjectProtocol]=[]
        init(_ parent:AccessoryEntryField) {
            self.parent=parent
            super.init()
            let center=NotificationCenter.default
            keyboardObservers.append(center.addObserver(forName:UIResponder.keyboardWillChangeFrameNotification,object:nil,queue:.main) { [weak self] notification in
                guard let self,
                      let field=self.field,
                      let window=field.window,
                      let frame=(notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else{return}
                let keyboardFrame=window.screen.coordinateSpace.convert(frame,to:window)
                let coveredHeight=window.bounds.intersection(keyboardFrame).height
                // Hardware keyboards can still produce a short shortcut bar.
                // A rotation can also report a temporary off-screen frame;
                // only a positive frame is allowed to show the row. Hide it
                // after keyboardDidHide confirms dismissal below.
                if coveredHeight > 100 {
                    self.setSoftwareKeyboardVisible(true)
                } else {
                    self.attachAccessoryIfNeeded(reloadInputViews: false)
                }
            })
            // The iPad keyboard's down control can finish dismissing the
            // keyboard without a useful final frame change. Reapply the
            // collapsed accessory state after UIKit completes that dismissal.
            keyboardObservers.append(center.addObserver(forName:UIResponder.keyboardDidHideNotification,object:nil,queue:.main) { [weak self] _ in
                self?.collapseAccessoryAfterKeyboardDismissal()
            })
            keyboardObservers.append(center.addObserver(forName:UIContentSizeCategory.didChangeNotification,object:nil,queue:.main) { [weak self] _ in
                self?.refreshAccessoryHeightForContentSizeChange()
            })
        }
        deinit { keyboardObservers.forEach(NotificationCenter.default.removeObserver) }
        private func setSoftwareKeyboardVisible(_ visible:Bool) {
            if visible { attachAccessoryIfNeeded(reloadInputViews:true) }
            guard softwareKeyboardVisible != visible else{return}
            softwareKeyboardVisible=visible
            accessoryView?.isHidden = !visible
            accessoryHeightConstraint?.constant = visible ? accessoryHeight : 0
        }
        private func collapseAccessoryAfterKeyboardDismissal() {
            softwareKeyboardVisible=false
            accessoryView?.isHidden=true
            accessoryHeightConstraint?.constant=0
            accessoryView?.invalidateIntrinsicContentSize()
            accessoryView?.setNeedsLayout()
            accessoryView?.layoutIfNeeded()
            // UIInputView can retain the height it measured while the
            // keyboard was visible. Detach and reload after dismissal so its
            // host drops that measurement; the next software-keyboard show
            // installs the same view again with the collapsed height ready.
            guard let field, field.isFirstResponder else{return}
            field.inputAccessoryView=nil
            field.reloadInputViews()
        }
        private func refreshAccessoryHeightForContentSizeChange() {
            guard field?.traitCollection.userInterfaceIdiom == .pad,
                  softwareKeyboardVisible,
                  let accessoryView,
                  let accessoryHeightConstraint else { return }
            accessoryHeightConstraint.constant = accessoryHeight
            accessoryView.invalidateIntrinsicContentSize()
            accessoryView.setNeedsLayout()
            if let field, field.isFirstResponder {
                field.reloadInputViews()
            }
        }
        private func attachAccessoryIfNeeded(reloadInputViews:Bool) {
            guard let field, let accessoryView,
                  field.inputAccessoryView !== accessoryView else{return}
            field.inputAccessoryView=accessoryView
            if reloadInputViews && field.isFirstResponder {
                field.reloadInputViews()
            }
        }
        @objc func changed(_ sender:UITextField) {
            parent.text=sender.text ?? ""
            // The model filters what was typed. When the filtered value equals
            // the old one nothing is published, so put it back here.
            let stored=parent.text
            if sender.text != stored { sender.text=stored }
        }
        func textFieldShouldReturn(_ textField:UITextField)->Bool {
            let completedQSO=parent.onSubmit()
            // After an Enter that did not log, MRCE leaves the cursor where it
            // is until his call has been keyed (so the call can still be
            // corrected); the model then announces the move.
            if completedQSO { parent.focus.focus(.callsign) }
            return false // Keep the iPhone keyboard open for the next exchange.
        }
        func textField(_ textField:UITextField,shouldChangeCharactersIn range:NSRange,replacementString string:String)->Bool {
            if string == " ", let next=ContestRules.nextSpaceEntryField(after:parent.role,contest:parent.contest) {
                parent.onSpaceAdvance()
                parent.focus.focus(next)
                return false
            }
            return true
        }
        func textFieldDidBeginEditing(_ textField:UITextField) {
            guard parent.focus.isFocusEnabled else {
                textField.resignFirstResponder()
                return
            }
            // Focus can return through the app's field navigation after the
            // iPad keyboard was dismissed, so restore the accessory before
            // UIKit builds the next input session.
            attachAccessoryIfNeeded(reloadInputViews:false)
            deliverEditingChange(true)
        }
        func textFieldDidEndEditing(_ textField:UITextField) {
            deliverEditingChange(false)
        }
        private func deliverEditingChange(_ editing:Bool) {
            // UIKit can invoke delegate methods during a SwiftUI representable
            // update. Publish the focus change after that update transaction.
            DispatchQueue.main.async { [weak self] in self?.parent.onEditingChanged(editing) }
        }
        func makeAccessory(for field:UITextField)->UIView {
            self.field=field
            let bar=UIStackView()
            bar.axis = .horizontal
            bar.distribution = .fillEqually
            bar.spacing=5
            bar.isLayoutMarginsRelativeArrangement=true
            bar.directionalLayoutMargins=NSDirectionalEdgeInsets(top:5,leading:8,bottom:5,trailing:8)
            // SwiftUI Previews adds a bunch of stuff to this list and it won't compile all in one expression.
            //let keyboardButtons = ["1","2","3","4","5","6","7","8","9","0","/","?"]
            var keyboardButtons = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
            keyboardButtons.append(contentsOf: ["/", "?"])
            let isPad = field.traitCollection.userInterfaceIdiom == .pad
            let labelFont = isPad
                ? UIFontMetrics(forTextStyle: .body).scaledFont(
                    for: .systemFont(ofSize: 18, weight: .semibold),
                    compatibleWith: field.traitCollection
                )
                : UIFontMetrics(forTextStyle: .footnote).scaledFont(
                    for: .systemFont(ofSize: 14, weight: .semibold)
                )
            for key in keyboardButtons {
                let button=UIButton(type:.system)
                button.setTitle(key,for:.normal)
                button.titleLabel?.font = labelFont
                button.titleLabel?.adjustsFontForContentSizeCategory = isPad
                button.accessibilityLabel="Insert \(key)"
                button.backgroundColor = .secondarySystemBackground
                button.layer.cornerRadius=6
                button.addAction(UIAction { [weak field] _ in
                    guard let field else{return}
                    field.insertText(key)
                },for:.touchUpInside)
                bar.addArrangedSubview(button)
            }
            let initialHeight = accessoryHeight
            let container=UIInputView(frame:CGRect(x:0,y:0,width:0,height:initialHeight),inputViewStyle:.keyboard)
            container.allowsSelfSizing=true
            container.backgroundColor = .systemBackground
            container.isOpaque=true
            bar.translatesAutoresizingMaskIntoConstraints=false
            container.addSubview(bar)
            let heightConstraint=container.heightAnchor.constraint(equalToConstant:softwareKeyboardVisible ? initialHeight : 0)
            accessoryHeightConstraint=heightConstraint
            NSLayoutConstraint.activate([
                heightConstraint,
                bar.leadingAnchor.constraint(equalTo:container.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo:container.trailingAnchor),
                bar.topAnchor.constraint(equalTo:container.topAnchor),
                bar.bottomAnchor.constraint(equalTo:container.bottomAnchor)
            ])
            accessoryView=container
            // Install before first responder so UIKit carries the row up with
            // the software keyboard. Keep it attached for hardware keyboards,
            // but collapse its self-sizing height to zero. Reloading input
            // views during keyboard animation shifts the row independently.
            container.isHidden = !softwareKeyboardVisible
            field.inputAccessoryView=container
            return container
        }
        private var accessoryHeight: CGFloat {
            guard let field else { return 48 }
            guard field.traitCollection.userInterfaceIdiom == .pad else { return 48 }
            let font = UIFontMetrics(forTextStyle: .body).scaledFont(
                for: .systemFont(ofSize: 18, weight: .semibold),
                compatibleWith: field.traitCollection
            )
            // Keep at least a 44-point touch target after the bar's 10 points
            // of vertical margins; larger Dynamic Type sizes grow the row.
            return max(54, ceil(font.lineHeight) + 10)
        }
    }
}

/// The text field remains the nearest responder while editing. All key
/// commands use one Objective-C-visible action selector and UIKit's named
/// function-key inputs, which Catalyst can also expose as menu commands.
private final class CommandEntryTextField:UITextField {
    var onHardwareCommand:((Command)->Void)?
    var onSaveOnly:(()->Void)?
    var onSpaceAdvance:(()->Void)?
    var entryRole:EntryFieldFocus.Role = .callsign
    var entryContest:ContestID = .wpx
    weak var entryFocus:EntryFieldFocus?
    override var keyCommands:[UIKeyCommand]? {
        makeHardwareKeyCommands(action:#selector(handleHardwareCommand(_:))) +
            makeSaveOnlyKeyCommands(action:#selector(handleSaveOnlyShortcut)) +
            makeEntryNavigationKeyCommands(action:#selector(handleHardwareCommand(_:)),role:entryRole,contest:entryContest) +
            makeExtraKeyCommands(action:#selector(handleHardwareCommand(_:)),radioAction:#selector(handleRadioKey(_:)))
    }
    @objc func handleRadioKey(_ keyCommand:UIKeyCommand) {postRadioKey(keyCommand)}
    @objc func handleHardwareCommand(_ keyCommand:UIKeyCommand) {
        if keyCommand.input == " " {
            if let next=ContestRules.nextSpaceEntryField(after:entryRole,contest:entryContest) {
                onSpaceAdvance?()
                entryFocus?.focus(next)
            }
            return
        }
        if keyCommand.input == "\t" {
            entryFocus?.advance(from:entryRole,contest:entryContest,backwards:keyCommand.modifierFlags.contains(.shift))
            return
        }
        if let command=hardwareCommand(for:keyCommand.input) ?? extraCommand(for:keyCommand.input) {onHardwareCommand?(command)}
    }
    @objc func handleSaveOnlyShortcut() {onSaveOnly?()}
}

/// MRCE advances through exchange controls on Space, except in Sweepstakes'
/// final control where spaces separate copied exchange components.
private func makeEntryNavigationKeyCommands(action:Selector,role:EntryFieldFocus.Role,contest:ContestID)->[UIKeyCommand] {
    var commands=[
        UIKeyCommand(title:"Next entry field",image:nil,action:action,input:"\t",modifierFlags:[],propertyList:nil),
        UIKeyCommand(title:"Previous entry field",image:nil,action:action,input:"\t",modifierFlags:.shift,propertyList:nil)
    ]
    if ContestRules.spaceAdvancesEntryField(contest:contest,field:role) {
        commands.append(UIKeyCommand(title:"Advance to exchange",image:nil,action:action,input:" ",modifierFlags:[],propertyList:nil))
    }
    commands.forEach {$0.wantsPriorityOverSystemBehavior=true}
    return commands
}

/// Keeps hardware shortcuts active outside the entry fields. It becomes first
/// responder only while neither text field is editing and never accepts text.
private struct GameKeyCommandHost:UIViewControllerRepresentable {
    let isEnabled:Bool
    let onSaveOnly:()->Void
    let onCommand:(Command)->Void
    func makeUIViewController(context:Context)->Controller {
        let controller=Controller()
        controller.onCommand=onCommand
        controller.onSaveOnly=onSaveOnly
        controller.isEnabled=isEnabled
        return controller
    }
    func updateUIViewController(_ controller:Controller,context:Context) {
        controller.onCommand=onCommand
        controller.onSaveOnly=onSaveOnly
        controller.isEnabled=isEnabled
        controller.updateFirstResponderState()
    }
    final class Controller:UIViewController {
        var onCommand:((Command)->Void)?
        var onSaveOnly:(()->Void)?
        var isEnabled=false
        override var canBecomeFirstResponder:Bool {true}
        override func loadView() {
            let view=UIView(frame:.zero)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled=false
            self.view=view
        }
        override func viewDidAppear(_ animated:Bool) {
            super.viewDidAppear(animated)
            updateFirstResponderState()
        }
        override var keyCommands:[UIKeyCommand]? {
            isEnabled ? makeHardwareKeyCommands(action:#selector(handleHardwareCommand(_:))) + makeSaveOnlyKeyCommands(action:#selector(handleSaveOnlyShortcut)) +
                makeExtraKeyCommands(action:#selector(handleHardwareCommand(_:)),radioAction:#selector(handleRadioKey(_:))) : []
        }
        func updateFirstResponderState() {
            guard isViewLoaded, view.window != nil else{return}
            if isEnabled {
                if !isFirstResponder {becomeFirstResponder()}
            } else if isFirstResponder {
                resignFirstResponder()
            }
        }
        @objc func handleHardwareCommand(_ keyCommand:UIKeyCommand) {
            if let command=hardwareCommand(for:keyCommand.input) ?? extraCommand(for:keyCommand.input) {onCommand?(command)}
        }
        @objc func handleRadioKey(_ keyCommand:UIKeyCommand) {postRadioKey(keyCommand)}
        @objc func handleSaveOnlyShortcut() {onSaveOnly?()}
    }
}

private func hardwareKeyDefinitions()->[(String,String,Command)] {
    [
        (UIKeyCommand.f1,"F1 CQ",.cq),
        (UIKeyCommand.f2,"F2 Exchange",.exchange),
        (UIKeyCommand.f3,"F3 TU",.tu),
        (UIKeyCommand.f4,"F4 My callsign",.mycall),
        (UIKeyCommand.f5,"F5 His callsign",.hiscall),
        (UIKeyCommand.f6,"F6 B4",.b4),
        (UIKeyCommand.f7,"F7 Repeat",.repeatMessage),
        (UIKeyCommand.f8,"F8 NIL",.nil),
        (UIKeyCommand.f11,"F11 Wipe",.wipe),
        (UIKeyCommand.f12,"F12 Number again",.numberAgain),
        (UIKeyCommand.inputEscape,"Escape Stop",.stop)
    ]
}

private func makeHardwareKeyCommands(action:Selector)->[UIKeyCommand] {
    hardwareKeyDefinitions().map { definition in
        let keyCommand=UIKeyCommand(
            title:definition.1,
            image:nil,
            action:action,
            input:definition.0,
            modifierFlags:[],
            propertyList:nil,
            alternates:[],
            discoverabilityTitle:definition.1,
            attributes:[],
            state:.off
        )
        keyCommand.wantsPriorityOverSystemBehavior=true
        return keyCommand
    }
}

/// MRCE's other keyboard shortcuts: `;` sends his call and the exchange,
/// `.` `+` `[` `,` send TU and log, the up and down arrows move the RIT and
/// Page Up / Page Down change speed.
private let radioKeyNotification=Notification.Name("MorseJogger.radioKey")
private func extraCommand(for input:String?)->Command? {
    switch input {
    case ";": .call
    case ".","+","[",",": .log
    default: nil
    }
}
private func makeExtraKeyCommands(action:Selector,radioAction:Selector)->[UIKeyCommand] {
    var commands:[UIKeyCommand]=[]
    for input in [";",".","[",","] {
        commands.append(UIKeyCommand(title:input == ";" ? "His call and exchange" : "TU and log",image:nil,action:action,input:input,modifierFlags:[],propertyList:nil))
    }
    for flags in [UIKeyModifierFlags(),.shift] {
        commands.append(UIKeyCommand(title:"TU and log",image:nil,action:action,input:"+",modifierFlags:flags,propertyList:nil))
    }
    for (input,title) in [(UIKeyCommand.inputUpArrow,"RIT up"),(UIKeyCommand.inputDownArrow,"RIT down"),
                          (UIKeyCommand.inputPageUp,"Faster"),(UIKeyCommand.inputPageDown,"Slower")] {
        commands.append(UIKeyCommand(title:title,image:nil,action:radioAction,input:input,modifierFlags:[],propertyList:nil))
    }
    commands.forEach {$0.wantsPriorityOverSystemBehavior=true}
    return commands
}
private func postRadioKey(_ keyCommand:UIKeyCommand) {
    NotificationCenter.default.post(name:radioKeyNotification,object:nil,userInfo:["input":keyCommand.input ?? ""])
}

private func makeSaveOnlyKeyCommands(action:Selector)->[UIKeyCommand] {
    [UIKeyModifierFlags.shift,.control,.alternate].map { modifiers in
        let keyCommand=UIKeyCommand(
            title:"Save QSO",
            image:nil,
            action:action,
            input:"\r",
            modifierFlags:modifiers,
            propertyList:nil
        )
        keyCommand.wantsPriorityOverSystemBehavior=true
        return keyCommand
    }
}

private func hardwareCommand(for input:String?)->Command? {
    hardwareKeyDefinitions().first(where:{$0.0 == input})?.2
}

@MainActor
private final class EntryFieldFocus:ObservableObject {
    typealias Role=QSOEntryField
    @Published private(set) var isFocused=false
    @Published private(set) var focusedRole:Role?
    private weak var callsignField:UITextField?
    private weak var exchangeFirstField:UITextField?
    private weak var exchangeSecondField:UITextField?
    private var focusEnabled=true
    private var focusGeneration:UInt64=0
    func register(_ field:UITextField,role:Role) {
        switch role {
        case .callsign:callsignField=field
        case .exchangeFirst:exchangeFirstField=field
        case .exchangeSecond:exchangeSecondField=field
        }
    }
    func focus(_ role:Role) {
        guard focusEnabled else { return }
        let generation=focusGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusEnabled, self.focusGeneration == generation else{return}
            let field:UITextField?
            switch role {
            case .callsign:field=self.callsignField
            case .exchangeFirst:field=self.exchangeFirstField
            case .exchangeSecond:field=self.exchangeSecondField
            }
            field?.becomeFirstResponder()
            // MRCE's Edit*Enter handlers: select the `?` in a call, the
            // middle digit of a report, or the whole of another exchange box,
            // so the next key replaces it.
            if let field,
               let range=ContestRules.entrySelectionOnFocus(role,text:field.text ?? "",contest:(field as? CommandEntryTextField)?.entryContest ?? .wpx),
               let start=field.position(from:field.beginningOfDocument,offset:range.lowerBound),
               let end=field.position(from:field.beginningOfDocument,offset:range.upperBound) {
                field.selectedTextRange=field.textRange(from:start,to:end)
            }
        }
    }
    func setFocusEnabled(_ enabled:Bool) {
        focusEnabled=enabled
        focusGeneration &+= 1
        if !enabled { resign() }
    }
    var isFocusEnabled:Bool { focusEnabled }
    func resign() {
        focusGeneration &+= 1
        callsignField?.resignFirstResponder()
        exchangeFirstField?.resignFirstResponder()
        exchangeSecondField?.resignFirstResponder()
    }
    func advance(from role:Role,contest:ContestID,backwards:Bool=false) {
        focus(ContestRules.nextEntryField(after:role,contest:contest,backwards:backwards))
    }
    func setFocused(_ value:Bool,role:Role) {
        if value { focusedRole=role }
        else if focusedRole == role { focusedRole=nil }
        if isFocused != value { isFocused=value }
    }
}

private struct RadioSheet:View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vm:FieldViewModel
    var body:some View {
        NavigationStack {
            Form {
                Section("Receiver") {
                    Stepper("CW speed \(vm.activeSettings.wpm) WPM",value:$vm.settings.wpm,in:SettingsStore.cwSpeedRange)
                    Stepper("Pitch \(vm.settings.pitch) Hz",value:$vm.settings.pitch,in:300...900,step:50)
                    ritControls
                    Stepper("Bandwidth \(vm.activeSettings.bandwidth) Hz",value:$vm.settings.bandwidth,in:100...600,step:50)
                        .disabled(vm.settings.mode == .hstCompetition)
                    Stepper("Monitor \(min(0,max(-60,vm.settings.monitor))) dB",value:Binding(
                        get:{min(0,max(-60,vm.settings.monitor))},
                        set:{vm.settings.monitor=$0}
                    ),in:(-60)...0)
                    Stepper("Receive volume \(Int((min(1,max(0,vm.settings.volume))*100).rounded())) %",value:Binding(
                        get:{Int((min(1,max(0,vm.settings.volume))*100).rounded())},
                        set:{vm.settings.volume=Double($0)/100}
                    ),in:0...100,step:5)
                    Toggle("Full break-in (QSK)",isOn:$vm.settings.qsk)
                }
                Section("Band conditions") {
                    Stepper("Band activity \(vm.activeSettings.activity == ContestSettings().activity ? "(default) " : "")\(vm.activeSettings.activity) / 9",
                            value:$vm.settings.activity,in:1...9)
                        .disabled(vm.settings.mode == .hstCompetition || vm.settings.mode == .single)
                        .accessibilityIdentifier("radio.activity")
                    Text("About half this many stations answer each CQ.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("QRN (atmospheric noise)",isOn:effectBinding(\.qrn))
                        .disabled(vm.settings.mode == .wpxCompetition || vm.settings.mode == .hstCompetition)
                    Toggle("QRM (interference)",isOn:effectBinding(\.qrm))
                        .disabled(vm.settings.mode == .wpxCompetition || vm.settings.mode == .hstCompetition)
                    Toggle("QSB (fading)",isOn:effectBinding(\.qsb))
                        .disabled(vm.settings.mode == .wpxCompetition || vm.settings.mode == .hstCompetition)
                    Toggle("Flutter",isOn:effectBinding(\.flutter))
                        .disabled(vm.settings.mode == .wpxCompetition || vm.settings.mode == .hstCompetition)
                    Toggle("LIDs (copying errors)",isOn:effectBinding(\.lids))
                        .disabled(vm.settings.mode == .wpxCompetition || vm.settings.mode == .hstCompetition)
                }
                if vm.settings.mode == .wpxCompetition || vm.settings.mode == .hstCompetition {
                    Text(vm.settings.mode == .hstCompetition ? "HST competition fixes activity, bandwidth, QRN, QRM, QSB, flutter and LIDs." : "WPX competition fixes QRN, QRM, QSB, flutter and LIDs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Radio settings")
            .toolbar {ToolbarItem(placement:.confirmationAction) {Button("Done") {dismiss()}}}
        }
    }
    private var ritControls: some View {
        let step = RadioTuning.ritStep
        let value = vm.settings.rit
        let signedValue = value >= 0 ? "+\(value)" : "\(value)"
        let sliderValue = Binding<Double>(
            get:{Double(vm.settings.rit)},
            set:{vm.updateRadio(rit:Int($0.rounded()))}
        )

        return VStack(alignment:.leading,spacing:8) {
            ViewThatFits(in:.horizontal) {
                HStack(alignment:.firstTextBaseline) {
                    Text("Receive tuning")
                    Spacer(minLength:8)
                    ritReadout(signedValue)
                    ritReset(value:value)
                }
                VStack(alignment:.leading,spacing:4) {
                    Text("Receive tuning")
                    HStack(alignment:.firstTextBaseline) {
                        ritReadout(signedValue)
                        Spacer(minLength:8)
                        ritReset(value:value)
                    }
                }
            }

            ZStack {
                Slider(value:sliderValue,in:-500...500,step:Double(step))
                    .accessibilityLabel("Receive tuning")
                    .accessibilityValue("\(signedValue) hertz")
                    .accessibilityHint("Moves the receiver filter in \(step) hertz steps")
                Rectangle()
                    .fill(.secondary.opacity(0.75))
                    .frame(width:1,height:10)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            HStack {
                Text("−500 Hz")
                Spacer()
                Text("0")
                Spacer()
                Text("+500 Hz")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

            HStack(spacing:10) {
                ritAdjustmentButton(direction:-1,value:value,step:step)
                ritAdjustmentButton(direction:1,value:value,step:step)
            }

            Text("Adjust receive tuning to bring a station's tone into the filter.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    private func ritReadout(_ signedValue:String) -> some View {
        Text("RIT \(signedValue) Hz")
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .accessibilityLabel("Receive tuning")
            .accessibilityValue("\(signedValue) hertz")
    }
    private func ritReset(value:Int) -> some View {
        Button("Reset") { vm.resetRIT() }
            .buttonStyle(.bordered)
            .font(.callout.weight(.semibold))
            .tint(.gray)
            .disabled(value == 0)
            .accessibilityHint("Resets receive tuning to zero hertz")
    }
    private func ritAdjustmentButton(direction:Int,value:Int,step:Int) -> some View {
        Button { vm.adjustRIT(direction:direction) } label: {
            Image(systemName:direction < 0 ? "minus" : "plus")
                .frame(maxWidth:.infinity,minHeight:40)
        }
        .buttonStyle(.bordered)
        .font(.callout.weight(.semibold))
        .tint(.gray)
        .disabled(direction < 0 ? value <= -500 : value >= 500)
        .accessibilityLabel(direction < 0 ? "Decrease receive tuning" : "Increase receive tuning")
        .accessibilityHint("\(direction < 0 ? "Decreases" : "Increases") receive tuning by \(step) hertz")
    }
    private func effectBinding(_ keyPath: WritableKeyPath<Effects, Bool>) -> Binding<Bool> {
        Binding(get: { vm.activeSettings.effects[keyPath: keyPath] }, set: { value in
            vm.settings.effects[keyPath: keyPath] = value
        })
    }
}
private struct SessionSheet:View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vm:FieldViewModel
    var body:some View {
        NavigationStack {
            List {
                Section("Audio") {
                    Button(vm.currentlyRecording ? "Stop WAV recording" : "Start WAV recording",systemImage:"record.circle") {
                        if vm.currentlyRecording {vm.stopRecording()}else{vm.startRecording()}
                    }
                    if let url=vm.recordedFile, !vm.currentlyRecording {
                        ShareLink(item:url) {Label("Share WAV recording",systemImage:"square.and.arrow.up")}
                    }
                    Button(vm.muted ? "Unmute" : "Mute",systemImage:vm.muted ? "speaker" : "speaker.slash") {vm.toggleMute()}
                }
                Section("Session") {
                    Button("Export QSO log",systemImage:"tablecells") {vm.exportCSV()}
                    if let url=vm.exportedLog {ShareLink(item:url) {Label("Share CSV log",systemImage:"square.and.arrow.up")}}
                    Button("Stop session",systemImage:"stop.circle",role:.destructive) {dismiss();vm.stop()}
                }
            }
            .navigationTitle("Session controls")
            .toolbar {ToolbarItem(placement:.confirmationAction) {Button("Done"){dismiss()}}}
            .alert("Session control error",isPresented:Binding(
                get:{vm.sessionControlsAlert != nil},set:{if !$0 {vm.sessionControlsAlert=nil}}
            )) {
                if vm.audioRecoveryAvailable {
                    Button("Retry audio") { vm.retryAudio() }
                }
                Button("OK",role:.cancel) { vm.sessionControlsAlert=nil }
            } message: {
                Text(vm.sessionControlsAlert ?? "The requested action could not be completed.")
            }
        }
        .onAppear {vm.setSessionControlsPresented(true)}
        .onDisappear {vm.setSessionControlsPresented(false)}
    }
}
struct ResultsSheet:View {
    @EnvironmentObject private var vm:FieldViewModel
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .title2) private var resultValueHeight: CGFloat = 28
    private var userInterfaceIdiom: UIUserInterfaceIdiom { UIDevice.current.userInterfaceIdiom }
    let onDone:() -> Void
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    Text("73, good operating.").font(.largeTitle.weight(.bold))
                    scoreSummary
                    HStack {
                        Text("Session log")
                        .font(.headline.weight(.semibold))
                        Spacer()
                        Text("\(vm.log.count) QSOs")
                        .font(.headline.weight(.semibold))
                    }
                    .padding(.top, 8)
                    QSOLogView(entries:vm.log)
                    Button("Export session CSV",systemImage:"square.and.arrow.up") {vm.exportCSV()}
                        .buttonStyle(.bordered)
                    if let csv=vm.exportedLog {ShareLink(item:csv) {Label("Share CSV",systemImage:"square.and.arrow.up")}}
                    if let wav=vm.recordedFile {ShareLink(item:wav) {Label("Share WAV",systemImage:"waveform")}}
                }
                .padding(20)
                .frame(maxWidth:userInterfaceIdiom == .pad ? 900 : .infinity,alignment:.leading)
                .frame(maxWidth:.infinity)
            }
            .navigationTitle("Results")
            .toolbar {
                ToolbarItem(placement:.topBarTrailing) { Button("Done") { onDone(); dismiss() } }
            }
        }
    }
    private var scoreSummary: some View {
        let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 6), count: 4)
        return LazyVGrid(columns: columns, spacing: 8) {
            resultInstrument("QSOs", value: vm.presentation.contacts.formatted())
            resultInstrument("Verified", value: vm.presentation.verified.formatted())
            resultInstrument("Mults", value: vm.presentation.multipliers.formatted(), accessibilityLabel: "Multipliers")
            resultInstrument("Score", value: vm.presentation.score.formatted(), prominent: true)
        }
        .accessibilityElement(children: .contain)
    }
    private func resultInstrument(_ label: String, value: String, prominent: Bool = false, accessibilityLabel: String? = nil) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font((prominent ? Font.title2 : Font.title3).monospacedDigit().weight(.semibold))
                .foregroundStyle(prominent ? Color.accentColor : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .contentTransition(.numericText())
                .frame(height: resultValueHeight)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(accessibilityLabel ?? label): \(value)")
    }
}

/// Post-QSO only: exposes expected values after a QSO has been logged.
/// Mirrors the original MRCE's NIL / DUP / RST / NR diagnostics, while
/// showing the actual answer for contests with multi-field exchanges.
private struct QSOLogView:View {
    @EnvironmentObject private var vm:FieldViewModel
    let entries:[QSOEntry]
    var body:some View {
        LazyVStack(alignment:.leading,spacing:10) {
            if entries.isEmpty {
                Text("No contacts logged yet.").foregroundStyle(.secondary)
            }
            ForEach(entries) { qso in
                let pending=qso.status == .pendingTUConfirmation
                VStack(alignment:.leading,spacing:4) {
                    HStack(spacing:8) {
                        Image(systemName:pending ? "hourglass" : qso.correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(pending ? .yellow : qso.correct ? .green : .red)
                        Text(pending ? qso.copiedCall : qso.call).font(.subheadline.monospaced().weight(.bold))
                            .fixedSize(horizontal:false,vertical:true)
                        if (qso.correct) {
                            Text(qso.received)
                                .font(.subheadline.monospaced())
                                .fixedSize(horizontal:false,vertical:true)
                                .padding(.leading, 4)
                        }
                        Spacer(minLength:2)
                        Text(pending ? "PENDING" : qso.diagnosis.code).font(.caption.monospaced().bold())
                            .foregroundStyle(pending ? .yellow : qso.correct ? .green : .orange)
                    }
                    if pending {
                        Text("Awaiting TU confirmation")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if (!qso.correct) {
                        if (qso.copiedCall != qso.call) {
                            Text("Busted call")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                                .padding(.top, 4)
                        }
                        if qso.copiedCall != qso.call {
                            Text("Copied call: \(qso.copiedCall.isEmpty ? "(empty)" : qso.copiedCall)")
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal:false,vertical:true)
                        }
                        if qso.received == qso.expected {
                            Text(qso.received)
                                .font(.subheadline.monospaced())
                                .fixedSize(horizontal:false,vertical:true)
                        } else {
                            Text("Incorrect exchange")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                                .padding(.top, 4)
                            Text("Expected: \(qso.expected)")
                                .font(.subheadline.monospaced())
                                .fixedSize(horizontal:false,vertical:true)
                            Text("Copied:   \(qso.received.isEmpty ? "(empty)" : qso.received)")
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal:false,vertical:true)
                        }
                    }
                }
                .frame(maxWidth:.infinity,alignment:.leading)
                .padding(.vertical,6)
                .contentShape(Rectangle())
                .onTapGesture { vm.selectLogCall(pending && !qso.copiedCall.isEmpty ? qso.copiedCall : qso.call) }
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("log.qso.\(qso.id)")
                Divider()
            }
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:12))
    }
}
#Preview {
    GameView()
        .environmentObject(FieldViewModel())
}

#Preview {
    ResultsPresetPreview()
}

private struct ResultsPresetPreview: View {
    @State private var preset: ResultsPreviewPreset = .standard

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Score case")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Picker("Score case", selection: $preset) {
                    ForEach(ResultsPreviewPreset.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            ResultsSheet(onDone: {})
                .environmentObject(FieldViewModel.resultsPreview(preset: preset))
        }
        .frame(width: 390, height: 844)
    }
}
