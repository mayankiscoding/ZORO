// UNVERIFIED-ON-HOST
// Shared by the app target (starts the activity) and the widget extension (draws it).
// Checked against Apple's documentation: ActivityAttributes, ContentState (Codable & Hashable).
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

/// A long-running agent task that continues while the owner is away from the app.
struct ZoroTaskActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// One plain sentence: "Comparing prices at 3 stores", "Waiting for your approval".
        var status: String
        /// Agent names working right now.
        var agents: [String]
        var needsApproval: Bool
        var finished: Bool
    }

    /// What the owner asked, as the conversation shows it.
    var request: String
}
#endif
