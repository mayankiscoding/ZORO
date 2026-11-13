import AppKit
import SwiftUI
import ZoroAppUI
import ZoroComposition
import ZoroCore
import ZoroDesign

/// `ZOROMac --smoke-test [output directory]`: builds the full service graph against an unreachable
/// server (nothing persisted, no keychain, no device channel, no permission prompts), checks the
/// wiring, renders the main window and the menu-bar view off screen to `mac-*.png`, prints
/// "SMOKE OK" and exits. No window is opened.
@MainActor
enum SmokeTest {
    static let unreachableServer = URL(string: "https://127.0.0.1:9")!

    static func run(outputDirectory: URL?) async -> Bool {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("zoro-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: data) }
        let configuration = CompositionConfiguration(
            platform: .macos, storage: .inMemory, dataDirectory: data, serverURL: unreachableServer, assumePaired: true,
            deviceName: "Smoke test Mac", appVersion: "smoke", keepsChannelInBackground: true, startsDeviceChannel: false,
            defaultsSuite: "app.zoro.smoke.\(UUID().uuidString)")
        let app = await ZoroApplication.make(configuration)

        var failures: [String] = []
        if app.shell.sections.registeredSections != Set(AppSection.allCases) { failures.append("sections not all registered") }
        let tools = Set(await app.deviceActions.supportedTools)
        for needed in ["mac.file.search", "mac.applescript.run", "device.music.control", "device.photos.search"] where !tools.contains(needed) {
            failures.append("missing device tool \(needed)")
        }
        if tools.contains(where: { $0.hasPrefix("ios.") }) { failures.append("iPhone-only tools registered on the Mac") }
        let hello = await app.helloTools()
        if !Set(hello).isSubset(of: tools) { failures.append("hello announces unregistered tools") }

        // Against an unreachable server the screens must say so, not hang or crash.
        await app.inbox.refresh()
        switch app.inbox.phase {
        case .disconnected, .failed: break
        default: failures.append("approvals did not report the unreachable server")
        }

        if let outputDirectory {
            do {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                for scheme in [ColorScheme.light, .dark] {
                    let suffix = scheme == .light ? "light" : "dark"
                    try render(
                        CompositionRootView(app: app).frame(width: 1080, height: 720), scheme: scheme,
                        size: CGSize(width: 1080, height: 720), to: outputDirectory.appendingPathComponent("mac-main-window-\(suffix).png"))
                    try render(
                        MenuBarContentView(model: app.shell.home, openMainWindow: {}).zoroEnvironment(app).background(ZoroNeutral.raised),
                        scheme: scheme, to: outputDirectory.appendingPathComponent("mac-menu-bar-\(suffix).png"))
                    try render(
                        WaitingApprovalsView(inbox: app.inbox).padding(ZoroSpace.l.value)
                            .frame(width: 520).zoroEnvironment(app).background(ZoroNeutral.background),
                        scheme: scheme, to: outputDirectory.appendingPathComponent("mac-approvals-disconnected-\(suffix).png"))
                }
            } catch {
                failures.append("render failed: \(error)")
            }
        }

        await app.movedToBackground()
        if failures.isEmpty {
            print("services: api, identity, keys, biometrics, approvals, voice, device actions (\(tools.count) tools), photos, health, music, intents")
            print("hello tools: \(hello.joined(separator: ", "))")
            print("SMOKE OK")
            return true
        }
        for failure in failures { print("SMOKE FAIL: \(failure)") }
        return false
    }

    /// Draws the view in an off-screen window that is never ordered on screen. `ImageRenderer` cannot
    /// draw AppKit-backed views (the sidebar split view, scroll views), so the hosting view's own
    /// display cache is captured instead.
    static func render<V: View>(_ view: V, scheme: ColorScheme, size: CGSize? = nil, to url: URL) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        let fitting = host.fittingSize
        let frame = CGRect(origin: .zero, size: size ?? CGSize(width: max(fitting.width, 200), height: max(fitting.height, 100)))
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
        window.contentView = host
        host.frame = frame
        // Let SwiftUI lay out and run one pass of state updates.
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw ZoroError.storage("no bitmap for \(url.lastPathComponent)")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.close()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw ZoroError.storage("cannot encode \(url.lastPathComponent)")
        }
        try png.write(to: url)
    }
}
