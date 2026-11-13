import SwiftUI
import SystemFeatures
import ZoroCore
import ZoroDesign

/// Activity: approvals waiting for the owner (from any source), then what each agent is doing.
public struct ActivityScreen: View {
    let inbox: ApprovalInbox
    let system: SystemFeaturesContainer

    public init(inbox: ApprovalInbox, system: SystemFeaturesContainer) {
        self.inbox = inbox
        self.system = system
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WaitingApprovalsView(inbox: inbox)
                .padding(.horizontal, ZoroSpace.l.value)
                .padding(.top, ZoroSpace.l.value)
            SystemScreenView(.activity, container: system)
        }
        .background(ZoroNeutral.background)
        .task { await inbox.refresh() }
    }
}

/// The list of approvals waiting on the server, each answered with the approval sheet.
public struct WaitingApprovalsView: View {
    let inbox: ApprovalInbox
    var now: Date

    public init(inbox: ApprovalInbox, now: Date = Date()) {
        self.inbox = inbox
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
            ZoroSectionHeader("Waiting for you", detail: "Requests from automations, connected tools and your other devices.")
            content
            if let outcome = inbox.lastOutcome {
                Text(outcome).zoroText(.detail).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch inbox.phase {
        case .loading:
            ZoroStateView(.loading, message: "Checking for approvals that are waiting.")
        case .disconnected(let message):
            ZoroStateView(.disconnected, message: message, action: ZoroStateAction("Try again") { Task { await inbox.refresh() } })
        case .failed(let message):
            ZoroStateView(.error, message: message, action: ZoroStateAction("Try again") { Task { await inbox.refresh() } })
        case .loaded:
            if inbox.pending.isEmpty {
                ZoroStateView(.empty, message: "Nothing is waiting for your approval. Requests show up here and as a sheet when they arrive.")
            } else {
                ForEach(inbox.pending) { request in
                    WaitingApprovalRow(request: request, now: now, isAnswering: inbox.answering == request.approvalId) {
                        Task { await inbox.answer(request) }
                    }
                }
            }
        }
    }
}

struct WaitingApprovalRow: View {
    let request: ApprovalRequest
    let now: Date
    let isAnswering: Bool
    let onReview: () -> Void

    var body: some View {
        let summary = DesignAdapters.approvalSummary(request)
        ZoroCard {
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                HStack(alignment: .firstTextBaseline) {
                    Text(request.title).zoroText(.heading)
                    Spacer(minLength: ZoroSpace.s.value)
                    if let expiry = summary.expiryText(now: now) {
                        Text(expiry).zoroText(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Text(summary.action).zoroText(.body).fixedSize(horizontal: false, vertical: true)
                if request.tainted {
                    Label(Copy.tainted(.english), systemImage: "exclamationmark.triangle")
                        .zoroText(.detail)
                        .symbolRenderingMode(.multicolor)
                }
                Button(isAnswering ? "Reviewing…" : "Review and answer", action: onReview)
                    .buttonStyle(.zoroPrimary)
                    .disabled(isAnswering)
                    .accessibilityHint("Shows exactly what will happen, then approve or decline.")
            }
        }
        .accessibilityElement(children: .contain)
    }
}
