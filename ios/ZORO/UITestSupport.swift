// UNVERIFIED-ON-HOST
// DEBUG only: launch arguments the XCUITests use. `-zoro-ui-test` builds the graph in memory against an
// unreachable server (nothing persisted, no keychain); `-zoro-ui-test-unpaired` shows first run;
// `-zoro-ui-test-approval` presents the specimen approval through the real approval sheet.
#if os(iOS) && DEBUG
import Foundation
import ZoroComposition
import ZoroCore

enum UITestSupport {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("-zoro-ui-test") }

    static func configuration() -> CompositionConfiguration {
        let unpaired = ProcessInfo.processInfo.arguments.contains("-zoro-ui-test-unpaired")
        return CompositionConfiguration(
            platform: .ios, storage: .inMemory,
            dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("zoro-ui-\(UUID().uuidString)"),
            serverURL: unpaired ? nil : URL(string: "https://127.0.0.1:9"), assumePaired: !unpaired,
            deviceName: "UI test iPhone", startsDeviceChannel: false, defaultsSuite: "app.zoro.uitest.\(UUID().uuidString)")
    }

    @MainActor
    static func afterLaunch(_ app: ZoroApplication) {
        guard ProcessInfo.processInfo.arguments.contains("-zoro-ui-test-approval") else { return }
        Task { await app.inbox.receive(SpecimenApproval.request) }
    }
}

/// Design specimen for the approval-sheet UI test. Interface copy only, no personal data.
enum SpecimenApproval {
    static let request = ApprovalRequest(
        approvalId: "specimen-approval", tool: "automation.run_routine", risk: .medium, level: .confirm,
        title: "Run a routine", summary: "Run the routine you set up.", details: [LabelValue(label: "Routine", value: "Specimen")],
        actionDigest: "specimen", expiresAt: Date().addingTimeInterval(600))
}
#endif
