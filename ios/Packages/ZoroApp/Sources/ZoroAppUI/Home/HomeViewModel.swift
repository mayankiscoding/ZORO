import ConversationManager
import Foundation
import Observation
import ZoroCore
import ZoroDesign

/// Drives Home, Live Voice and the Mac menu-bar orb: maps `ConversationManager` and the voice session
/// to what is shown (`presentation`) and turns the owner's gestures into commands.
@MainActor
@Observable
public final class HomeViewModel {
    public let conversation: ConversationManager

    public private(set) var voiceState: VoiceSessionState = .idle
    public private(set) var connection: ConnectionState = .checking
    public private(set) var serverPrivacyMode: PrivacyMode?
    public private(set) var context = SuggestionContext()
    public private(set) var voiceIssue: HomeIssue?
    /// Set while the purpose sentence for a permission is on screen.
    public private(set) var priming: AppPermission?
    public private(set) var errorSettled = false
    public private(set) var userLevels = LevelRingBuffer(capacity: HomeViewModel.levelCapacity)
    public private(set) var assistantLevels = LevelRingBuffer(capacity: HomeViewModel.levelCapacity)
    /// The latest level, for the orb.
    public private(set) var level: Double = 0
    /// The owner's words while they speak (from `VoiceSessionControlling.transcriptUpdates()`).
    public private(set) var liveOwnerWords: String?
    public var draft = ""

    public static let levelCapacity = 48
    /// How long the orb shows an error before settling (design: "one shake, then settles").
    public static let errorDisplaySeconds: Double = 1.6

    @ObservationIgnored private let voice: any VoiceSessionControlling
    @ObservationIgnored private let api: any ZoroAPI
    @ObservationIgnored private let contextProvider: any HomeContextProviding
    @ObservationIgnored private let permissions: any PermissionPriming
    @ObservationIgnored public var voiceOptions: @MainActor () -> VoiceSessionOptions
    @ObservationIgnored private var observers: [Task<Void, Never>] = []
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    public init(
        conversation: ConversationManager, voice: any VoiceSessionControlling, api: any ZoroAPI,
        context: (any HomeContextProviding)? = nil, permissions: any PermissionPriming,
        voiceOptions: @escaping @MainActor () -> VoiceSessionOptions = { VoiceSessionOptions() }
    ) {
        self.conversation = conversation
        self.voice = voice
        self.api = api
        self.contextProvider = context ?? APIHomeContext(api: api)
        self.permissions = permissions
        self.voiceOptions = voiceOptions
    }

    // MARK: - Presentation

    public var effectivePrivacyMode: PrivacyMode? { conversation.privacyMode ?? serverPrivacyMode }

    public var presentation: HomePresentation {
        HomePresentation.make(HomePresentation.Input(
            voice: voiceState, phase: conversation.phase, transcript: conversation.transcript,
            agents: conversation.agentWork, isToolRunning: conversation.isToolRunning, cards: conversation.cards,
            privacyMode: effectivePrivacyMode, connection: connection, errorSettled: errorSettled,
            voiceIssue: voiceIssue, context: context, liveOwnerWords: liveOwnerWords))
    }

    /// The last thing ZORO said, for the menu bar.
    public var lastReply: String? {
        conversation.transcript.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text
    }

    // MARK: - Lifecycle

    /// Starts following the voice session. Call from `.task`; `stop()` (or the task's cancellation) ends it.
    public func start() async {
        guard observers.isEmpty else { return }
        let voice = voice
        observers.append(Task { [weak self] in
            for await state in voice.stateUpdates() {
                guard !Task.isCancelled else { return }
                self?.voiceDidChange(state)
            }
        })
        observers.append(Task { [weak self] in
            for await level in voice.levelUpdates() {
                guard !Task.isCancelled else { return }
                self?.receiveLevel(Double(level))
            }
        })
        observers.append(Task { [weak self] in
            for await words in voice.transcriptUpdates() {
                guard !Task.isCancelled else { return }
                self?.receiveTranscript(words)
            }
        })
        voiceDidChange(await voice.currentState())
        await refresh()
    }

    public func stop() {
        observers.forEach { $0.cancel() }
        observers = []
        settleTask?.cancel()
    }

    /// Checks the server (privacy mode, kill switch) and reloads suggestion facts.
    public func refresh() async {
        if connection != .connected { connection = .checking }
        do {
            let state = try await api.securityState()
            serverPrivacyMode = state.privacyMode
            connection = state.killSwitch ? .paused : .connected
        } catch {
            connection = ConnectionState.from(error)
        }
        context = connection == .connected ? await contextProvider.suggestionContext() : SuggestionContext()
    }

    // MARK: - Voice

    func voiceDidChange(_ state: VoiceSessionState) {
        guard state != voiceState else { return }
        if state == .listening {
            userLevels.removeAll()
            voiceIssue = nil
            if voiceState != .processing { liveOwnerWords = nil }  // a new utterance starts empty
        }
        if ![.listening, .processing].contains(state) { liveOwnerWords = nil }
        if state == .speaking { assistantLevels.removeAll() }
        if state == .error { errorSettled = false }
        voiceState = state
        if state == .idle || state == .private { level = 0 }
    }

    func receiveTranscript(_ words: VoiceTranscript) {
        guard words.speaker == .owner else { return }
        let text = words.text.trimmingCharacters(in: .whitespacesAndNewlines)
        liveOwnerWords = text.isEmpty ? nil : text
    }

    func receiveLevel(_ raw: Double) {
        let value = raw.isFinite ? min(max(raw, 0), 1) : 0
        switch voiceState {
        case .listening: userLevels.append(value)
        case .speaking: assistantLevels.append(value)
        default: return
        }
        level = value
    }

    /// The orb or talk button was used.
    public func handle(_ gesture: VoiceGesture) async {
        let hold = gesture == .holdBegan
        switch VoiceCommand.forGesture(gesture, in: voiceState) {
        case .start: await startListening(holdToTalk: hold)
        case .stop: await voice.stop()
        case .finishListening: await voice.finishListening()
        case .interrupt: await interrupt()
        case .interruptAndStart:
            await interrupt()
            await startListening(holdToTalk: hold)
        case .none: break
        }
    }

    /// Barge-in: stops speech and cancels the running turn.
    public func interrupt() async {
        await voice.interrupt()
        if conversation.isBusy { await conversation.cancel() }
    }

    /// Leaving Live Voice ends listening; a turn already running carries on and shows on Home.
    public func leaveLiveVoice() async {
        if voiceState == .listening { await voice.stop() }
    }

    /// `holdToTalk`: the owner is holding the button, so the utterance ends on release, not on a pause.
    func startListening(holdToTalk: Bool = false) async {
        voiceIssue = nil
        let gate = VoicePermissionGate.evaluate(
            microphone: await permissions.status(of: .microphone),
            speech: await permissions.status(of: .speechRecognition))
        switch gate {
        case .prime(let permission):
            priming = permission
            return
        case .denied(let permission):
            voiceIssue = HomeIssue(kind: .error, message: permission.deniedMessage, actionTitle: "Open Settings", action: .openSystemSettings)
            return
        case .ready:
            break
        }
        do {
            var options = voiceOptions()
            if holdToTalk { options.activation = .holdToTalk }
            try await voice.start(options)
        } catch {
            voiceIssue = HomeIssue(
                kind: .error, message: "Speech recognition isn't available right now. You can type instead.",
                actionTitle: "Type", action: .typeInstead)
        }
    }

    /// The owner read the purpose sentence and chose Continue: ask the system, then listen if allowed.
    public func continuePriming() async {
        guard let permission = priming else { return }
        priming = nil
        let status = await permissions.request(permission)
        if status == .granted {
            await startListening()
        } else {
            voiceIssue = HomeIssue(kind: .error, message: permission.deniedMessage, actionTitle: "Open Settings", action: .openSystemSettings)
        }
    }

    public func dismissPriming() { priming = nil }

    public func dismissVoiceIssue() { voiceIssue = nil }

    // MARK: - Turns

    /// Sends the composer text as a typed turn.
    public func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, presentation.canSend else { return }
        draft = ""
        await send(text)
    }

    /// Sends a phrase (composer, suggestion, `zoro://ask`, AskZoroIntent).
    public func send(_ text: String, modality: InputModality = .text) async {
        errorSettled = false
        settleTask?.cancel()
        await conversation.send(text, modality: modality)
        await refreshContextAfterTurn()
    }

    public func perform(_ suggestion: Suggestion, navigation: AppNavigation) async {
        switch suggestion.action {
        case .send(let text), .retry(let text): await send(text)
        case .open(let section): navigation.open(section)
        }
    }

    /// Retries the last owner request after a retryable failure.
    public func retryLast() async {
        guard let last = conversation.transcript.last(where: { $0.role == .user })?.text else { return }
        await send(last)
    }

    public func startNewConversation() {
        conversation.startNewConversation()
        errorSettled = false
    }

    /// Called by the view when the orb shows an error: after a moment the orb settles, the sentence stays.
    public func orbDidShow(_ state: OrbState) {
        guard state == .error else { return }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(HomeViewModel.errorDisplaySeconds))
            guard !Task.isCancelled else { return }
            self?.errorSettled = true
        }
    }

    /// Marks the error moment as over (tests and the view's Reduce Motion path).
    public func settleError() { errorSettled = true }

    private func refreshContextAfterTurn() async {
        guard connection == .connected else { return }
        context = await contextProvider.suggestionContext()
    }
}
