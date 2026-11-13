import Foundation

/// What an on-device language model understood from an English command. Only plain phrases: the
/// deterministic parser still resolves times and dates, so the model never decides a number.
public struct IntentGuess: Sendable, Equatable {
    /// One of `alarm`, `timer`, `reminder`, `calendar`, `music`, `photos`, `open_section`, `none`.
    public var intent: String
    /// Reminder title.
    public var title: String?
    /// The time words as spoken, for example "tomorrow at 6 pm" or "10 minutes".
    public var timePhrase: String?
    /// Music search text or photo description.
    public var query: String?
    /// `play`, `pause`, `next`, `previous`.
    public var musicAction: String?
    public var section: String?

    public init(intent: String, title: String? = nil, timePhrase: String? = nil, query: String? = nil, musicAction: String? = nil, section: String? = nil) {
        self.intent = intent
        self.title = title
        self.timePhrase = timePhrase
        self.query = query
        self.musicAction = musicAction
        self.section = section
    }

    /// A plain command the rule-based classifier understands, or nil when the guess is not actionable.
    /// Everything the model produced is re-read by the same parser as the owner's own words.
    var canonicalCommand: String? {
        func clean(_ s: String?) -> String? {
            guard let s else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.count > 200 ? nil : trimmed
        }
        let time = clean(timePhrase) ?? ""
        switch intent {
        case "alarm": return time.isEmpty ? nil : "set an alarm \(time)"
        case "timer": return time.isEmpty ? nil : "set a timer for \(time)"
        case "reminder":
            guard let title = clean(title) else { return nil }
            return "remind me to \(title) \(time)"
        case "calendar": return "show my calendar \(time)"
        case "music":
            switch musicAction {
            case "pause": return "pause the music"
            case "next": return "next song"
            case "previous": return "previous song"
            default:
                if let q = clean(query) { return "play \(q)" }
                return "play music"
            }
        case "photos": return clean(query).map { "show photos \($0) \(time)" }
        case "open_section": return clean(section).map { "open \($0)" }
        default: return nil
        }
    }
}

/// An optional on-device language model that helps with English commands the rules did not catch.
/// Apple's system model does not list Hindi, so Hindi and Hinglish never reach it.
public protocol OnDeviceIntentAssisting: Sendable {
    /// Whether the model can run right now (device supports it, Apple Intelligence on, model downloaded).
    func isAvailable() async -> Bool
    /// nil when the model sees no device command in the text.
    func guess(for text: String) async throws -> IntentGuess?
}
