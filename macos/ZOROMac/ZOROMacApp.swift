import AppKit
import SwiftUI
import ZoroAppUI
import ZoroComposition
import ZoroCore
import ZoroDesign

/// Entry point: the normal app, or `--smoke-test`, which builds the full service graph against an
/// unreachable server, renders the main window and the menu-bar view off screen, and exits.
@main
enum ZOROMacEntry {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--smoke-test") {
            let rest = CommandLine.arguments.dropFirst(index + 1)
            let output = rest.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            Task { @MainActor in
                let ok = await SmokeTest.run(outputDirectory: output)
                exit(ok ? 0 : 1)
            }
            // Keep the real main thread running (SwiftUI rendering checks for it); dispatchMain() would
            // park it and drain the main queue elsewhere.
            RunLoop.main.run()
            exit(1)
        } else {
            ZOROMacApp.main()
        }
    }
}

/// The Mac companion: the main window with the sidebar, the menu-bar orb with push-to-talk, and
/// Settings. Its own device identity: it pairs separately and announces `mac.*` and `device.*` tools,
/// so the iPhone (or the server) can hand it tasks such as playing music or finding a file.
struct ZOROMacApp: App {
    @State private var model = MacAppModel()

    var body: some Scene {
        Window("ZORO", id: MacAppModel.mainWindowID) {
            Group {
                if let app = model.app {
                    CompositionRootView(app: app, scanner: nil, openSystemSettings: MacAppModel.openPrivacySettings)
                        .onContinueUserActivity(ConversationActivity.type) { app.continueActivity($0) }
                } else {
                    CompositionLaunchView()
                }
            }
            .frame(minWidth: 760, minHeight: 520)
            .task { await model.start() }
        }
        .defaultSize(width: 1080, height: 720)

        MenuBarExtra {
            MenuBarRoot(model: model)
        } label: {
            Label("ZORO", systemImage: "circle.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            if let app = model.app {
                MacSettingsView(app: app, notifier: model.notifier)
                    .zoroEnvironment(app)
            } else {
                CompositionLaunchView().frame(width: 480, height: 240)
            }
        }
    }
}

/// The menu-bar popover: compact orb, push-to-talk (Option-Space), last reply, and "Open ZORO".
struct MenuBarRoot: View {
    let model: MacAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let app = model.app {
            MenuBarContentView(model: app.shell.home) {
                openWindow(id: MacAppModel.mainWindowID)
                NSApp.activate()
            }
            .zoroEnvironment(app)
        } else {
            ZoroStateView(.loading, message: "ZORO is starting. The orb appears in a moment.")
                .padding(ZoroSpace.l.value)
                .frame(width: 320)
                .task { await model.start() }
        }
    }
}
