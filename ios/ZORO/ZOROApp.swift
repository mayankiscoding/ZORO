// UNVERIFIED-ON-HOST
// iPhone app entry point (app target; built only by Xcode). Thin: everything is composed in the
// ZoroComposition package, which is compiled and tested on the Mac host.
// Checked against Apple's documentation: App, WindowGroup, Scene.onChange(of:initial:_:),
// View.onContinueUserActivity(_:perform:), UIApplication.openSettingsURLString, UIApplication.open(_:).
#if os(iOS)
import SwiftUI
import UIKit
import ZoroAppUI
import ZoroComposition
import ZoroCore

@main
struct ZOROApp: App {
    @State private var model: PhoneAppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = PhoneAppModel()
        _model = State(initialValue: model)
        // Before any scene: the photo-index task must be registered before launch finishes, and
        // Siri, Shortcuts and the Action Button may launch the app in the background to run an intent.
        PhotoIndexingTask.register(model: model)
        model.start()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let app = model.app {
                    CompositionRootView(app: app, scanner: { onFound in AnyView(SetupCodeScanner(onFound: onFound)) }, openSystemSettings: openSettings)
                        .onContinueUserActivity(ConversationActivity.type) { app.continueActivity($0) }
                } else {
                    CompositionLaunchView()
                }
            }
        }
        .onChange(of: scenePhase) { oldPhase, phase in
            guard let app = model.app else { return }
            switch phase {
            case .inactive where oldPhase == .active:
                // ActivityKit refuses a request from the background (ActivityAuthorizationError.visibility),
                // so the Live Activity is requested on the way out, while the app is still in the foreground.
                model.liveActivity.appMovedToBackground(conversation: app.shell.home.conversation)
            case .background:
                PhotoIndexingTask.schedule()
            case .active:
                model.liveActivity.appBecameActive()
            default:
                break
            }
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// Builds the composition root once, at launch.
@MainActor
@Observable
final class PhoneAppModel {
    private(set) var app: ZoroApplication?
    let liveActivity = AgentTaskActivityController()
    @ObservationIgnored private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor in
            let info = Bundle.main.infoDictionary ?? [:]
            var configuration = CompositionConfiguration.standard(
                deviceName: UIDevice.current.name, appVersion: info["CFBundleShortVersionString"] as? String,
                // Set by project.yml next to the HomeKit entitlement; iOS terminates an app that uses
                // HomeKit without it, so ios.home.run_scene is announced only when both are present.
                homeKitEntitled: (info["ZOROHomeKitEntitled"] as? String)?.uppercased() == "YES")
            #if DEBUG
            if UITestSupport.isActive { configuration = UITestSupport.configuration() }
            #endif
            let built = await ZoroApplication.make(configuration)
            built.registerIntents(updateShortcutParameters: { ZOROShortcuts.updateAppShortcutParameters() })
            self.app = built
            #if DEBUG
            UITestSupport.afterLaunch(built)
            #endif
        }
    }

    func waitUntilReady() async -> ZoroApplication? {
        await task?.value
        return app
    }
}
#endif
