import ConversationManager
import Foundation
import ShoppingInterface
import ZoroAppUI
import ZoroCore
import ZoroDesign

/// Maps the ZoroCore contract to ZoroDesign's display models, so screens built in the composition root
/// draw server data with the shared components. Values are carried as sent (money stays `Decimal`,
/// sources and timestamps are kept); nothing is invented when a field is missing.
public enum DesignAdapters {
    public static func privacyMode(_ mode: PrivacyMode) -> ZoroPrivacyMode {
        switch mode {
        case .strictPrivate: .strictPrivate
        case .cloudIntelligence: .cloudIntelligence
        }
    }

    public static func approvalLevel(_ level: ZoroCore.ApprovalLevel) -> ZoroDesign.ApprovalLevel {
        switch level {
        // `none` never reaches an approval sheet; shown as a plain confirmation if a server ever sends it.
        case .none, .confirm: .confirm
        case .biometric: .biometric
        }
    }

    /// The approval as the sheet shows it: the server's summary sentence, its details in order, the
    /// level and expiry. A tainted request carries the warning line from voice-and-copy section 6.
    public static func approvalSummary(_ request: ApprovalRequest, language: CopyLanguage = .english) -> ApprovalSummary {
        var details = request.details.map { ApprovalDetail(label: $0.label, value: $0.value) }
        if request.tainted {
            details.insert(ApprovalDetail(label: language == .hindi ? "ध्यान दें" : "Check", value: Copy.tainted(language)), at: 0)
        }
        return ApprovalSummary(
            action: request.summary.isEmpty ? request.title : request.summary, details: details, amount: nil,
            level: approvalLevel(request.level), expiresAt: request.expiresAt, handoffNote: nil)
    }

    /// A conversation's agent activity as a ZoroDesign row.
    public static func agentActivity(_ activity: ConversationAgentActivity, needsApproval: Bool = false) -> ZoroDesign.AgentActivity {
        let status: AgentActivityStatus
        switch activity.state {
        case .running: status = needsApproval ? .needsYou : .working
        case .finished(let ok, _): status = ok ? .done : .failed
        }
        return ZoroDesign.AgentActivity(
            id: activity.agent.rawValue, agentName: AgentCatalog.name(activity.agent), symbol: AgentCatalog.symbol(activity.agent),
            status: status, detail: activity.task.isEmpty ? nil : activity.task)
    }

    /// A product the server returned, with its store and retrieval time. nil when the server sent no
    /// price for any variant: a product card never shows a made-up price.
    public static func productCard(_ product: ShownProduct, quantity: Int = 1) -> ProductCardModel? {
        ProductMapping.card(product, quantity: quantity)
    }

    /// The source line ("From Instamart, checked 4:12 pm") in the owner's language.
    public static func sourceLine(_ stamp: SourceStamp, now: Date, language: CopyLanguage = .english) -> String {
        guard language == .hindi else { return stamp.line(now: now) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "hi_IN")
        formatter.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(stamp.retrievedAt, inSameDayAs: now) ? "hmma" : "dMMM")
        return "\(stamp.source) से, \(formatter.string(from: stamp.retrievedAt)) पर देखा गया"
    }
}

/// The language of the copy the composition root adds (the shell and feature packages own theirs).
public enum CopyLanguage: String, Sendable, CaseIterable {
    case english, hindi

    /// Hinglish speakers read the English interface (voice-and-copy section 2).
    public init(languageHint: String?) {
        self = languageHint?.lowercased().hasPrefix("hi") == true && languageHint?.lowercased() != "hinglish" ? .hindi : .english
    }
}

/// Strings from docs/design/voice-and-copy.md, sections 4 to 7, used by the screens this package adds.
public enum Copy {
    public static func privacyTitle(_ mode: PrivacyMode, _ language: CopyLanguage) -> String {
        switch (mode, language) {
        case (.strictPrivate, .english): "Private mode"
        case (.strictPrivate, .hindi): "प्राइवेट मोड"
        case (.cloudIntelligence, .english): "Cloud intelligence"
        case (.cloudIntelligence, .hindi): "क्लाउड इंटेलिजेंस"
        }
    }

    public static func privacyLine(_ mode: PrivacyMode, _ language: CopyLanguage) -> String {
        switch (mode, language) {
        case (.strictPrivate, .english): "Nothing leaves your ZORO server."
        case (.strictPrivate, .hindi): "कुछ भी आपके ZORO सर्वर से बाहर नहीं जाता।"
        case (.cloudIntelligence, .english): "Only what you allowed is sent out, with personal details removed."
        case (.cloudIntelligence, .hindi): "सिर्फ़ वही बाहर भेजा जाता है जिसकी आपने अनुमति दी है, निजी जानकारी हटाकर।"
        }
    }

    public static func agentStatus(_ status: AgentActivityStatus, _ language: CopyLanguage) -> String {
        guard language == .hindi else { return status.label }
        switch status {
        case .queued: return "शुरू होने का इंतज़ार"
        case .working: return "काम जारी है"
        case .needsYou: return "आपकी मंज़ूरी चाहिए"
        case .done: return "हो गया"
        case .failed: return "पूरा नहीं हो सका"
        }
    }

    public static func tainted(_ language: CopyLanguage) -> String {
        language == .hindi
            ? "यह ZORO के पढ़े किसी वेब पेज से आया है। जानकारी जाँच लें।"
            : "This came from a web page ZORO read. Check the details."
    }

    public static func approved(_ language: CopyLanguage) -> String {
        language == .hindi ? "मंज़ूर। अभी भेजा जा रहा है।" : "Approved. Sending now."
    }

    public static func declined(_ language: CopyLanguage) -> String {
        language == .hindi ? "मना कर दिया। कुछ नहीं भेजा गया।" : "Declined. Nothing was sent."
    }

    public static func expired(_ language: CopyLanguage) -> String {
        language == .hindi ? "समय खत्म। मंज़ूरी के लिए फिर से कहें।" : "Expired. Ask again to approve."
    }

    public static func serverUnreachable(_ language: CopyLanguage) -> String {
        language == .hindi
            ? "आपके ZORO सर्वर से जुड़ नहीं पा रहे। देखें कि आपका Mac चालू है और Tailscale पर है।"
            : "Can't reach your ZORO server. Check that your Mac is awake and on Tailscale."
    }

    public static func noActivity(_ language: CopyLanguage) -> String {
        language == .hindi
            ? "अभी कुछ नहीं चल रहा। काम करते समय एजेंट यहाँ दिखेंगे।"
            : "Nothing running. Agents show up here while they work."
    }
}
