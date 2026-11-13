import Foundation
import ZoroCore

/// What the app does when an intent continues in the foreground.
public enum IntentHandoff: Sendable, Equatable {
    /// Ask this again as a normal turn in the app (approvals and device actions run there).
    case ask(String)
    /// Show this conversation (a long answer that is already complete on the server).
    case conversation(String)
    /// Open a screen.
    case link(DeepLink)
}

/// Why the intent continues in the app, and what the app does then.
public struct IntentContinuation: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case suspended(IntentSuspension)
        case longReply
        case privateReply
    }

    public var reason: Reason
    public var handoff: IntentHandoff

    public init(reason: Reason, handoff: IntentHandoff) {
        self.reason = reason
        self.handoff = handoff
    }
}

/// The reply text and the first card's summary, shown under Siri's dialog.
public struct IntentSnippet: Sendable, Equatable {
    public var text: String
    public var cardTitle: String?
    public var cardLines: [String]

    public init(text: String, cardTitle: String? = nil, cardLines: [String] = []) {
        self.text = text
        self.cardTitle = cardTitle
        self.cardLines = cardLines
    }

    public var isEmpty: Bool { text.isEmpty && cardTitle == nil && cardLines.isEmpty }
}

/// Which data classes keep an answer off Siri. The intents that send turns all use
/// `.requiresAuthentication`, so Siri asks for Face ID, Touch ID or the passcode on a locked phone before
/// anything reaches ZORO: personal, sensitive, financial and health answers are never read on a locked phone.
/// Secret answers are never handed to Siri at all; they are shown only in the app.
public enum IntentPrivacy {
    /// Data classes that require the phone to be unlocked before Siri may hear or show them.
    public static let unlockRequired: Set<DataClass> = [.personal, .sensitive, .financial, .health, .secret]
    /// Data classes that are never spoken or shown by Siri, even unlocked.
    public static let appOnly: Set<DataClass> = [.secret]

    public static func needsUnlock(_ classes: [DataClass]) -> Bool { !unlockRequired.isDisjoint(with: classes) }
    public static func isAppOnly(_ classes: [DataClass]) -> Bool { !appOnly.isDisjoint(with: classes) }
}

/// Turns a turn's outcome into what Siri says and shows. Pure, so every branch is unit-tested.
public struct IntentReplyPlan: Sendable, Equatable {
    /// Replies longer than this are not read in full: the first sentence is read and the rest opens in the app.
    public static let maxSpokenCharacters = 300
    /// The snippet shows at most this much of the reply.
    public static let maxSnippetCharacters = 600

    public var dialog: String
    public var snippet: IntentSnippet?
    public var continuation: IntentContinuation?
    /// The language the dialog is in.
    public var language: ZoroLanguage

    public init(dialog: String, snippet: IntentSnippet? = nil, continuation: IntentContinuation? = nil, language: ZoroLanguage) {
        self.dialog = dialog
        self.snippet = snippet
        self.continuation = continuation
        self.language = language
    }

    /// - Parameters:
    ///   - askText: the turn text, asked again in the app when the turn suspended.
    ///   - owner: the owner's language, used for ZORO's own sentences when the reply does not name one.
    public static func make(for outcome: IntentTurnOutcome, askText: String, owner: ZoroLanguage) -> IntentReplyPlan {
        switch outcome {
        case .failed(let failure):
            return IntentReplyPlan(dialog: IntentCopy(owner).failure(failure), language: owner)

        case .suspended(let reason, _):
            let copy = IntentCopy(owner)
            return IntentReplyPlan(
                dialog: copy.continuation(reason),
                snippet: nil,
                continuation: IntentContinuation(reason: .suspended(reason), handoff: .ask(askText)),
                language: owner)

        case .answer(let reply):
            let language = IntentCopy.language(ofReply: reply.language, fallback: owner)
            let copy = IntentCopy(language)
            if IntentPrivacy.isAppOnly(reply.dataClasses) {
                return IntentReplyPlan(
                    dialog: copy.privateReply, snippet: nil,
                    continuation: continuation(.privateReply, reply: reply, askText: askText), language: language)
            }
            let snippet = snippet(for: reply)
            let text = reply.text
            if text.count <= maxSpokenCharacters {
                let dialog = text.isEmpty ? (snippet.cardTitle ?? copy.failure(.empty)) : text
                return IntentReplyPlan(dialog: dialog, snippet: snippet, language: language)
            }
            let lead = firstSentence(of: text, limit: maxSpokenCharacters / 2)
            let dialog = lead.map { "\($0) \(copy.longReply)" } ?? copy.longReply
            return IntentReplyPlan(
                dialog: dialog, snippet: snippet,
                continuation: continuation(.longReply, reply: reply, askText: askText), language: language)
        }
    }

    private static func continuation(_ reason: IntentContinuation.Reason, reply: IntentReply, askText: String) -> IntentContinuation {
        if let id = reply.conversationId, !id.isEmpty {
            return IntentContinuation(reason: reason, handoff: .conversation(id))
        }
        // Without a conversation id the app cannot show the finished answer, so it asks again.
        return IntentContinuation(reason: reason, handoff: .ask(askText))
    }

    static func snippet(for reply: IntentReply) -> IntentSnippet {
        var text = reply.text
        if text.count > maxSnippetCharacters { text = String(text.prefix(maxSnippetCharacters - 1)) + "…" }
        guard let card = reply.cards.first else { return IntentSnippet(text: text) }
        let summary = cardSummary(card)
        return IntentSnippet(text: text, cardTitle: summary.title, cardLines: summary.lines)
    }

    /// The card's title and up to two lines: its `summary` field when it has one, else its first two
    /// fields as "Label: value" (values exactly as the server sent them; money strings stay exact).
    public static func cardSummary(_ card: UICard) -> (title: String, lines: [String]) {
        let model = GenericCardModel(card)
        if case .string(let summary)? = card.payload["summary"] {
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return (model.title, [trimmed]) }
        }
        let lines = model.rows.filter { $0.label != "Summary" && $0.label != "Title" }.prefix(2).map { "\($0.label): \($0.value)" }
        return (model.title, Array(lines))
    }

    /// The first sentence when it is short enough to read on its own (Latin or Devanagari punctuation).
    /// A full stop ends a sentence only before whitespace or the end, so "₹1,234.50" is never cut.
    public static func firstSentence(of text: String, limit: Int) -> String? {
        let terminators: Set<Character> = [".", "?", "!", "।"]
        let characters = Array(text)
        var end: Int?
        for (i, character) in characters.enumerated() {
            if i >= limit + 1 { break }
            guard terminators.contains(character) else { continue }
            let next = i + 1 < characters.count ? characters[i + 1] : nil
            if next == nil || next!.isWhitespace {
                end = i
                break
            }
        }
        guard let end else { return nil }
        let sentence = String(characters[...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty, sentence.count <= limit else { return nil }
        return sentence
    }
}
