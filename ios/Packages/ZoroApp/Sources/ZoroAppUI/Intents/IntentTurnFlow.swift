import AppIntents
import Foundation
import ZoroCore

/// Shared `perform()` steps of the intents that run a turn: run it in the background, plan the reply,
/// and continue in the app when the plan says so.
enum IntentTurnFlow {
    /// Runs `text` as a turn (nil text = nothing to ask) and plans what Siri says.
    static func plan(text: String?, services: ZoroIntentServices) async -> IntentReplyPlan {
        let language = services.language()
        guard services.isConfigured else {
            return IntentReplyPlan.make(for: .failed(.notConfigured), askText: text ?? "", owner: language)
        }
        guard let text, !text.isEmpty else {
            return IntentReplyPlan.make(for: .failed(.empty), askText: "", owner: language)
        }
        let outcome = await services.turns.run(IntentTurnRequest(text: text, language: language))
        return IntentReplyPlan.make(for: outcome, askText: text, owner: language)
    }

    /// Hands the continuation to the app's UI.
    @MainActor
    static func post(_ handoff: IntentHandoff, to inbox: IntentInbox = .shared) {
        switch handoff {
        case .ask(let text): inbox.post(.ask(String(text.prefix(AskLimits.maxPhraseLength))))
        case .conversation(let id): inbox.postConversation(id)
        case .link(let link): inbox.post(link)
        }
    }

    /// Returns the sentence Siri should end with. When the plan continues in the app this either brings the
    /// app forward (iOS 26 and later: `continueInForeground`) or throws the system's continue-in-app error
    /// (iOS 18 to 25: `ForegroundContinuableIntent`), which shows the dialog with a button to open ZORO.
    /// Approvals are never given here: the app asks again and its own approval sheet takes over.
    static func deliver<Intent: ForegroundContinuableIntent>(_ plan: IntentReplyPlan, from intent: Intent) async throws -> String {
        guard let continuation = plan.continuation else { return plan.dialog }
        let copy = IntentCopy(plan.language)
        #if compiler(>=6.2)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard intent.systemContext.currentMode.canContinueInForeground else {
                return "\(plan.dialog) \(copy.openAppToContinue)"
            }
            do {
                try await intent.continueInForeground(IntentDialog("\(plan.dialog)"))
            } catch {
                if case .suspended = continuation.reason { return copy.notContinued }
                return plan.dialog
            }
            await post(continuation.handoff)
            return plan.dialog
        }
        #endif
        let handoff = continuation.handoff
        throw intent.needsToContinueInForegroundError(IntentDialog("\(plan.dialog)")) {
            IntentTurnFlow.post(handoff)
        }
    }
}

extension IntentDialog {
    /// A dialog from text computed at run time (the reply, or `IntentCopy` in the owner's language).
    static func text(_ string: String) -> IntentDialog { IntentDialog("\(string)") }
}
