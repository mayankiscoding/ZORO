import AppKit
import Foundation
import Observation
@preconcurrency import UserNotifications
import ZoroComposition
import ZoroCore

/// Builds the composition root once and keeps it for every scene (window, menu bar, Settings).
@MainActor
@Observable
final class MacAppModel {
    static let mainWindowID = "main"

    private(set) var app: ZoroApplication?
    let notifier = MacNotifier()
    @ObservationIgnored private var starting: Task<Void, Never>?

    func start() async {
        if app != nil { return }
        if let starting { return await starting.value }
        let task = Task { @MainActor in
            let info = Bundle.main.infoDictionary
            let configuration = CompositionConfiguration.standard(
                deviceName: Host.current().localizedName ?? "Mac", appVersion: info?["CFBundleShortVersionString"] as? String,
                homeKitEntitled: false)
            let built = await ZoroApplication.make(configuration)
            built.registerIntents(updateShortcutParameters: { ZOROShortcuts.updateAppShortcutParameters() })
            self.app = built
            self.notifier.watch(built.inbox)
        }
        starting = task
        await task.value
    }

    /// System Settings > Privacy & Security > Microphone (the first permission voice needs).
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Mac notifications: tells the owner when an approval is waiting and ZORO is not in front. Asked for
/// in context (the first time an approval arrives, or from Settings), never at launch. Does nothing in
/// an unbundled build (the smoke test), where the notification centre is not available.
@MainActor
@Observable
final class MacNotifier {
    private(set) var status: UNAuthorizationStatus = .notDetermined
    @ObservationIgnored private var announced: Set<String> = []

    var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func watch(_ inbox: ApprovalInbox) {
        withObservationTracking {
            _ = inbox.pending
        } onChange: { [weak self, weak inbox] in
            Task { @MainActor in
                guard let self, let inbox else { return }
                await self.announce(inbox.pending)
                self.watch(inbox)
            }
        }
    }

    func refreshStatus() async {
        guard isAvailable else { return }
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestPermission() async {
        guard isAvailable else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshStatus()
    }

    private func announce(_ pending: [ApprovalRequest]) async {
        let fresh = pending.filter { !announced.contains($0.approvalId) }
        guard isAvailable, !fresh.isEmpty, !NSApp.isActive else { return }
        await refreshStatus()
        if status == .notDetermined { await requestPermission() }
        guard status == .authorized || status == .provisional else { return }
        for request in fresh {
            announced.insert(request.approvalId)
            let content = UNMutableNotificationContent()
            content.title = "Approval waiting"
            content.body = "\(request.title). Open ZORO to review it."
            content.sound = .default
            let note = UNNotificationRequest(identifier: "approval.\(request.approvalId)", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(note)
        }
    }
}
