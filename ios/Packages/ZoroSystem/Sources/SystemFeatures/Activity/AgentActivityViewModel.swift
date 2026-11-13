import ConversationManager
import Foundation
import Observation
import ZoroCore

public enum AgentCopy {
    public static func name(_ agent: AgentId) -> String {
        switch agent {
        case .supervisor: "ZORO"
        case .voice: "Voice"
        case .personalAssistant: "Personal assistant"
        case .memory: "Memory"
        case .finance: "Finance"
        case .investment: "Investments"
        case .shopping: "Shopping"
        case .productResearch: "Product research"
        case .vision: "Photos"
        case .communication: "Messages"
        case .fitness: "Fitness"
        case .music: "Music"
        case .deviceControl: "Device control"
        case .document: "Documents"
        case .browserResearch: "Web research"
        case .automation: "Automations"
        case .security: "Security"
        }
    }

    public static func symbol(_ agent: AgentId) -> String {
        switch agent {
        case .supervisor: "sparkle"
        case .voice: "waveform"
        case .personalAssistant: "person.crop.circle"
        case .memory: "brain"
        case .finance: "indianrupeesign.circle"
        case .investment: "chart.line.uptrend.xyaxis"
        case .shopping: "cart"
        case .productResearch: "magnifyingglass"
        case .vision: "photo"
        case .communication: "bubble.left"
        case .fitness: "figure.run"
        case .music: "music.note"
        case .deviceControl: "iphone"
        case .document: "doc.text"
        case .browserResearch: "globe"
        case .automation: "gearshape.2"
        case .security: "lock.shield"
        }
    }
}

public enum ActivityStatus: String, Equatable, Sendable {
    case working, needsYou, done, failed
}

public struct AgentRow: Identifiable, Equatable, Sendable {
    public var agent: AgentId
    public var name: String
    public var symbol: String
    public var status: ActivityStatus
    /// A plain sentence of what it is doing, or how long it took.
    public var detail: String?
    public var id: String { agent.rawValue }
}

public struct ToolRow: Identifiable, Equatable, Sendable {
    public enum Status: String, Equatable, Sendable { case running, done, failed }
    public var callId: String
    public var title: String
    public var tool: String
    public var agentName: String
    public var risk: RiskLevel
    public var status: Status
    public var detail: String?
    public var id: String { callId }

    public var riskLabel: String { AuditCopy.riskLabel(risk) }
}

/// One approval that is waiting for the owner.
public struct WaitingApproval: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    public var risk: RiskLevel
    public var expiresAt: Date
}

/// Live agent and tool activity for the Activity tab, read from `ConversationManager`. Reads happen
/// through `@Observable` properties of the manager, so views update as events stream in.
@MainActor
@Observable
public final class AgentActivityViewModel {
    @ObservationIgnored private let manager: ConversationManager
    @ObservationIgnored private let api: (any ZoroAPI)?

    public private(set) var waitingElsewhere: [WaitingApproval] = []
    public private(set) var waitingPhase: ScreenPhase = .idle

    public init(manager: ConversationManager, api: (any ZoroAPI)? = nil) {
        self.manager = manager
        self.api = api
    }

    // MARK: - Derived from the conversation manager

    public var headline: String { Self.headline(for: manager.phase) }

    public var isBusy: Bool { manager.isBusy }

    public var phase: ScreenPhase { Self.screenPhase(phase: manager.phase, agents: manager.agents, tools: manager.tools) }

    public var emptyMessage: String { "Nothing running. Agents show up here while they work." }

    public var agents: [AgentRow] { Self.agentRows(manager.agents, phase: manager.phase) }

    public var tools: [ToolRow] { Self.toolRows(manager.tools) }

    /// The approval the current turn is waiting for, if any.
    public var currentApproval: WaitingApproval? {
        if case .awaitingApproval(let request) = manager.phase { return Self.waiting(request) }
        return nil
    }

    // MARK: - Pure mapping

    static func headline(for phase: ConversationPhase) -> String {
        switch phase {
        case .idle: "Nothing running."
        case .sending: "Sending your request."
        case .streaming: "Working on it."
        case .awaitingApproval: "Waiting for your approval."
        case .runningDeviceAction: "Carrying out a step on this device."
        case .resuming: "Continuing."
        case .completed: "Done."
        case .cancelled: "Stopped. Nothing more will run."
        case .failed(let error): SystemFailure.message(for: error) ?? "Stopped."
        }
    }

    static func screenPhase(phase: ConversationPhase, agents: [AgentActivity], tools: [ToolActivity]) -> ScreenPhase {
        if case .failed(let error) = phase, let mapped = SystemFailure.phase(for: error), mapped.isDisconnected { return mapped }
        if agents.isEmpty && tools.isEmpty {
            if case .failed(let error) = phase, let mapped = SystemFailure.phase(for: error) { return mapped }
            return phase.isBusy ? .loading : .empty
        }
        return .loaded
    }

    static func agentRows(_ agents: [AgentActivity], phase: ConversationPhase) -> [AgentRow] {
        var waitingAgent: AgentId?
        if case .awaitingApproval(let request) = phase { waitingAgent = request.agent }
        return agents.map { activity in
            let status: ActivityStatus
            var detail: String? = activity.task.isEmpty ? nil : activity.task
            switch activity.state {
            case .running:
                status = activity.agent == waitingAgent ? .needsYou : .working
            case .finished(let ok, let ms):
                status = ok ? .done : .failed
                detail = [detail, durationText(ms)].compactMap { $0 }.joined(separator: ", ")
            }
            return AgentRow(
                agent: activity.agent, name: AgentCopy.name(activity.agent), symbol: AgentCopy.symbol(activity.agent),
                status: status, detail: detail)
        }
    }

    static func toolRows(_ tools: [ToolActivity]) -> [ToolRow] {
        tools.map { activity in
            let status: ToolRow.Status
            var detail: String?
            switch activity.state {
            case .running:
                status = .running
            case .finished(let ok, let ms, let summary):
                status = ok ? .done : .failed
                detail = [summary, durationText(ms)].compactMap { $0 }.joined(separator: ", ")
            }
            return ToolRow(
                callId: activity.callId, title: SystemFormat.toolTitle(activity.tool), tool: activity.tool,
                agentName: AgentCopy.name(activity.agent), risk: activity.risk, status: status,
                detail: detail?.isEmpty == true ? nil : detail)
        }
    }

    static func durationText(_ ms: Int) -> String? {
        guard ms >= 0 else { return nil }
        if ms < 1000 { return "\(ms) ms" }
        let seconds = Double(ms) / 1000
        return String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }

    static func waiting(_ request: ApprovalRequest) -> WaitingApproval {
        WaitingApproval(id: request.approvalId, title: request.title, summary: request.summary, risk: request.risk, expiresAt: request.expiresAt)
    }

    // MARK: - Approvals waiting on other turns or devices

    public func loadWaiting() async {
        guard let api else { return }
        waitingPhase = .loading
        do {
            let pending = try await api.pendingApprovals()
            waitingElsewhere = pending.map(Self.waiting)
            waitingPhase = pending.isEmpty ? .empty : .loaded
        } catch {
            if let next = SystemFailure.phase(for: error) { waitingPhase = next }
        }
    }
}
