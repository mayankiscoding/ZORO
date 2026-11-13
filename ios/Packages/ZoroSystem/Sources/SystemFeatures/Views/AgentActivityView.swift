import SwiftUI
import ZoroCore
import ZoroDesign

/// Live agent and tool activity from the current turn, with risk badges.
public struct AgentActivityView: View {
    let model: AgentActivityViewModel

    public init(model: AgentActivityViewModel) { self.model = model }

    public var body: some View {
        ScreenScroll {
            PhaseView(phase: model.phase, loadingMessage: "Getting started.", emptyMessage: model.emptyMessage, retry: { await model.loadWaiting() }) {
                VStack(alignment: .leading, spacing: ZoroSpace.xl.value) {
                    Text(model.headline).zoroText(.heading)
                    if let approval = model.currentApproval { approvalCard(approval) }
                    if !model.agents.isEmpty { agents }
                    if !model.tools.isEmpty { tools }
                }
            }
            waiting
        }
        .navigationTitle("Now")
        .systemInlineTitle()
        .task { await model.loadWaiting() }
        .refreshable { await model.loadWaiting() }
    }

    private func approvalCard(_ approval: WaitingApproval) -> some View {
        ZoroCard {
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                HStack {
                    Text(approval.title).zoroText(.body).fontWeight(.semibold)
                    Spacer(minLength: ZoroSpace.s.value)
                    RiskBadge(risk: approval.risk)
                }
                Text(approval.summary).zoroText(.detail).foregroundStyle(.secondary)
                Label("Waiting for your approval", systemImage: "hand.raised").zoroText(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroSectionHeader("Agents")
            ZoroCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.agents) { row in
                        AgentActivityRow(ZoroDesign.AgentActivity(id: row.id, agentName: row.name, symbol: row.symbol, status: Self.designStatus(row.status), detail: row.detail))
                    }
                }
            }
        }
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroSectionHeader("Steps")
            ZoroCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.tools.enumerated()), id: \.element.id) { index, tool in
                        if index > 0 { RowDivider() }
                        VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(tool.title).zoroText(.body)
                                Spacer(minLength: ZoroSpace.s.value)
                                RiskBadge(risk: tool.risk)
                            }
                            Text("\(tool.agentName), \(Self.statusText(tool.status))\(tool.detail.map { ". \($0)" } ?? "")")
                                .zoroText(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, ZoroSpace.m.value)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    @ViewBuilder private var waiting: some View {
        if !model.waitingElsewhere.isEmpty {
            VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                ZoroSectionHeader("Waiting for you", detail: "Approvals that are still open. They expire if you don't answer.")
                ZoroCard {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.waitingElsewhere.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { RowDivider() }
                            InfoRow(item.title, detail: item.summary) { RiskBadge(risk: item.risk) }.accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        } else if case .disconnected(let failure) = model.waitingPhase {
            NoticeBanner(notice: .failure(failure.message), dismiss: {})
        }
    }

    static func designStatus(_ status: ActivityStatus) -> AgentActivityStatus {
        switch status {
        case .working: .working
        case .needsYou: .needsYou
        case .done: .done
        case .failed: .failed
        }
    }

    static func statusText(_ status: ToolRow.Status) -> String {
        switch status {
        case .running: "working"
        case .done: "done"
        case .failed: "couldn't finish"
        }
    }
}
