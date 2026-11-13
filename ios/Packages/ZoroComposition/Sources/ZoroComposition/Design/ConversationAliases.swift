import ConversationManager

/// `ConversationManager` is both a module and a class, so `ConversationManager.AgentActivity` cannot name
/// the module's type in a file that also imports ZoroDesign (which has its own `AgentActivity`).
public typealias ConversationAgentActivity = AgentActivity
