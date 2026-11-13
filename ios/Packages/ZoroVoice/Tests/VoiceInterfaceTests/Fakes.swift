import AgentClient
import AudioEngine
import Foundation
import ZoroCore

@testable import VoiceInterface

// In-memory fakes for every system service. Nothing here touches hardware, permissions, the Keychain
// or the network.

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func with<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

func eventually(_ timeout: TimeInterval = 3, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

func pcmChunk(speech: Bool, events: [VADEvent] = [], seconds: TimeInterval = 0.2) -> CapturedChunk {
    CapturedChunk(pcm16: Data(count: Int(16_000 * seconds) * 2), level: speech ? 0.7 : 0.05, isSpeech: speech, vadEvents: events)
}

final class FakeCapture: AudioCapturing, @unchecked Sendable {
    private let state = Locked<(continuation: AsyncStream<CapturedChunk>.Continuation?, starts: Int, stops: Int)>((nil, 0, 0))
    var starts: Int { state.get().starts }
    var stops: Int { state.get().stops }
    var isRunning: Bool { state.get().continuation != nil }

    func start() async throws -> AsyncStream<CapturedChunk> {
        let (stream, c) = AsyncStream<CapturedChunk>.makeStream()
        state.with { $0.continuation?.finish(); $0.continuation = c; $0.starts += 1 }
        return stream
    }
    func stop() async {
        state.with { $0.continuation?.finish(); $0.continuation = nil; $0.stops += 1 }
    }
    func send(_ chunk: CapturedChunk) { state.get().continuation?.yield(chunk) }
}

final class FakePlayer: PCMStreaming, @unchecked Sendable {
    let enqueued = Locked<[Data]>([])
    let flushes = Locked(0)
    let finishes = Locked(0)
    private let levelsOut = Broadcaster<Float>()
    func enqueue(_ pcm16: Data) async throws { enqueued.with { $0.append(pcm16) } }
    func finish() async -> Bool {
        finishes.with { $0 += 1 }
        return true
    }
    func flush() async { flushes.with { $0 += 1 } }
    func levels() -> AsyncStream<Float> { levelsOut.subscribe() }
}

final class FakeAudioSession: AudioSessionManaging, @unchecked Sendable {
    let mic: Locked<MicrophoneAuthorization>
    let grantOnRequest: Bool
    let activations = Locked(0)
    let deactivations = Locked(0)
    let broadcaster = Broadcaster<AudioSessionEvent>()
    init(mic: MicrophoneAuthorization = .granted, grantOnRequest: Bool = true) {
        self.mic = Locked(mic)
        self.grantOnRequest = grantOnRequest
    }
    func microphoneAuthorization() async -> MicrophoneAuthorization { mic.get() }
    func requestMicrophoneAccess() async -> Bool {
        mic.with { $0 = grantOnRequest ? .granted : .denied }
        return grantOnRequest
    }
    func activate() async throws { activations.with { $0 += 1 } }
    func deactivate() async { deactivations.with { $0 += 1 } }
    func events() -> AsyncStream<AudioSessionEvent> { broadcaster.subscribe() }
}

actor FakeRecognizer: SpeechRecognizing {
    var auth: SpeechAuthorization
    var availabilityByLocale: [String: RecognizerAvailability]
    private(set) var started: [(locale: String, onDeviceOnly: Bool)] = []
    private(set) var appendedBytes = 0
    private(set) var appendCalls = 0
    private(set) var ends = 0
    private(set) var cancels = 0
    private var continuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?

    init(auth: SpeechAuthorization = .authorized, availability: [String: RecognizerAvailability] = ["en-IN": .onDevice, "hi-IN": .onDevice, "en-US": .onDevice]) {
        self.auth = auth
        self.availabilityByLocale = availability
    }

    func authorization() async -> SpeechAuthorization { auth }
    func requestAuthorization() async -> SpeechAuthorization { auth }
    func availability(locale: String) async -> RecognizerAvailability { availabilityByLocale[locale] ?? .unavailable("unknown") }
    func startUtterance(locale: String, onDeviceOnly: Bool) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        started.append((locale, onDeviceOnly))
        let (stream, c) = AsyncThrowingStream<TranscriptUpdate, Error>.makeStream()
        continuation = c
        return stream
    }
    func append(_ pcm16: Data) async {
        appendedBytes += pcm16.count
        appendCalls += 1
    }
    func endUtterance() async { ends += 1 }
    func cancel() async {
        cancels += 1
        continuation?.finish()
        continuation = nil
    }

    var startCount: Int { started.count }
    var lastLocale: String? { started.last?.locale }
    var lastOnDeviceOnly: Bool? { started.last?.onDeviceOnly }

    func partial(_ text: String) { continuation?.yield(TranscriptUpdate(text: text, isFinal: false)) }
    func final(_ text: String) {
        continuation?.yield(TranscriptUpdate(text: text, isFinal: true))
        continuation?.finish()
        continuation = nil
    }
    func fail(_ error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }
}

actor FakeSynthesizer: SpeechSynthesizing {
    /// When true, each sentence stays "speaking" until `finishCurrent()` or `stop()`.
    var holdSpeech: Bool
    private(set) var spoken: [SpeechUtteranceRequest] = []
    private(set) var stops = 0
    private var current: AsyncStream<SynthesisEvent>.Continuation?
    let voices: [SpeechVoiceDescriptor] = [
        SpeechVoiceDescriptor(id: "en-in-f", name: "Isha", language: "en-IN", gender: .female, quality: 1),
        SpeechVoiceDescriptor(id: "en-in-m", name: "Rishi", language: "en-IN", gender: .male, quality: 1),
        SpeechVoiceDescriptor(id: "hi-in-f", name: "Lekha", language: "hi-IN", gender: .female, quality: 0),
    ]

    init(holdSpeech: Bool = false) { self.holdSpeech = holdSpeech }
    func setHold(_ hold: Bool) { holdSpeech = hold }

    func availableVoices() async -> [SpeechVoiceDescriptor] { voices }
    func speak(_ request: SpeechUtteranceRequest) async -> AsyncStream<SynthesisEvent> {
        spoken.append(request)
        let (stream, c) = AsyncStream<SynthesisEvent>.makeStream()
        c.yield(.started)
        c.yield(.word)
        if holdSpeech {
            current = c
        } else {
            c.yield(.finished)
            c.finish()
        }
        return stream
    }
    func stop() async {
        stops += 1
        current?.yield(.cancelled)
        current?.finish()
        current = nil
    }
    func finishCurrent() {
        current?.yield(.finished)
        current?.finish()
        current = nil
    }
    var texts: [String] { spoken.map(\.text) }
}

/// Backend whose turns follow scripts queued by the test.
final class FakeBackend: VoiceBackend, @unchecked Sendable {
    enum Script {
        case events([TurnEvent])
        /// Emits the events, then stays open until cancelled.
        case open([TurnEvent])
        case fail(Error)
    }
    let scripts = Locked<[Script]>([])
    let requests = Locked<[TurnRequest]>([])
    let cancelled = Locked<[String]>([])
    let grant = Locked<Result<LiveSessionGrant, ZoroError>>(.failure(.unavailable(capability: "Cloud voice", reason: "no key")))
    let grantRequests = Locked(0)

    func queue(_ s: Script...) { scripts.with { $0.append(contentsOf: s) } }

    func startTurn(_ request: TurnRequest) -> AsyncThrowingStream<TurnEvent, Error> {
        requests.with { $0.append(request) }
        let script = scripts.with { $0.isEmpty ? Script.events([]) : $0.removeFirst() }
        return AsyncThrowingStream { c in
            switch script {
            case .events(let events):
                events.forEach { c.yield($0) }
                c.finish()
            case .open(let events):
                events.forEach { c.yield($0) }
            case .fail(let error):
                c.finish(throwing: error)
            }
        }
    }
    func cancelTurn(id: String) async throws { cancelled.with { $0.append(id) } }
    func liveSessionGrant() async throws -> LiveSessionGrant {
        grantRequests.with { $0 += 1 }
        return try grant.get().get()
    }
}

actor FakeTransport: LiveTransporting {
    private(set) var connects: [String?] = []
    private(set) var audioSent = 0
    private(set) var toolResponses: [(id: String, name: String, response: JSONObject)] = []
    private(set) var closes = 0
    var failConnect = false
    private var continuation: AsyncThrowingStream<LiveServerEvent, Error>.Continuation?

    func setFailConnect(_ f: Bool) { failConnect = f }

    func connect(grant: LiveSessionGrant, resumptionHandle: String?) async throws -> AsyncThrowingStream<LiveServerEvent, Error> {
        connects.append(resumptionHandle)
        if failConnect { throw VoiceError.liveSession("refused") }
        let (stream, c) = AsyncThrowingStream<LiveServerEvent, Error>.makeStream()
        continuation = c
        return stream
    }
    func sendAudio(_ pcm16: Data) async throws { audioSent += 1 }
    func sendToolResponse(callId: String, name: String, response: JSONObject) async throws {
        toolResponses.append((callId, name, response))
    }
    func close() async {
        closes += 1
        continuation?.finish()
        continuation = nil
    }
    func server(_ events: LiveServerEvent...) { events.forEach { continuation?.yield($0) } }
    func drop() {
        continuation?.finish(throwing: VoiceError.liveSession("socket closed"))
        continuation = nil
    }
}

/// Sleeps at or below `instant` seconds return at once; longer ones wait (until cancelled).
struct TestClock: VoiceClock {
    let ticks = Locked<TimeInterval>(0)
    var instant: TimeInterval = 1
    func now() -> TimeInterval { ticks.with { $0 += 0.01; return $0 } }
    func sleep(seconds: TimeInterval) async throws {
        if seconds <= instant {
            await Task.yield()
            return
        }
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

final class StateRecorder: @unchecked Sendable {
    let states = Locked<[VoiceSessionState]>([])
    let events = Locked<[VoiceSessionEvent]>([])
    private var tasks: [Task<Void, Never>] = []
    init(_ session: VoiceSession) {
        let s = session.stateUpdates()
        let e = session.events()
        tasks.append(Task { [states] in for await v in s { states.with { $0.append(v) } } })
        tasks.append(Task { [events] in for await v in e { events.with { $0.append(v) } } })
    }
    deinit { tasks.forEach { $0.cancel() } }
    var phases: [VoicePhase] {
        events.get().compactMap { if case .phase(let p) = $0 { p } else { nil } }
    }
    var errors: [VoiceError] {
        events.get().compactMap { if case .error(let e) = $0 { e } else { nil } }
    }
}

struct Harness {
    let capture = FakeCapture()
    let player = FakePlayer()
    let audio: FakeAudioSession
    let recognizer: FakeRecognizer
    let synth: FakeSynthesizer
    let backend = FakeBackend()
    let transport = FakeTransport()
    let clock = TestClock()
    let session: VoiceSession
    let recorder: StateRecorder

    init(
        settings: VoiceSettings = VoiceSettings(), mic: MicrophoneAuthorization = .granted, recognizer: FakeRecognizer = FakeRecognizer(),
        holdSpeech: Bool = false, configure: (inout VoiceSessionConfiguration) -> Void = { _ in }
    ) {
        audio = FakeAudioSession(mic: mic, grantOnRequest: false)
        self.recognizer = recognizer
        synth = FakeSynthesizer(holdSpeech: holdSpeech)
        var config = VoiceSessionConfiguration(client: ClientContext(platform: .ios), errorSettle: 0.01)
        configure(&config)
        let deps = VoiceSessionDependencies(
            capture: capture, player: player, audioSession: audio, recognizer: recognizer, synthesizer: synth,
            backend: backend, liveTransport: transport, clock: clock)
        session = VoiceSession(dependencies: deps, settings: settings, configuration: config)
        recorder = StateRecorder(session)
    }

    func phase() async -> VoicePhase { await session.currentPhase }
    func waitFor(_ phase: VoicePhase) async -> Bool { await eventually { await session.currentPhase == phase } }

    static func grant(expiresIn: TimeInterval = 600) -> LiveSessionGrant {
        LiveSessionGrant(
            provider: "gemini", model: "test-live-model", wsUrl: "wss://example.invalid/ws/live", ephemeralToken: "tok",
            expiresAt: Date().addingTimeInterval(expiresIn), systemInstruction: "Be brief.")
    }
}

enum Turns {
    static func reply(_ text: String, id: String = "t1", cloudVoice: Bool = false, language: String = "en", agents: [AgentId] = [.personalAssistant]) -> [TurnEvent] {
        [
            .turnStarted(TurnStarted(turnId: id, conversationId: "c1", privacyMode: .cloudIntelligence)),
            .route(RouteDecided(agents: agents, reason: "test", dataClasses: [.personal], engine: .deterministic)),
            .textDelta(TextDelta(text: text)),
            .turnCompleted(TurnCompleted(turnId: id, messageId: "m1", language: language, dataClasses: [.personal], cloudVoiceAllowed: cloudVoice, usage: UsageSummary())),
        ]
    }
}
