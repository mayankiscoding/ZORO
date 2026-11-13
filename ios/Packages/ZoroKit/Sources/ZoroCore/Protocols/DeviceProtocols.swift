import Foundation

// MARK: - Voice

/// The voice state machine (design spec section 9).
public enum VoiceSessionState: String, Sendable, CaseIterable {
    case idle, listening, processing, delegating
    case toolExecution = "tool_execution"
    case speaking, error
    case `private`
}

public enum VoiceEngineKind: String, Sendable, CaseIterable {
    case onDevice = "on_device"
    case cloud
}

public struct VoiceSessionOptions: Sendable, Equatable {
    public var engine: VoiceEngineKind
    /// "en" | "hi" | "hinglish"; nil = detect.
    public var languageHint: String?
    public var privacyMode: PrivacyMode
    /// How the owner starts and ends talking for this session (button, hold-to-talk, wake word inside
    /// an active session); nil = the owner's saved `VoiceSettings.activation`.
    public var activation: VoiceSettings.Activation?
    public init(
        engine: VoiceEngineKind = .onDevice, languageHint: String? = nil, privacyMode: PrivacyMode = .strictPrivate,
        activation: VoiceSettings.Activation? = nil
    ) {
        self.engine = engine
        self.languageHint = languageHint
        self.privacyMode = privacyMode
        self.activation = activation
    }
}

/// Live words of a voice session, partial while they are still being recognised or spoken.
public struct VoiceTranscript: Sendable, Equatable {
    public enum Speaker: String, Sendable, CaseIterable { case owner, assistant }
    public var text: String
    /// False while the recogniser may still revise `text`.
    public var isFinal: Bool
    public var speaker: Speaker
    /// "en" | "hi" | "hinglish" when known.
    public var language: String?
    public init(text: String, isFinal: Bool, speaker: Speaker, language: String? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.speaker = speaker
        self.language = language
    }
}

public protocol VoiceSessionControlling: Sendable {
    func start(_ options: VoiceSessionOptions) async throws
    /// Abandons the session: nothing heard so far is sent.
    func stop() async
    /// End of the owner's utterance (for example hold-to-talk released): sends what was heard as a turn.
    func finishListening() async
    /// Barge-in: stops speech and cancels the running turn.
    func interrupt() async
    func currentState() async -> VoiceSessionState
    func stateUpdates() -> AsyncStream<VoiceSessionState>
    /// Normalised audio level 0...1 (input while listening, output while speaking).
    func levelUpdates() -> AsyncStream<Float>
    /// The owner's words while they speak and the assistant's while it answers.
    func transcriptUpdates() -> AsyncStream<VoiceTranscript>
}

// MARK: - Device actions

/// Runs device tools (alarms, reminders, Mac automation) the backend asks for.
public protocol DeviceActionExecuting: Sendable {
    /// Tool names this device can execute, sent in the channel hello and `PairRequest`.
    var supportedTools: [String] { get async }
    /// Never throws: failures are `DeviceActionResult` with an error code.
    func execute(_ request: DeviceActionRequest) async -> DeviceActionResult
}

// MARK: - Photos

public enum MediaAuthorization: String, Sendable, CaseIterable {
    case notDetermined = "not_determined"
    case denied, restricted, limited, authorized
}

// PhotoQuery, PhotoHit, PhotoSearchResult and PhotoIndexStatus live in Contract/Photos.swift.

public protocol PhotoSearching: Sendable {
    func authorizationStatus() async -> MediaAuthorization
    func requestAuthorization() async -> MediaAuthorization
    func indexStatus() async -> PhotoIndexStatus
    /// Contract search (`device.photos.search`): hits plus `indexed_count`, `limited_library` and a paging cursor.
    func search(_ query: PhotoQuery) async throws -> PhotoSearchResult
    func rebuildIndex() async throws
    func deleteIndex() async throws
}

// MARK: - Health (fitness information only)

public enum HealthAuthorization: String, Sendable, CaseIterable {
    /// HealthKit does not reveal read authorization; `requested` means the sheet was shown.
    case notDetermined = "not_determined"
    case requested
    case unavailable
}

/// Every reading carries its source and when it was read (no fabricated data).
public struct HealthDailySummary: Sendable, Equatable {
    public var date: Date
    public var steps: Int?
    public var activeEnergyKcal: Double?
    public var exerciseMinutes: Double?
    public var standHours: Int?
    public var restingHeartRate: Double?
    public var sleepHours: Double?
    public var source: String
    public var fetchedAt: Date
    public init(
        date: Date, steps: Int? = nil, activeEnergyKcal: Double? = nil, exerciseMinutes: Double? = nil, standHours: Int? = nil,
        restingHeartRate: Double? = nil, sleepHours: Double? = nil, source: String, fetchedAt: Date
    ) {
        self.date = date
        self.steps = steps
        self.activeEnergyKcal = activeEnergyKcal
        self.exerciseMinutes = exerciseMinutes
        self.standHours = standHours
        self.restingHeartRate = restingHeartRate
        self.sleepHours = sleepHours
        self.source = source
        self.fetchedAt = fetchedAt
    }
}

public struct HealthWeeklySummary: Sendable, Equatable {
    public var weekStart: Date
    public var days: [HealthDailySummary]
    public var workouts: Int
    public var source: String
    public var fetchedAt: Date
    public init(weekStart: Date, days: [HealthDailySummary], workouts: Int, source: String, fetchedAt: Date) {
        self.weekStart = weekStart
        self.days = days
        self.workouts = workouts
        self.source = source
        self.fetchedAt = fetchedAt
    }
    public var totalSteps: Int? {
        let values = days.compactMap(\.steps)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

public struct WorkoutSummary: Sendable, Equatable, Identifiable {
    public var id: String
    public var activityType: String
    public var start: Date
    public var end: Date
    public var energyKcal: Double?
    public var distanceMeters: Double?
    public var source: String
    public var durationSeconds: TimeInterval { end.timeIntervalSince(start) }
    public init(id: String, activityType: String, start: Date, end: Date, energyKcal: Double? = nil, distanceMeters: Double? = nil, source: String) {
        self.id = id
        self.activityType = activityType
        self.start = start
        self.end = end
        self.energyKcal = energyKcal
        self.distanceMeters = distanceMeters
        self.source = source
    }
}

public struct HealthDataFreshness: Sendable, Equatable {
    public var metric: String
    public var lastSampleAt: Date?
    public init(metric: String, lastSampleAt: Date?) {
        self.metric = metric
        self.lastSampleAt = lastSampleAt
    }
}

public protocol HealthDataProviding: Sendable {
    func authorization() async -> HealthAuthorization
    func requestAuthorization() async throws
    func dailySummary(for day: Date) async throws -> HealthDailySummary
    func weeklySummary(weekContaining day: Date) async throws -> HealthWeeklySummary
    func workouts(in interval: DateInterval, limit: Int) async throws -> [WorkoutSummary]
    func dataFreshness() async throws -> [HealthDataFreshness]
}

// MARK: - Music

public enum MusicService: String, Sendable, CaseIterable {
    case appleMusic = "apple_music"
    case spotify
}

public struct MusicItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable { case song, album, playlist, artist, station }
    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var service: MusicService
    public var artworkURL: URL?
    public init(id: String, kind: Kind, title: String, subtitle: String? = nil, service: MusicService, artworkURL: URL? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.service = service
        self.artworkURL = artworkURL
    }
}

public struct MusicSearchQuery: Sendable, Equatable {
    public var text: String
    public var kinds: [MusicItem.Kind]
    public var service: MusicService?
    public var limit: Int
    public init(text: String, kinds: [MusicItem.Kind] = [.song], service: MusicService? = nil, limit: Int = 20) {
        self.text = text
        self.kinds = kinds
        self.service = service
        self.limit = limit
    }
}

public enum QueuePosition: String, Sendable { case next, last }

public struct MusicOutputDevice: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var isActive: Bool
    public init(id: String, name: String, isActive: Bool) {
        self.id = id
        self.name = name
        self.isActive = isActive
    }
}

public struct NowPlaying: Sendable, Equatable {
    public var item: MusicItem?
    public var isPlaying: Bool
    public var positionSeconds: Double?
    public var durationSeconds: Double?
    public var deviceName: String?
    public var observedAt: Date
    public init(item: MusicItem?, isPlaying: Bool, positionSeconds: Double? = nil, durationSeconds: Double? = nil, deviceName: String? = nil, observedAt: Date) {
        self.item = item
        self.isPlaying = isPlaying
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.deviceName = deviceName
        self.observedAt = observedAt
    }
}

public protocol MusicControlling: Sendable {
    func authorization() async -> MediaAuthorization
    func search(_ query: MusicSearchQuery) async throws -> [MusicItem]
    /// Plays `item`, or resumes when nil.
    func play(_ item: MusicItem?) async throws
    func pause() async throws
    /// Skips to the next item in the queue.
    func skipToNext() async throws
    /// Goes back to the previous item (or the start of the current one, as the player decides).
    func skipToPrevious() async throws
    func queue(_ item: MusicItem, at position: QueuePosition) async throws
    func outputDevices() async throws -> [MusicOutputDevice]
    func transfer(toDeviceId deviceId: String) async throws
    func nowPlaying() async throws -> NowPlaying?
}

// MARK: - Local intents

public struct LocalIntent: Sendable, Equatable {
    public var name: String
    /// Device tool to run directly, when the intent maps to one.
    public var tool: String?
    public var confidence: Double
    public var slots: JSONObject
    /// "en" | "hi" | "hinglish"
    public var language: String
    public init(name: String, tool: String? = nil, confidence: Double, slots: JSONObject = [:], language: String) {
        self.name = name
        self.tool = tool
        self.confidence = confidence
        self.slots = slots
        self.language = language
    }
}

/// On-device intent classification for device commands; nil = not a known local intent.
public protocol LocalIntentClassifying: Sendable {
    func classify(_ text: String, languageHint: String?) async -> LocalIntent?
}
