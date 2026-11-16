//------------------------------------------------------------------------------
//This Source Code Form is subject to the terms of the Mozilla Public
//License, v. 2.0. If a copy of the MPL was not distributed with this
//file, You can obtain one at http://mozilla.org/MPL/2.0/.
//------------------------------------------------------------------------------

import SwiftUI
import AVFoundation
import UIKit

@main
struct MorseJoggerApp: App {
    @StateObject private var app = FieldViewModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .tint(.orange)
                .onChange(of:scenePhase) { _,phase in app.sceneDidChange(active:phase == .active) }
                // UIKit application notifications complement scenePhase. They
                // cover app-level activation edges on iPhone and Catalyst.
                .onReceive(NotificationCenter.default.publisher(for:UIApplication.willResignActiveNotification)) { _ in
                    app.sceneDidChange(active:false)
                }
                .onReceive(NotificationCenter.default.publisher(for:UIApplication.didBecomeActiveNotification)) { _ in
                    #if targetEnvironment(macCatalyst)
                    app.sceneDidChange(active:true,clearStaleInterruption:true)
                    #else
                    app.sceneDidChange(active:true)
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for:AVAudioSession.interruptionNotification)) { event in
                    guard let info=event.userInfo,
                          let value=info[AVAudioSessionInterruptionTypeKey] as? UInt,
                          let kind=AVAudioSession.InterruptionType(rawValue:value) else {return}
                    app.audioInterruption(began:kind == .began)
                }
        }
    }
}
