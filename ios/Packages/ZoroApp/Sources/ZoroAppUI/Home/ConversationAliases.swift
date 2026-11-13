// Only ConversationManager is imported here: its module and its main class share a name, and its
// `AgentActivity` collides with ZoroDesign's, so the shell maps it to its own `AgentWork`.
import ConversationManager
import ZoroCore

/// One agent's part in the current turn, as the shell shows it.
public struct AgentWork: Sendable, Equatable {
    public enum State: Sendable, Equatable { case running, done, failed }
    public var agent: AgentId
    public var task: String
    public var state: State

    public init(agent: AgentId, task: String = "", state: State = .running) {
        self.agent = agent
        self.task = task
        self.state = state
    }

    init(_ activity: AgentActivity) {
        agent = activity.agent
        task = activity.task
        switch activity.state {
        case .running: state = .running
        case .finished(let ok, _): state = ok ? .done : .failed
        }
    }
}

extension ConversationManager {
    /// The turn's agents in the shell's terms.
    var agentWork: [AgentWork] { agents.map(AgentWork.init) }

    /// True while any tool of the turn is running.
    var isToolRunning: Bool {
        tools.contains { if case .running = $0.state { true } else { false } }
    }
}
