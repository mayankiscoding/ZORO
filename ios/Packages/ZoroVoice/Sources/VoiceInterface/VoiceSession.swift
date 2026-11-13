import AudioEngine
import Foundation
import ZoroCore

public struct VoiceSessionConfiguration: Sendable {
    public var client: ClientContext
    public var wakePhrase: WakePhrase
    /// Continuous speech needed over a reply before it counts as barge-in (rejects coughs and echo).
    public var bargeInMinimumSpeech: TimeInterval
    /// Nothing heard this long after the orb opened: close it.
    public var listenTimeout: TimeInterval
    /// A continuing (wake phrase) session ends after this much silence.
    public var followUpWindow: TimeInterval
    /// How long the error state shows before settling.
    public var errorSettle: TimeInterval
    /// Recent microphone chunks replayed into the recogniser after a barge-in, so the first syllables
    /// that interrupted the reply are not lost.
    public var preRollChunks: Int
    public var maxRecognitionFailures: Int
    public var maxRecordedLatencies: Int

    public init(
        client: ClientContext, wakePhrase: WakePhrase = WakePhrase(), bargeInMinimumSpeech: TimeInterval = 0.3,
        listenTimeout: TimeInterval = 8, followUpWindow: TimeInterval = 20, errorSettle: TimeInterval = 1.5,
        preRollChunks: Int = 8, maxRecognitionFailures: Int = 3, maxRecordedLatencies: Int = 50
    ) {
        self.client = client
        self.wakePhrase = wakePhrase
        self.bargeInMinimumSpeech = bargeInMinimumSpeech
        self.listenTimeout = listenTimeout
        self.followUpWindow = followUpWindow
        self.errorSettle = errorSettle
        self.preRollChunks = preRollChunks
        self.maxRecognitionFailures = maxRecognitionFailures
        self.maxRecordedLatencies = maxRecordedLatencies
    }
}

/// Everything the session touches, behind protocols.
public struct VoiceSessionDependencies: Sendable {
    public var capture: any AudioCapturing
    public var player: any PCMStreaming
    public var audioSession: any AudioSessionManaging
    public var recognizer: any SpeechRecognizing
    public var synthesizer: any SpeechSynthesizing
    public var backend: any VoiceBackend
    public var liveTransport: any LiveTransporting
    public var clock: any VoiceClock

    public init(
        capture: any AudioCapturing, player: any PCMStreaming, audioSession: any AudioSessionManaging,
        recognizer: any SpeechRecognizing, synthesizer: any SpeechSynthesizing, backend: any VoiceBackend,
        liveTransport: any LiveTransporting, clock: any VoiceClock = SystemVoiceClock()
    ) {
        self.capture = capture
        self.player = player
        self.audioSession = audioSession
        self.recognizer = recognizer
        self.synthesizer = synthesizer
        self.backend = backend
        self.liveTransport = liveTransport
        self.clock = clock
    }
}

/// The voice session (design spec section 9): one state machine over two engines.
/// On-device: Apple speech recognition → backend turn over SSE → sentence-by-sentence system speech.
/// Cloud: the realtime voice model over a WebSocket, whose only tool `ask_zoro` runs a backend turn.
/// Barge-in stops speech and cancels the running turn. Listening happens only inside a session the
/// owner started; ZORO never listens in the background.
public actor VoiceSession: VoiceSessionControlling {
    let deps: VoiceSessionDependencies
    let config: VoiceSessionConfiguration
    var settings: VoiceSettings

    // Published
    var phase: VoicePhase = .idle
    nonisolated let stateBroadcaster = Broadcaster<VoiceSessionState>(initial: .idle, replayLatest: true)
    nonisolated let levelBroadcaster = Broadcaster<Float>(bufferSize: 8)
    nonisolated let eventBroadcaster = Broadcaster<VoiceSessionEvent>(bufferSize: 256)
    nonisolated let transcriptBroadcaster = Broadcaster<VoiceTranscript>(bufferSize: 64)
    /// The assistant's reply so far, for `transcriptUpdates()`.
    var assistantTranscript = ""

    // Session
    var options = VoiceSessionOptions()
    var privacy: PrivacyMode = .strictPrivate
    var engine: VoiceEngineKind = .onDevice
    var sessionActive = false
    var inFollowUp = false
    var captureTask: Task<Void, Never>?
    var audioEventsTask: Task<Void, Never>?
    var recoveryTask: Task<Void, Never>?
    var outputLevelTask: Task<Void, Never>?
    var preRoll: [Data] = []
    var bargeInSpeech: TimeInterval = 0

    // Recognition (on-device)
    var utteranceGen = 0
    var recognitionTask: Task<Void, Never>?
    var listenTimeoutTask: Task<Void, Never>?
    var recognizing = false
    var heardSpeech = false
    var lastPartial = ""
    var recognitionFailures = 0
    var lastLanguage: SpokenLanguage?
    var localeAvailability: [String: RecognizerAvailability] = [:]

    // Turn and reply
    var turnGen = 0
    var turnTask: Task<Void, Never>?
    var currentTurnId: String?
    var conversationId: String?
    var activeAgents: Set<AgentId> = []
    var turnFinished = false
    var chunker = SentenceChunker()
    var pendingSentences: [String] = []
    var speechTask: Task<Void, Never>?
    var voices: [SpeechVoiceDescriptor]?
    var replyBuffer = ""
    var askCall: LiveFunctionCall?
    var wordPulse = false

    // Cloud
    var liveGen = 0
    var liveTask: Task<Void, Never>?
    var cloudConnected = false
    var resumptionHandle: String?
    var reconnectAttempts = 0
    var inputTranscript = ""
    var cloudAudioMuted = false

    // Metrics
    var latency = LatencyTracker()
    var latencies: [TurnLatency] = []

    public init(dependencies: VoiceSessionDependencies, settings: VoiceSettings = VoiceSettings(), configuration: VoiceSessionConfiguration) {
        self.deps = dependencies
        self.settings = settings
        self.config = configuration
    }

    // MARK: - VoiceSessionControlling

    public nonisolated func stateUpdates() -> AsyncStream<VoiceSessionState> { stateBroadcaster.subscribe() }
    public nonisolated func levelUpdates() -> AsyncStream<Float> { levelBroadcaster.subscribe() }
    /// Transcripts, reply text, turn events, engine changes, latency and errors for the UI.
    public nonisolated func events() -> AsyncStream<VoiceSessionEvent> { eventBroadcaster.subscribe() }
    /// The owner's words while they speak (partial, then final) and the reply as it streams.
    public nonisolated func transcriptUpdates() -> AsyncStream<VoiceTranscript> { transcriptBroadcaster.subscribe() }

    public func currentState() async -> VoiceSessionState { phase.sessionState }
    public var currentPhase: VoicePhase { phase }
    public var activeEngine: VoiceEngineKind? { sessionActive ? engine : nil }

    public func updateSettings(_ settings: VoiceSettings) { self.settings = settings }

    public var recordedLatencies: [TurnLatency] { latencies }
    public var latencySummary: LatencySummary { LatencySummary(latencies) }

    public func start(_ options: VoiceSessionOptions) async throws {
        guard phase.isResting else { return }
        recoveryTask?.cancel()
        self.options = options
        privacy = EngineSelector.stricter(options.privacyMode, nil)
        sessionActive = true
        inFollowUp = false
        latency.reset()

        var mic = await deps.audioSession.microphoneAuthorization()
        if mic == .notDetermined { mic = await deps.audioSession.requestMicrophoneAccess() ? .granted : .denied }
        guard mic == .granted else { throw await failStart(.microphoneDenied) }

        let plan = EngineSelector.plan(settings: settings, options: options)
        let cloudReady = plan == .attemptCloud ? await connectCloud(resumptionHandle: nil) : false
        var onDeviceReady = cloudReady
        if !cloudReady {
            if let error = await prepareOnDeviceRecognition() { throw await failStart(error) }
            onDeviceReady = true
        }
        switch EngineSelector.resolve(plan: plan, cloudReady: cloudReady, onDeviceAvailable: onDeviceReady) {
        case .cloud:
            engine = .cloud
            emit(.engine(.cloud, fallback: nil))
        case .onDevice(let reason):
            engine = .onDevice
            emit(.engine(.onDevice, fallback: reason))
        case .unavailable(let reason):
            throw await failStart(.liveSession(reason))
        }

        do {
            try await deps.audioSession.activate()
            try await startCapture()
        } catch {
            throw await failStart(.audio(error.localizedDescription))
        }
        observeAudioSession()
        observeOutputLevel()
        transition(.start)
        latency.markListening(deps.clock.now())
        if engine == .onDevice { await beginListening(withPreRoll: false) }
    }

    public func stop() async {
        guard sessionActive || !phase.isResting || phase == .error else { return }
        recoveryTask?.cancel()
        await cancelReplyWork(notifyBackend: true)
        await releaseAudio()
        transition(.stop)
    }

    public func interrupt() async {
        await bargeIn()
    }

    /// End of the owner's utterance (hold-to-talk released): transcribe it now and send the turn.
    /// Unlike `stop()`, what was heard is kept.
    public func finishListening() async {
        guard phase == .listening else { return }
        latency.markUtteranceEnd(deps.clock.now())
        if engine == .onDevice, recognizing { await deps.recognizer.endUtterance() }
    }

    // MARK: - Phase

    /// This session's activation mode: the start options when they name one, else the saved setting.
    var activation: VoiceSettings.Activation { options.activation ?? settings.activation }

    var quietRest: VoicePhase { privacy == .strictPrivate ? .privateOffline : .idle }

    var restPhase: VoicePhase {
        guard sessionActive else { return quietRest }
        return engine == .cloud || activation == .wakeWordInSession ? .listening : quietRest
    }

    @discardableResult
    func transition(_ trigger: VoiceTrigger, rest: VoicePhase? = nil) -> Bool {
        guard let next = VoiceStateMachine.next(phase, trigger, rest: rest ?? restPhase) else { return false }
        if next != phase {
            phase = next
            stateBroadcaster.yield(next.sessionState)
            emit(.phase(next))
            if next != .listening, next != .speaking { levelBroadcaster.yield(0) }
        }
        return true
    }

    func emit(_ event: VoiceSessionEvent) {
        eventBroadcaster.yield(event)
        if let words = transcript(for: event) { transcriptBroadcaster.yield(words) }
    }

    /// Maps the internal events onto `VoiceTranscript` values (owner partial / final, assistant reply).
    func transcript(for event: VoiceSessionEvent) -> VoiceTranscript? {
        switch event {
        case .partialTranscript(let text):
            assistantTranscript = ""
            return VoiceTranscript(text: text, isFinal: false, speaker: .owner, language: lastLanguage?.rawValue)
        case .finalTranscript(let text, let language):
            assistantTranscript = ""
            return VoiceTranscript(text: text, isFinal: true, speaker: .owner, language: language.rawValue)
        case .replyText(let delta):
            assistantTranscript += delta
            return VoiceTranscript(text: assistantTranscript, isFinal: false, speaker: .assistant)
        case .turn(.turnCompleted(let done)) where !assistantTranscript.isEmpty:
            defer { assistantTranscript = "" }
            return VoiceTranscript(text: assistantTranscript, isFinal: true, speaker: .assistant, language: done.language)
        default:
            return nil
        }
    }

    // MARK: - Errors

    func failStart(_ error: VoiceError) async -> VoiceError {
        // Not a continuing session: the error settles to rest and releases audio.
        sessionActive = false
        await fail(error)
        return error
    }

    func fail(_ error: VoiceError) async {
        emit(.error(error))
        await cancelReplyWork(notifyBackend: true)
        transition(.failed)
        let gen = turnGen
        recoveryTask?.cancel()
        recoveryTask = Task { [clock = deps.clock, settle = config.errorSettle] in
            try? await clock.sleep(seconds: settle)
            guard !Task.isCancelled else { return }
            await self.settleAfterError(gen)
        }
    }

    func settleAfterError(_ gen: Int) async {
        guard phase == .error, gen == turnGen else { return }
        let continuing = sessionActive && restPhase == .listening
        if continuing {
            transition(.recovered, rest: .listening)
            if engine == .onDevice { await beginListening(withPreRoll: false) }
        } else {
            await releaseAudio()
            transition(.recovered, rest: quietRest)
        }
    }

    // MARK: - Audio

    func startCapture() async throws {
        captureTask?.cancel()
        let chunks = try await deps.capture.start()
        captureTask = Task {
            for await chunk in chunks {
                if Task.isCancelled { break }
                await self.handle(chunk)
            }
        }
    }

    func releaseAudio() async {
        sessionActive = false
        inFollowUp = false
        listenTimeoutTask?.cancel()
        recognitionTask?.cancel()
        if recognizing || engine == .onDevice { await deps.recognizer.cancel() }
        recognizing = false
        captureTask?.cancel()
        captureTask = nil
        await deps.capture.stop()
        audioEventsTask?.cancel()
        outputLevelTask?.cancel()
        if cloudConnected || liveTask != nil {
            liveGen += 1
            liveTask?.cancel()
            liveTask = nil
            cloudConnected = false
            await deps.liveTransport.close()
        }
        preRoll.removeAll()
        await deps.audioSession.deactivate()
    }

    func handle(_ chunk: CapturedChunk) async {
        guard sessionActive else { return }
        if phase == .listening { levelBroadcaster.yield(chunk.level) }
        preRoll.append(chunk.pcm16)
        if preRoll.count > config.preRollChunks { preRoll.removeFirst(preRoll.count - config.preRollChunks) }

        switch engine {
        case .onDevice:
            if recognizing { await deps.recognizer.append(chunk.pcm16) }
            for event in chunk.vadEvents { await handleVAD(event) }
        case .cloud:
            if cloudConnected { try? await deps.liveTransport.sendAudio(chunk.pcm16) }
        }

        if phase == .speaking, chunk.isSpeech {
            bargeInSpeech += chunk.duration
            if bargeInSpeech >= config.bargeInMinimumSpeech { await bargeIn() }
        } else if !chunk.isSpeech {
            bargeInSpeech = 0
        }
    }

    func handleVAD(_ event: VADEvent) async {
        guard phase == .listening, recognizing else { return }
        switch event {
        case .speechStarted:
            heardSpeech = true
            latency.markSpeechStart(deps.clock.now())
            listenTimeoutTask?.cancel()
        case .speechEnded:
            // Endpointing: VAD hangover ends the utterance sooner than the recogniser would.
            guard heardSpeech, activation != .holdToTalk else { return }
            latency.markUtteranceEnd(deps.clock.now())
            await deps.recognizer.endUtterance()
        }
    }

    func observeAudioSession() {
        audioEventsTask?.cancel()
        let events = deps.audioSession.events()
        audioEventsTask = Task {
            for await event in events {
                if Task.isCancelled { break }
                await self.handleAudioSessionEvent(event)
            }
        }
    }

    func handleAudioSessionEvent(_ event: AudioSessionEvent) async {
        switch AudioRecoveryPolicy.action(for: event, sessionActive: sessionActive) {
        case .endSession: await stop()
        case .stopPlayback: if phase == .speaking { await bargeIn() }
        case .restartAudio:
            do { try await startCapture() } catch { await fail(.audio(error.localizedDescription)) }
        case .none: break
        }
    }

    func observeOutputLevel() {
        outputLevelTask?.cancel()
        let levels = deps.player.levels()
        outputLevelTask = Task {
            for await level in levels {
                if Task.isCancelled { break }
                self.forwardOutputLevel(level)
            }
        }
    }

    func forwardOutputLevel(_ level: Float) {
        if phase == .speaking { levelBroadcaster.yield(level) }
    }
}
