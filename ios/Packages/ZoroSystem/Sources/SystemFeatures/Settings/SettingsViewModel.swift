import Foundation
import Observation
import ZoroCore

/// Where the app thinks it stands with the server.
public enum ConnectionState: Equatable, Sendable {
    case unknown
    case checking
    case notPaired
    case connected(sessionExpiresAt: Date)
    case deviceRemoved
    case unreachable

    public var title: String {
        switch self {
        case .unknown, .checking: "Checking the connection"
        case .notPaired: "Not connected"
        case .connected: "Connected"
        case .deviceRemoved: "Removed from ZORO"
        case .unreachable: "Can't reach your server"
        }
    }

    /// One sentence saying what happened and what to do.
    public var detail: String {
        switch self {
        case .unknown, .checking: "Checking your ZORO server."
        case .notPaired: "Pair this device with your ZORO server to use it. You need the pairing code from your server."
        case .connected: "This device is paired and your server answered."
        case .deviceRemoved: SystemCopy.deviceRemoved
        case .unreachable: SystemCopy.unreachable
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// The server address the app is paired with, when it knows it. Provided by the app shell.
public protocol ServerAddressProviding: Sendable {
    func serverAddress() async -> String?
}

public struct StaticServerAddress: ServerAddressProviding {
    public var address: String?
    public init(_ address: String?) { self.address = address }
    public func serverAddress() async -> String? { address }
}

/// Typed client for the voice routes (`/v1/voice`): the voice configuration and settings.
public struct VoiceSettingsClient: Sendable {
    public static let basePath = "/v1/voice"
    private let api: any ZoroAPI
    public init(api: any ZoroAPI) { self.api = api }

    public func config() async throws -> VoiceConfig {
        try await api.voiceConfig()
    }

    public func update(_ settings: VoiceSettings) async throws {
        var clamped = settings
        clamped.speakingRate = min(max(settings.speakingRate, 0.5), 2.0)
        _ = try await api.updateVoiceSettings(clamped)
    }
}

/// Settings: server connection and pairing, voice, language, response length, appearance and model routes.
@MainActor
@Observable
public final class SettingsViewModel {
    public private(set) var connection: ConnectionState = .unknown
    public private(set) var serverAddress: String?
    public private(set) var deviceId: String?

    public private(set) var voicePhase: ScreenPhase = .idle
    public private(set) var voice = VoiceSettings()
    public private(set) var engines: [VoiceEngineStatus] = []
    public private(set) var voices: [VoiceOption] = []

    public private(set) var routesPhase: ScreenPhase = .idle
    public private(set) var routes: [ModelRouteInfo] = []

    public private(set) var appearance: AppearancePreference
    public private(set) var notice: SystemNotice?
    public private(set) var pendingUnpair = false

    @ObservationIgnored private let api: any ZoroAPI
    @ObservationIgnored private let identity: any DeviceIdentityProviding
    @ObservationIgnored private let address: any ServerAddressProviding
    @ObservationIgnored private let preferences: any PreferencesStoring
    @ObservationIgnored private let voiceClient: VoiceSettingsClient
    @ObservationIgnored private var voiceChangeCounter = 0

    public init(
        api: any ZoroAPI, identity: any DeviceIdentityProviding, address: any ServerAddressProviding = StaticServerAddress(nil),
        preferences: any PreferencesStoring = InMemoryPreferences()
    ) {
        self.api = api
        self.identity = identity
        self.address = address
        self.preferences = preferences
        voiceClient = VoiceSettingsClient(api: api)
        appearance = preferences.string(forKey: AppearancePreference.storageKey).flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }

    public var voiceEmptyMessage: String { "No voice settings came back. Check that your ZORO server is up to date." }
    public var routesEmptyMessage: String { "No model routes are set up on your server. Add them in config/models.yaml." }

    // MARK: - Loading

    public func load() async {
        await refreshConnection()
        guard connection.isConnected else {
            // Offline sections say why instead of staying blank.
            let phase: ScreenPhase = connection == .unreachable
                ? .disconnected(ScreenFailure(message: SystemCopy.unreachable))
                : .disconnected(ScreenFailure(message: connection.detail, retryable: false))
            voicePhase = phase
            routesPhase = phase
            return
        }
        async let v: Void = loadVoice()
        async let r: Void = loadRoutes()
        _ = await (v, r)
    }

    public func refreshConnection() async {
        connection = .checking
        deviceId = await identity.deviceId()
        serverAddress = await address.serverAddress()
        guard deviceId != nil else {
            connection = .notPaired
            return
        }
        do {
            let state = try await api.securityState()
            connection = .connected(sessionExpiresAt: state.sessionExpiresAt)
        } catch {
            switch ZoroError.wrap(error) {
            case .notPaired: connection = .notPaired
            case .unauthorized: connection = .deviceRemoved
            case .cancelled: connection = .unknown
            default: connection = .unreachable
            }
        }
    }

    public func loadVoice() async {
        voicePhase = .loading
        do {
            let config = try await voiceClient.config()
            voice = config.settings
            engines = config.engines
            voices = config.voices
            voicePhase = .loaded
        } catch {
            if let next = SystemFailure.phase(for: error) { voicePhase = next }
        }
    }

    public func loadRoutes() async {
        routesPhase = .loading
        do {
            routes = try await api.modelRoutes()
            routesPhase = routes.isEmpty ? .empty : .loaded
        } catch {
            if let next = SystemFailure.phase(for: error) { routesPhase = next }
        }
    }

    // MARK: - Voice settings

    public func setLanguage(_ language: VoiceSettings.Language) async { await updateVoice("Changing the language") { $0.language = language } }
    public func setResponseLength(_ length: VoiceSettings.ResponseLength) async { await updateVoice("Changing the answer length") { $0.responseLength = length } }
    public func setPersonality(_ value: VoiceSettings.Personality) async { await updateVoice("Changing the voice style") { $0.personality = value } }
    public func setVoiceGender(_ value: VoiceSettings.Gender) async { await updateVoice("Changing the voice") { $0.voiceGender = value } }
    public func setEngine(_ value: VoiceSettings.Engine) async { await updateVoice("Changing the voice engine") { $0.engine = value } }
    public func setActivation(_ value: VoiceSettings.Activation) async { await updateVoice("Changing how you start talking") { $0.activation = value } }
    public func setSpeakingRate(_ rate: Double) async {
        await updateVoice("Changing the speaking speed") { $0.speakingRate = min(max(rate, 0.5), 2.0) }
    }
    public func setVoice(id: String?) async { await updateVoice("Changing the voice") { $0.voiceId = id } }

    /// Applies at once, saves in the background, and goes back if the server refuses (unless a newer
    /// change was made in the meantime).
    private func updateVoice(_ action: String, _ change: (inout VoiceSettings) -> Void) async {
        guard voicePhase == .loaded else {
            notice = .failure("\(action) didn't happen. Voice settings haven't loaded yet.")
            return
        }
        let previous = voice
        var next = voice
        change(&next)
        guard next != previous else { return }
        voice = next
        voiceChangeCounter += 1
        let mine = voiceChangeCounter
        do {
            try await voiceClient.update(next)
            if mine == voiceChangeCounter { notice = nil }
        } catch {
            if mine == voiceChangeCounter { voice = previous }
            notice = SystemNotice.failed(error, action: action)
        }
    }

    // MARK: - Appearance

    public func setAppearance(_ value: AppearancePreference) {
        appearance = value
        preferences.set(value == .system ? nil : value.rawValue, forKey: AppearancePreference.storageKey)
    }

    // MARK: - Pairing

    public func requestUnpair() { pendingUnpair = true }
    public func cancelUnpair() { pendingUnpair = false }

    /// Removes this device's keys and pairing. Local only; remove the device on the server from
    /// Security and privacy first if it should stop working there too.
    public func confirmUnpair() async {
        guard pendingUnpair else { return }
        pendingUnpair = false
        do {
            try await identity.unpair()
            deviceId = nil
            connection = .notPaired
            voicePhase = .disconnected(ScreenFailure(message: connection.detail, retryable: false))
            routesPhase = voicePhase
            notice = .success("This device is disconnected.")
        } catch {
            notice = SystemNotice.failed(error, action: "Disconnecting")
        }
    }

    public func dismissNotice() { notice = nil }
}
