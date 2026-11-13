import Foundation

/// Handoff for the current conversation: the iPhone advertises it, the Mac picks it up (and the other
/// way round). Only the conversation id travels; no message text is put in the activity, and it is
/// never indexed for search.
public enum ConversationActivity {
    /// Must be listed under `NSUserActivityTypes` in both apps' Info.plist.
    public static let type = "app.zoro.conversation"
    static let conversationKey = "conversation_id"
    static let sectionKey = "section"

    /// Fills an activity SwiftUI created (`.userActivity(_:isActive:_:)`).
    public static func configure(_ activity: NSUserActivity, conversationId: String, section: AppSection = .home) {
        activity.title = "Conversation with ZORO"
        activity.userInfo = [conversationKey: conversationId, sectionKey: section.rawValue]
        activity.requiredUserInfoKeys = [conversationKey]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.targetContentIdentifier = "conversation/\(conversationId)"
        activity.needsSave = true
    }

    public static func make(conversationId: String, section: AppSection = .home) -> NSUserActivity {
        let activity = NSUserActivity(activityType: type)
        configure(activity, conversationId: conversationId, section: section)
        return activity
    }

    public struct Continuation: Sendable, Equatable {
        public var conversationId: String
        public var section: AppSection
    }

    /// Reads a received activity; nil when it is not a ZORO conversation or has no usable id.
    public static func parse(_ activity: NSUserActivity) -> Continuation? {
        guard activity.activityType == type,
            let id = activity.userInfo?[conversationKey] as? String,
            !id.trimmingCharacters(in: .whitespaces).isEmpty, id.count <= 128
        else { return nil }
        let section = (activity.userInfo?[sectionKey] as? String).flatMap(AppSection.init(rawValue:)) ?? .home
        return Continuation(conversationId: id, section: section)
    }
}
