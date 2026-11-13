import ZoroCore
import ZoroDesign

/// Display names and symbols for the backend's agents.
public enum AgentCatalog {
    public static func name(_ agent: AgentId) -> String {
        switch agent {
        case .supervisor: "ZORO"
        case .voice: "Voice"
        case .personalAssistant: "Assistant"
        case .memory: "Memory"
        case .finance: "Finance"
        case .investment: "Investments"
        case .shopping: "Shopping"
        case .productResearch: "Product research"
        case .vision: "Photos"
        case .communication: "Communications"
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
        case .supervisor: "circle.circle"
        case .voice: "waveform"
        case .personalAssistant: "person"
        case .memory: "brain"
        case .finance: "indianrupeesign"
        case .investment: "chart.pie"
        case .shopping: "basket"
        case .productResearch: "magnifyingglass"
        case .vision: "photo"
        case .communication: "bubble.left"
        case .fitness: "figure.walk"
        case .music: "music.note"
        case .deviceControl: "iphone.gen3"
        case .document: "doc.text"
        case .browserResearch: "globe"
        case .automation: "gearshape.2"
        case .security: "lock.shield"
        }
    }

    public static func satellite(_ agent: AgentId) -> OrbSatellite {
        OrbSatellite(id: agent.rawValue, name: name(agent), symbol: symbol(agent))
    }

    /// The design-system activity row for a conversation agent. `needsApproval` marks the agent whose
    /// tool is waiting for the owner.
    public static func activity(_ activity: AgentWork, needsApproval: Bool) -> ZoroDesign.AgentActivity {
        let status: AgentActivityStatus
        switch activity.state {
        case .running: status = needsApproval ? .needsYou : .working
        case .done: status = .done
        case .failed: status = .failed
        }
        let task = activity.task.trimmingCharacters(in: .whitespacesAndNewlines)
        return ZoroDesign.AgentActivity(
            id: activity.agent.rawValue, agentName: name(activity.agent), symbol: symbol(activity.agent), status: status,
            detail: task.isEmpty ? nil : task)
    }
}
