import Foundation
import Observation
import ZoroCore

public struct TranscriptEntry: Identifiable, Sendable, Equatable {
    public var id: String
    public var role: MessageRole
    public var text: String
    public var language: String
    public var createdAt: Date
    public var agents: [AgentId]
    public var cards: [UICard]
    public var isStreaming: Bool

    public init(id: String, role: MessageRole, text: String, language: String = "en", createdAt: Date, agents: [AgentId] = [], cards: [UICard] = [], isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.language = language
        self.createdAt = createdAt
        self.agents = agents
        self.cards = cards
        self.isStreaming = isStreaming
    }

    var message: Message {
        Message(id: id, role: role, text: text, language: language, createdAt: createdAt, agents: agents, cards: cards)
    }
}

public struct AgentActivity: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable { case running, finished(ok: Bool, durationMs: Int) }
    public var agent: AgentId
    public var task: String
    public var state: State
    public var id: AgentId { agent }

    public init(agent: AgentId, task: String, state: State = .running) {
        self.agent = agent
        self.task = task
        self.state = state
    }
}

public struct ToolActivity: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable { case running, finished(ok: Bool, durationMs: Int, summary: String?) }
    public var callId: String
    public var tool: String
    public var agent: AgentId
    public var risk: RiskLevel
    public var state: State
    public var id: String { callId }

    public init(callId: String, tool: String, agent: AgentId, risk: RiskLevel, state: State = .running) {
        self.callId = callId
        self.tool = tool
        self.agent = agent
        self.risk = risk
        self.state = state
    }
}

public enum ConversationPhase: Sendable, Equatable {
    case idle
    case sending
    case streaming
    case awaitingApproval(ApprovalRequest)
    case runningDeviceAction(DeviceActionRequest)
    case resuming
    case completed
    case cancelled
    case failed(ZoroError)

    public var isBusy: Bool {
        switch self {
        case .sending, .streaming, .awaitingApproval, .runningDeviceAction, .resuming: true
        default: false
        }
    }
}

/// Drives one conversation: sends turns, folds streamed events into transcript text, agent and tool
/// activity and cards, and resolves suspended turns through the injected approval and device-action
/// handlers before resuming them. Completed exchanges are saved to the encrypted local store.
@MainActor
@Observable
public final class ConversationManager {
    public private(set) var phase: ConversationPhase = .idle
    public private(set) var conversationId: String?
    public private(set) var turnId: String?
    public private(set) var privacyMode: PrivacyMode?
    public private(set) var transcript: [TranscriptEntry] = []
    public private(set) var agents: [AgentActivity] = []
    public private(set) var tools: [ToolActivity] = []
    /// Cards of the current turn.
    public private(set) var cards: [UICard] = []
    public private(set) var route: RouteDecided?
    public private(set) var lastCompletion: TurnCompleted?

    /// Sent with every turn; the app keeps it current (locale, capabilities, app state).
    public var clientContext: ClientContext
    /// Per-turn privacy request; only ever stricter than the server setting.
    public var requestedPrivacyMode: PrivacyMode?

    public var isBusy: Bool { phase.isBusy }

    @ObservationIgnored private let api: any ZoroAPI
    @ObservationIgnored private let approvals: any ApprovalHandling
    @ObservationIgnored private let deviceActions: any DeviceActionExecuting
    @ObservationIgnored private let store: ConversationStore?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var streamingEntryIndex: Int?
    @ObservationIgnored private let log = ZoroLog("conversation")

    public init(
        api: any ZoroAPI, approvals: any ApprovalHandling, deviceActions: any DeviceActionExecuting,
        store: ConversationStore? = nil, clientContext: ClientContext, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.approvals = approvals
        self.deviceActions = deviceActions
        self.store = store
        self.clientContext = clientContext
        self.now = now
    }

    // MARK: - Public API

    /// Sends one turn and returns when it completes, fails, or is cancelled (including any approvals
    /// and device actions in between). Ignored while another turn is running.
    public func send(_ text: String, modality: InputModality = .text, languageHint: String? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        cancelRequested = false
        agents = []
        tools = []
        cards = []
        route = nil
        transcript.append(TranscriptEntry(id: "local-\(UUID().uuidString)", role: .user, text: trimmed, createdAt: now()))
        let userIndex = transcript.count - 1
        phase = .sending
        let request = TurnRequest(
            conversationId: conversationId, input: TurnInput(text: trimmed, modality: modality, languageHint: languageHint),
            client: clientContext, privacyMode: requestedPrivacyMode)
        let task = Task { await self.run(request, userIndex: userIndex) }
        activeTask = task
        await task.value
        activeTask = nil
    }

    /// Stops the running turn locally and asks the server to cancel it.
    public func cancel() async {
        guard isBusy else { return }
        cancelRequested = true
        activeTask?.cancel()
        finishStreamingEntry()
        phase = .cancelled
        guard let turnId else { return }
        // A new task: the caller may be the (now cancelled) turn task itself, and URLSession would
        // refuse to send from a cancelled task.
        let api = api
        await Task { try? await api.cancelTurn(id: turnId) }.value
    }

    /// Starts a fresh conversation (the next turn gets a new server conversation id).
    public func startNewConversation() {
        guard !isBusy else { return }
        conversationId = nil
        turnId = nil
        transcript = []
        agents = []
        tools = []
        cards = []
        route = nil
        lastCompletion = nil
        phase = .idle
    }

    /// Shows a stored conversation from the encrypted local store.
    public func loadConversation(id: String) async throws {
        guard !isBusy, let store else { return }
        let messages = try await store.messages(in: id)
        conversationId = id
        transcript = messages.map {
            TranscriptEntry(id: $0.id, role: $0.role, text: $0.text, language: $0.language, createdAt: $0.createdAt, agents: $0.agents, cards: $0.cards)
        }
        phase = .idle
    }

    /// Most messages `loadRemoteConversation` fetches (newest pages beyond this are left on the server).
    public static let remoteMessageLimit = 500

    /// Fetches a conversation from the server (`GET /v1/conversations/{id}/messages`, oldest first) and
    /// adopts it: the next turn continues it. Used for Handoff and for the Mac opening a conversation
    /// started on the iPhone. Throws `.busy` while a turn is running; on failure nothing changes.
    public func loadRemoteConversation(id: String) async throws {
        guard !isBusy else { throw ZoroError.busy }
        var messages: [Message] = []
        var cursor: String?
        repeat {
            let page = try await api.messages(conversationId: id, cursor: cursor, limit: 100)
            messages.append(contentsOf: page.items)
            cursor = page.nextCursor
        } while cursor != nil && messages.count < Self.remoteMessageLimit
        guard !isBusy else { throw ZoroError.busy }
        conversationId = id
        turnId = nil
        transcript = messages.map {
            TranscriptEntry(id: $0.id, role: $0.role, text: $0.text, language: $0.language, createdAt: $0.createdAt, agents: $0.agents, cards: $0.cards)
        }
        agents = []
        tools = []
        cards = []
        route = nil
        lastCompletion = nil
        phase = .idle
    }

    // MARK: - Turn loop

    private func run(_ request: TurnRequest, userIndex: Int) async {
        var stream = api.startTurn(request)
        while true {
            var pendingApproval: ApprovalRequest?
            var pendingAction: DeviceActionRequest?
            var suspended: TurnSuspended?
            var finished = false
            do {
                for try await event in stream {
                    guard !cancelRequested else { return }
                    switch event {
                    case .approvalRequired(let e): pendingApproval = e.approval
                    case .deviceAction(let e): pendingAction = e.action
                    case .turnSuspended(let e): suspended = e
                    case .turnCompleted, .error: finished = true
                    default: break
                    }
                    apply(event, userIndex: userIndex)
                    if finished { break }
                }
            } catch {
                fail(ZoroError.wrap(error))
                return
            }
            guard !cancelRequested else { return }
            if finished {
                if phase == .completed, let assistant = transcript.last, assistant.role == .assistant {
                    await persist(user: transcript[userIndex], assistant: assistant)
                }
                return
            }
            guard let suspended else {
                fail(.invalidResponse("the turn stream ended before the turn finished"))
                return
            }
            let id = turnId ?? suspended.turnId
            switch suspended.reason {
            case .approval:
                guard let approval = pendingApproval else {
                    fail(.invalidResponse("turn suspended for an approval it did not send"))
                    return
                }
                phase = .awaitingApproval(approval)
                let decision: ApprovalDecision
                do {
                    decision = try await approvals.decide(approval)
                } catch {
                    let z = ZoroError.wrap(error)
                    guard !cancelRequested else { return }
                    if z == .userCancelled || z == .cancelled {
                        await cancel()
                    } else {
                        fail(z)
                    }
                    return
                }
                guard !cancelRequested else { return }
                phase = .resuming
                stream = api.resumeTurn(id: id, ResumeRequest(approval: decision))
            case .deviceAction:
                guard let action = pendingAction else {
                    fail(.invalidResponse("turn suspended for a device action it did not send"))
                    return
                }
                phase = .runningDeviceAction(action)
                let result = await deviceActions.execute(action)
                guard !cancelRequested else { return }
                phase = .resuming
                stream = api.resumeTurn(id: id, ResumeRequest(deviceResult: result))
            }
        }
    }

    private func apply(_ event: TurnEvent, userIndex: Int) {
        switch phase {
        case .sending, .resuming: if !event.isTerminal { phase = .streaming }
        default: break
        }
        switch event {
        case .turnStarted(let e):
            turnId = e.turnId
            conversationId = e.conversationId
            privacyMode = e.privacyMode
        case .route(let e):
            route = e
        case .agentStarted(let e):
            let activity = AgentActivity(agent: e.agent, task: e.task, state: .running)
            if let i = agents.firstIndex(where: { $0.agent == e.agent }) { agents[i] = activity } else { agents.append(activity) }
        case .agentFinished(let e):
            if let i = agents.firstIndex(where: { $0.agent == e.agent }) {
                agents[i].state = .finished(ok: e.ok, durationMs: e.durationMs)
            } else {
                agents.append(AgentActivity(agent: e.agent, task: "", state: .finished(ok: e.ok, durationMs: e.durationMs)))
            }
        case .toolStarted(let e):
            tools.append(ToolActivity(callId: e.callId, tool: e.tool, agent: e.agent, risk: e.risk, state: .running))
        case .toolFinished(let e):
            if let i = tools.firstIndex(where: { $0.callId == e.callId }) {
                tools[i].state = .finished(ok: e.ok, durationMs: e.durationMs, summary: e.summary)
            }
        case .textDelta(let e):
            transcript[assistantIndex()].text += e.text
        case .card(let e):
            cards.append(e.card)
            transcript[assistantIndex()].cards.append(e.card)
        case .approvalRequired, .deviceAction, .turnSuspended, .unknown:
            break
        case .turnCompleted(let e):
            lastCompletion = e
            let index = assistantIndex()
            transcript[index].id = e.messageId
            transcript[index].language = e.language
            transcript[index].agents = route?.agents ?? agents.map(\.agent)
            transcript[index].isStreaming = false
            streamingEntryIndex = nil
            phase = .completed
        case .error(let e):
            fail(.turnFailed(e))
        }
    }

    private func assistantIndex() -> Int {
        if let i = streamingEntryIndex, transcript.indices.contains(i) { return i }
        transcript.append(TranscriptEntry(id: "pending-\(UUID().uuidString)", role: .assistant, text: "", createdAt: now(), isStreaming: true))
        streamingEntryIndex = transcript.count - 1
        return transcript.count - 1
    }

    private func finishStreamingEntry() {
        if let i = streamingEntryIndex, transcript.indices.contains(i) { transcript[i].isStreaming = false }
        streamingEntryIndex = nil
    }

    private func fail(_ error: ZoroError) {
        guard !cancelRequested else { return }
        finishStreamingEntry()
        phase = .failed(error)
        log.error("turn failed", error: error)
    }

    /// A failed local save never fails the turn; it is logged without content.
    private func persist(user: TranscriptEntry, assistant: TranscriptEntry) async {
        guard let store, let conversationId else { return }
        do {
            try await store.append(user.message, to: conversationId, conversationTitle: String(user.text.prefix(60)))
            try await store.append(assistant.message, to: conversationId)
        } catch {
            log.error("could not save the conversation locally", error: error)
        }
    }
}
