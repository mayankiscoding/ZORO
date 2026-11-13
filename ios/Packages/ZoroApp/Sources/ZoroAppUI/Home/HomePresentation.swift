import ConversationManager
import Foundation
import ZoroCore
import ZoroDesign

/// Whether the app can reach and use its ZORO server.
public enum ConnectionState: Sendable, Equatable {
    case checking
    case connected
    /// Network-level failure: the server did not answer.
    case unreachable
    case notPaired
    /// The server removed this device or no longer accepts its key.
    case revoked
    /// The kill switch is on.
    case paused
    /// Any other server error, with its sentence.
    case failed(String)

    /// Maps the error of a server call to a connection state.
    public static func from(_ error: Error) -> ConnectionState {
        let z = ZoroError.wrap(error)
        switch z {
        case .notPaired: return .notPaired
        case .unauthorized: return .revoked
        case .transport, .timeout: return .unreachable
        case .http(let status, let body):
            if body?.code == "device_revoked" { return .revoked }
            if body?.code == "kill_switch_active" { return .paused }
            if status == 502 || status == 504 { return .unreachable }
            return .failed(z.errorDescription ?? "The server answered \(status).")
        default:
            return .failed(z.errorDescription ?? "The server could not be used.")
        }
    }
}

/// A problem Home shows, with the one action that fixes it.
public struct HomeIssue: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case disconnected, error }
    public enum Action: Sendable, Equatable {
        case reconnect, pair, openSection(AppSection), retry, typeInstead, openSystemSettings
    }
    public var kind: Kind
    public var message: String
    public var actionTitle: String?
    public var action: Action?

    public init(kind: Kind, message: String, actionTitle: String? = nil, action: Action? = nil) {
        self.kind = kind
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public static func connection(_ state: ConnectionState) -> HomeIssue? {
        switch state {
        case .checking, .connected: nil
        case .unreachable:
            HomeIssue(kind: .disconnected, message: "Can't reach your ZORO server. Check that your Mac is awake and on Tailscale.", actionTitle: "Reconnect", action: .reconnect)
        case .notPaired:
            HomeIssue(kind: .disconnected, message: "This device isn't connected to a ZORO server yet.", actionTitle: "Connect", action: .pair)
        case .revoked:
            HomeIssue(kind: .error, message: "This device was removed from ZORO. Pair it again to continue.", actionTitle: "Pair again", action: .pair)
        case .paused:
            HomeIssue(kind: .error, message: "ZORO is paused. Turn it back on in Security and privacy.", actionTitle: "Open", action: .openSection(.security))
        case .failed(let message):
            HomeIssue(kind: .error, message: message, actionTitle: "Try again", action: .reconnect)
        }
    }
}

/// One suggestion chip. Built only from real context; there are no generic prompts.
public struct Suggestion: Sendable, Equatable, Identifiable {
    public enum Action: Sendable, Equatable {
        case send(String)
        case open(AppSection)
        case retry(String)
    }
    public var title: String
    public var symbol: String?
    public var action: Action
    public var id: String { title }

    public init(title: String, symbol: String? = nil, action: Action) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }
}

/// Facts that suggestions may be drawn from. Every field is optional or zero by default, and a
/// suggestion appears only when its fact is present.
public struct SuggestionContext: Sendable, Equatable {
    /// Items in the active basket, as reported by the shopping package; nil = no basket or unknown.
    public var basketItemCount: Int?
    /// Approvals waiting on the server.
    public var pendingApprovalCount: Int

    public init(basketItemCount: Int? = nil, pendingApprovalCount: Int = 0) {
        self.basketItemCount = basketItemCount
        self.pendingApprovalCount = pendingApprovalCount
    }
}

/// Everything Home draws, computed from the conversation and voice state. Pure, so every mapping is
/// unit-tested.
public struct HomePresentation: Sendable, Equatable {
    public var orbState: OrbState
    public var stateLabel: String
    public var satellites: [OrbSatellite]
    public var agents: [ZoroDesign.AgentActivity]
    /// The owner's words of the current exchange (hang below the rekha).
    public var ownerText: String?
    /// ZORO's words of the current exchange (stand on the rekha).
    public var zoroText: String?
    public var zoroIsStreaming: Bool
    public var cards: [UICard]
    public var privacyMode: ZoroPrivacyMode?
    public var issue: HomeIssue?
    public var suggestions: [Suggestion]
    public var isBusy: Bool
    public var canSend: Bool

    public struct Input: Sendable {
        public var voice: VoiceSessionState
        public var phase: ConversationPhase
        public var transcript: [TranscriptEntry]
        public var agents: [AgentWork]
        public var isToolRunning: Bool
        public var cards: [UICard]
        public var privacyMode: PrivacyMode?
        public var connection: ConnectionState
        /// True once an error has been shown for its moment; the orb then settles.
        public var errorSettled: Bool
        public var voiceIssue: HomeIssue?
        public var context: SuggestionContext
        /// The owner's words as the voice session hears them (partial, then final).
        public var liveOwnerWords: String?

        public init(
            voice: VoiceSessionState = .idle, phase: ConversationPhase = .idle, transcript: [TranscriptEntry] = [],
            agents: [AgentWork] = [], isToolRunning: Bool = false, cards: [UICard] = [],
            privacyMode: PrivacyMode? = nil, connection: ConnectionState = .connected, errorSettled: Bool = false,
            voiceIssue: HomeIssue? = nil, context: SuggestionContext = SuggestionContext(), liveOwnerWords: String? = nil
        ) {
            self.voice = voice
            self.phase = phase
            self.transcript = transcript
            self.agents = agents
            self.isToolRunning = isToolRunning
            self.cards = cards
            self.privacyMode = privacyMode
            self.connection = connection
            self.errorSettled = errorSettled
            self.voiceIssue = voiceIssue
            self.context = context
            self.liveOwnerWords = liveOwnerWords
        }
    }

    public static let maxSatellites = 6

    public static func make(_ input: Input) -> HomePresentation {
        let orb = orbState(input)
        let running = input.agents.filter { $0.state == .running && $0.agent != .supervisor }
        let approvalAgent: AgentId? = {
            if case .awaitingApproval(let request) = input.phase { return request.agent }
            return nil
        }()
        let satellites = (orb == .delegating || orb == .toolExecution)
            ? Array(running.prefix(maxSatellites)).map { AgentCatalog.satellite($0.agent) } : []
        let exchange = currentExchange(input.transcript)
        // While the owner speaks (and until the turn starts answering), their live words hang below the
        // line in place of the previous exchange.
        let live = [.listening, .processing].contains(input.voice)
            ? input.liveOwnerWords.flatMap { $0.isEmpty ? nil : $0 } : nil
        let lastAssistantCards = exchange.zoro?.cards ?? []
        let isBusy = input.phase.isBusy || [.processing, .delegating, .toolExecution].contains(input.voice)
        return HomePresentation(
            orbState: orb,
            stateLabel: stateLabel(orb, input: input, satellites: satellites),
            satellites: satellites,
            agents: input.agents.map { AgentCatalog.activity($0, needsApproval: $0.agent == approvalAgent) },
            ownerText: live ?? exchange.owner?.text,
            zoroText: live != nil ? nil : exchange.zoro.flatMap { $0.text.isEmpty ? nil : $0.text },
            zoroIsStreaming: live != nil ? false : exchange.zoro?.isStreaming ?? false,
            cards: input.cards.isEmpty ? lastAssistantCards : input.cards,
            privacyMode: input.privacyMode.map(displayMode),
            issue: issue(input),
            suggestions: isBusy ? [] : suggestions(input),
            isBusy: isBusy,
            canSend: !isBusy && canReachServer(input.connection)
        )
    }

    static func canReachServer(_ c: ConnectionState) -> Bool {
        switch c {
        case .connected, .checking: true
        default: false
        }
    }

    public static func displayMode(_ mode: PrivacyMode) -> ZoroPrivacyMode {
        switch mode {
        case .strictPrivate: .strictPrivate
        case .cloudIntelligence: .cloudIntelligence
        }
    }

    /// The orb at rest: moonstone and sealed in strict private mode (and when ZORO is paused), peacock otherwise.
    public static func restingState(_ input: Input) -> OrbState {
        if input.connection == .paused { return .privateOffline }
        return input.privacyMode == .strictPrivate ? .privateOffline : .idle
    }

    /// Voice state first (it is what the owner hears), then the turn's phase.
    public static func orbState(_ input: Input) -> OrbState {
        switch input.voice {
        case .listening: return .listening
        case .processing: return .processing
        case .delegating: return .delegating
        case .toolExecution: return .toolExecution
        case .speaking: return .speaking
        case .error: return input.errorSettled ? restingState(input) : .error
        case .private: return .privateOffline
        case .idle: break
        }
        switch input.phase {
        case .sending, .resuming:
            return .processing
        case .streaming:
            if input.isToolRunning { return .toolExecution }
            if input.agents.contains(where: { $0.state == .running && $0.agent != .supervisor }) { return .delegating }
            return .processing
        case .awaitingApproval, .runningDeviceAction:
            return .toolExecution
        case .failed:
            return input.errorSettled ? restingState(input) : .error
        case .idle, .completed, .cancelled:
            return restingState(input)
        }
    }

    static func stateLabel(_ orb: OrbState, input: Input, satellites: [OrbSatellite]) -> String {
        switch input.phase {
        case .awaitingApproval where input.voice == .idle: return "Waiting for your approval"
        case .runningDeviceAction where input.voice == .idle: return "Carrying out a step on this device"
        default: break
        }
        if orb == .idle || orb == .privateOffline {
            switch input.connection {
            case .paused: return "Paused"
            case .unreachable, .notPaired, .revoked, .failed: return "Not connected"
            case .checking, .connected: break
            }
        }
        switch orb {
        case .idle: return "Ready. Tap to talk."
        case .privateOffline: return "Private mode. Tap to talk."
        case .error: return "Something went wrong"
        default: return OrbAccessibility.value(state: orb, satellites: satellites)
        }
    }

    /// The last owner entry and the ZORO reply after it.
    static func currentExchange(_ transcript: [TranscriptEntry]) -> (owner: TranscriptEntry?, zoro: TranscriptEntry?) {
        guard let ownerIndex = transcript.lastIndex(where: { $0.role == .user }) else {
            return (nil, transcript.last(where: { $0.role == .assistant }))
        }
        let reply = transcript[(ownerIndex + 1)...].last(where: { $0.role == .assistant })
        return (transcript[ownerIndex], reply)
    }

    static func issue(_ input: Input) -> HomeIssue? {
        if let connection = HomeIssue.connection(input.connection) { return connection }
        if case .failed(let error) = input.phase {
            return HomeIssue(
                kind: .error, message: message(for: error),
                actionTitle: error.isRetryable ? "Try again" : nil, action: error.isRetryable ? .retry : nil)
        }
        return input.voiceIssue
    }

    static func message(for error: ZoroError) -> String {
        switch error {
        case .transport: "Can't reach your ZORO server. Check that your Mac is awake and on Tailscale."
        case .approvalExpired: "Expired. Ask again to approve."
        default: error.errorDescription ?? "Something went wrong."
        }
    }

    static func suggestions(_ input: Input) -> [Suggestion] {
        var out: [Suggestion] = []
        if case .failed(let error) = input.phase, error.isRetryable,
            let last = input.transcript.last(where: { $0.role == .user })?.text
        {
            out.append(Suggestion(title: "Try again", symbol: "arrow.clockwise", action: .retry(last)))
        }
        if let count = input.context.basketItemCount, count > 0 {
            out.append(Suggestion(title: "Compare my basket", symbol: "basket", action: .send("Compare my basket")))
        }
        let approvals = input.context.pendingApprovalCount
        if approvals > 0 {
            out.append(Suggestion(
                title: approvals == 1 ? "Review 1 waiting approval" : "Review \(approvals) waiting approvals",
                symbol: "checkmark.shield", action: .open(.activity)))
        }
        return out
    }
}

/// Which haptic marks a change of the orb's state, if any.
public enum OrbHaptics {
    public static func haptic(from old: OrbState, to new: OrbState) -> ZoroHaptic? {
        guard old != new else { return nil }
        switch new {
        case .listening: return .listenStart
        case .error: return .failure
        case .speaking: return .selection
        default: return nil
        }
    }
}
