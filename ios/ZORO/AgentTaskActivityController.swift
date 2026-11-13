// UNVERIFIED-ON-HOST
// Starts a Live Activity when the owner leaves the app while a turn is still running, updates it as
// agents work, and ends it when the turn finishes. Never started for an idle conversation.
// Checked against Apple's documentation: ActivityAuthorizationInfo().areActivitiesEnabled,
// Activity.request(attributes:content:pushType:) throws, ActivityContent(state:staleDate:),
// Activity.update(_:) async, Activity.end(_:dismissalPolicy:) async, ActivityUIDismissalPolicy.default.
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import ConversationManager
import Foundation
import Observation
import ZoroAppUI

@MainActor
final class AgentTaskActivityController {
    private var activity: Activity<ZoroTaskActivityAttributes>?
    private var observing = false

    func appMovedToBackground(conversation: ConversationManager) {
        guard activity == nil, conversation.phase.isBusy, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let request = conversation.transcript.last(where: { $0.role == .user })?.text ?? "Your request"
        do {
            activity = try Activity.request(
                attributes: ZoroTaskActivityAttributes(request: String(request.prefix(80))),
                content: ActivityContent(state: Self.state(conversation), staleDate: nil), pushType: nil)
            observe(conversation)
        } catch {
            activity = nil
        }
    }

    func appBecameActive() {
        guard let current = activity else { return }
        activity = nil
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }

    private func observe(_ conversation: ConversationManager) {
        withObservationTracking {
            _ = conversation.phase
            _ = conversation.agents
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let current = self.activity else { return }
                let state = Self.state(conversation)
                if state.finished {
                    self.activity = nil
                    await current.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .default)
                } else {
                    await current.update(ActivityContent(state: state, staleDate: nil))
                    self.observe(conversation)
                }
            }
        }
    }

    static func state(_ conversation: ConversationManager) -> ZoroTaskActivityAttributes.ContentState {
        let names = conversation.agents.filter { $0.state == .running }.map { AgentCatalog.name($0.agent) }
        switch conversation.phase {
        case .awaitingApproval:
            return .init(status: "Waiting for your approval. Open ZORO to review it.", agents: names, needsApproval: true, finished: false)
        case .completed:
            return .init(status: "Done. Open ZORO to see the answer.", agents: [], needsApproval: false, finished: true)
        case .failed, .cancelled:
            return .init(status: "This didn't finish. Open ZORO to try again.", agents: [], needsApproval: false, finished: true)
        default:
            let task = conversation.agents.first(where: { $0.state == .running })?.task
            return .init(status: task ?? "Working on it", agents: names, needsApproval: false, finished: false)
        }
    }
}
#endif
