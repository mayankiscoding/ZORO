// Ready file for the app targets: the entry point that wires ZoroAppUI. Not compiled in this package.
// The next stage replaces `makeServices()` and `makePairing()` with the concrete ZoroKit, ZoroVoice
// and ZoroDevice implementations, and registers the feature screens and card renderers.
//
// Info.plist (both apps): CFBundleURLTypes with the scheme "zoro"; NSUserActivityTypes containing
// "app.zoro.conversation"; NSMicrophoneUsageDescription and NSSpeechRecognitionUsageDescription with
// the sentences in docs/design/voice-and-copy.md section 8; NSCameraUsageDescription (iPhone, setup QR).
// Siri and App Intents (docs/setup/siri.md): add ZOROShortcuts.swift, AppShortcuts.xcstrings and
// Localizable.xcstrings from this folder; CFBundleLocalizations / Xcode "Localizations" with en and hi;
// the Siri capability is NOT needed for App Intents.
import SwiftUI
import ZoroAppUI
import ZoroCore

@main
struct ZOROApp: App {
    @State private var shell: ZoroAppShell = ZOROApp.makeShell()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before any scene: Siri, Shortcuts, Spotlight and the Action Button may launch the app in the
        // background just to run an intent.
        ZoroIntents.register(
            services: ZOROApp.services, clientContext: ZOROApp.clientContext,
            updateShortcutParameters: { ZOROShortcuts.updateAppShortcutParameters() })
    }

    var body: some Scene {
        WindowGroup {
            ZoroRootView(shell: shell, scanner: scanner, openSystemSettings: openSettings)
                .zoroServices(ZOROApp.services)
                // A long Siri answer continues here: open that conversation.
                .onChange(of: shell.inbox.pendingConversationId, initial: true) { _, id in
                    guard id != nil, let id = shell.inbox.takeConversation() else { return }
                    Task { await shell.openConversation(id: id) }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await ZoroIntentDiscovery.refresh() } }
                }
        }
        #if os(macOS)
        MenuBarExtra("ZORO", systemImage: "circle.circle") {
            MenuBarContentView(model: shell.home) { NSApp.activate() }
        }
        .menuBarExtraStyle(.window)
        #endif
    }

    @MainActor static let services: ZoroServices = makeServices()

    static var clientContext: ClientContext {
        #if os(iOS)
        ClientContext(platform: .ios)
        #else
        ClientContext(platform: .macos)
        #endif
    }

    @MainActor static func makeShell() -> ZoroAppShell {
        let shell = ZoroAppShell.make(
            services: services, clientContext: clientContext,
            pairing: makePairing(), isPaired: false /* read from the identity at launch */)
        // shell.sections.register(.shopping) { ShoppingScreen() }        // registered by the next stage
        // shell.cards.register(kind: "product") { ProductCard(card: $0) }
        return shell
    }

    @MainActor static func makeServices() -> ZoroServices { .unavailable }

    @MainActor static func makePairing() -> any ServerPairing {
        IdentityServerPairing(
            keys: services.keys, identity: services.identity,
            makeAuthAPI: { _ in services.api /* ZoroAPIClient(baseURL: $0, …) */ },
            deviceName: "ZORO device", platform: .ios, capabilities: [], appVersion: nil)
    }

    private var scanner: ((@escaping (PairingLink) -> Void) -> AnyView)? {
        #if os(iOS)
        { onFound in AnyView(SetupCodeScanner(onFound: onFound)) }
        #else
        nil
        #endif
    }

    private func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
