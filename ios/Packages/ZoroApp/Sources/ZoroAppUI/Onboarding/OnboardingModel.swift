import Foundation
import Observation
import ZoroCore

/// Reply language chosen at setup. Interface chrome follows the app language setting.
public enum ZoroLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case english = "en"
    case hindi = "hi"
    case hinglish

    public var id: String { rawValue }
    /// Each name in its own script.
    public var title: String {
        switch self {
        case .english: "English"
        case .hindi: "हिन्दी"
        case .hinglish: "Hinglish"
        }
    }
    public var detail: String {
        switch self {
        case .english: "ZORO replies in English."
        case .hindi: "ZORO हिन्दी में, देवनागरी में जवाब देगा।"
        case .hinglish: "ZORO replies in Hinglish, in Latin script."
        }
    }
}

/// The voice ZORO speaks with. It also sets ZORO's first-person verb forms in Hindi.
public enum VoiceStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case feminine, masculine
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .feminine: "Female voice"
        case .masculine: "Male voice"
        }
    }
    public var detail: String {
        switch self {
        case .feminine: "In Hindi, ZORO says \"मैं खोल सकती हूँ\"."
        case .masculine: "In Hindi, ZORO says \"मैं खोल सकता हूँ\"."
        }
    }
}

public struct AppPreferences: Codable, Sendable, Equatable {
    public var language: ZoroLanguage
    public var voice: VoiceStyle
    public var serverURL: URL?
    public var onboardingComplete: Bool

    public init(language: ZoroLanguage = .english, voice: VoiceStyle = .feminine, serverURL: URL? = nil, onboardingComplete: Bool = false) {
        self.language = language
        self.voice = voice
        self.serverURL = serverURL
        self.onboardingComplete = onboardingComplete
    }
}

public protocol PreferencesStoring: Sendable {
    func load() -> AppPreferences
    func save(_ preferences: AppPreferences)
}

/// `UserDefaults`-backed preferences (no secrets live here; keys stay in the Keychain).
public struct UserDefaultsPreferences: PreferencesStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "zoro.preferences") {
        self.defaults = defaults
        self.key = key
    }
    public func load() -> AppPreferences {
        guard let data = defaults.data(forKey: key), let p = try? JSONDecoder().decode(AppPreferences.self, from: data) else {
            return AppPreferences()
        }
        return p
    }
    public func save(_ preferences: AppPreferences) {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: key) }
    }
}

/// Creates the device keys and pairs with a server.
public protocol ServerPairing: Sendable {
    /// Creates the auth and approval keys when absent.
    func createKeys() async throws
    func pair(serverURL: URL, code: String) async throws -> PairResponse
}

/// The real pairing: keys from `KeyStoring`, the request signed by `DeviceIdentityProviding`, sent
/// to the typed address through an auth client the composition root builds for that address.
public struct IdentityServerPairing: ServerPairing {
    private let keys: any KeyStoring
    private let identity: any DeviceIdentityProviding
    private let makeAuthAPI: @Sendable (URL) -> any ZoroAuthAPI
    private let deviceName: String
    private let platform: DevicePlatform
    private let capabilities: [String]
    private let appVersion: String?

    public init(
        keys: any KeyStoring, identity: any DeviceIdentityProviding, makeAuthAPI: @escaping @Sendable (URL) -> any ZoroAuthAPI,
        deviceName: String, platform: DevicePlatform, capabilities: [String], appVersion: String?
    ) {
        self.keys = keys
        self.identity = identity
        self.makeAuthAPI = makeAuthAPI
        self.deviceName = deviceName
        self.platform = platform
        self.capabilities = capabilities
        self.appVersion = appVersion
    }

    public func createKeys() async throws { try await keys.ensureSigningKeys() }

    public func pair(serverURL: URL, code: String) async throws -> PairResponse {
        let request = try await identity.pairRequest(
            pairingCode: code, deviceName: deviceName, platform: platform, capabilities: capabilities, appVersion: appVersion)
        let response = try await makeAuthAPI(serverURL).pair(request)
        try await identity.completePairing(response)
        return response
    }
}

/// Why connecting failed, in one sentence with the next step.
public enum ConnectProblem: Sendable, Equatable {
    case invalidAddress
    case missingCode
    case wrongCode
    case unreachable(host: String)
    case rateLimited
    case notAZoroServer(host: String)
    case keys(String)
    case other(String)

    public var message: String {
        switch self {
        case .invalidAddress: "Enter the server address, like zoro.your-tailnet.ts.net."
        case .missingCode: "Enter the pairing code your server printed."
        case .wrongCode: "That code didn't match or has expired. Make a new one on your server: python -m app.cli pairing-code"
        case .unreachable(let host): "Can't reach a ZORO server at \(host). Check the address, and that your Mac is awake and on Tailscale."
        case .rateLimited: "Too many tries. Wait a minute, then try again."
        case .notAZoroServer(let host): "\(host) didn't answer like a ZORO server. Check the address."
        case .keys(let detail): "This device couldn't create its keys: \(detail)"
        case .other(let message): message
        }
    }

    static func from(_ error: Error, host: String) -> ConnectProblem {
        let z = ZoroError.wrap(error)
        switch z {
        case .transport, .timeout: return .unreachable(host: host)
        case .decoding, .invalidResponse: return .notAZoroServer(host: host)
        case .http(let status, let body):
            if body?.code == "pairing_code_invalid" { return .wrongCode }
            if status == 429 || body?.code == "rate_limited" { return .rateLimited }
            if status == 404 || status == 405 { return .notAZoroServer(host: host) }
            if status == 502 || status == 504 { return .unreachable(host: host) }
            return .other(z.errorDescription ?? "The server answered \(status).")
        case .keyUnavailable(let m), .signingFailed(let m): return .keys(m)
        default: return .other(z.errorDescription ?? "Pairing failed.")
        }
    }
}

public enum OnboardingStep: Sendable, Equatable {
    case welcome
    case connect
    case creatingKeys
    case pairing
    case language
    case voice
    /// Action Button and Lock Screen control guide (iPhone; optional).
    case shortcuts
    case done
}

/// First run: welcome → connect → keys → pair → language → voice → (iPhone) shortcuts guide → done.
/// Permissions are not asked here; each is primed the first time a feature needs it.
@MainActor
@Observable
public final class OnboardingModel {
    public private(set) var step: OnboardingStep = .welcome
    public var serverAddress = ""
    public var pairingCode = ""
    public private(set) var problem: ConnectProblem?
    public private(set) var serverName: String?
    public var language: ZoroLanguage
    public var voice: VoiceStyle

    @ObservationIgnored private let pairing: any ServerPairing
    @ObservationIgnored private let preferences: any PreferencesStoring
    @ObservationIgnored private let showsShortcutGuide: Bool
    @ObservationIgnored private var pairedServerURL: URL?

    public init(pairing: any ServerPairing, preferences: any PreferencesStoring, showsShortcutGuide: Bool) {
        self.pairing = pairing
        self.preferences = preferences
        self.showsShortcutGuide = showsShortcutGuide
        let saved = preferences.load()
        language = saved.language
        voice = saved.voice
    }

    public var isConnecting: Bool { step == .creatingKeys || step == .pairing }

    public func begin() {
        guard step == .welcome else { return }
        step = .connect
    }

    /// Fills the form from a `zoro://pair` link or the setup QR code, then connects.
    public func apply(_ link: PairingLink) async {
        guard [.welcome, .connect].contains(step) else { return }
        serverAddress = link.serverURL.absoluteString
        pairingCode = link.code
        step = .connect
        await connect()
    }

    public func connect() async {
        guard step == .connect else { return }
        problem = nil
        guard let url = PairingLink.serverURL(from: serverAddress) else {
            problem = .invalidAddress
            return
        }
        let code = PairingLink.normaliseCode(pairingCode)
        guard !code.isEmpty else {
            problem = .missingCode
            return
        }
        let host = url.host ?? url.absoluteString
        step = .creatingKeys
        do {
            try await pairing.createKeys()
        } catch {
            let z = ZoroError.wrap(error)
            problem = .keys(z.errorDescription ?? "unknown error")
            step = .connect
            return
        }
        guard !Task.isCancelled else { step = .connect; return }
        step = .pairing
        do {
            let response = try await pairing.pair(serverURL: url, code: code)
            serverName = response.serverName
            pairedServerURL = url
            pairingCode = ""
            step = .language
        } catch {
            problem = ConnectProblem.from(error, host: host)
            step = .connect
        }
    }

    public func chooseLanguage(_ language: ZoroLanguage) {
        guard step == .language else { return }
        self.language = language
        step = .voice
    }

    public func chooseVoice(_ voice: VoiceStyle) {
        guard step == .voice else { return }
        self.voice = voice
        step = showsShortcutGuide ? .shortcuts : .done
        if step == .done { persist() }
    }

    /// Done with (or skipping) the Action Button guide.
    public func finishShortcuts() {
        guard step == .shortcuts else { return }
        step = .done
        persist()
    }

    public func back() {
        switch step {
        case .connect: step = .welcome; problem = nil
        case .voice: step = .language
        case .shortcuts: step = .voice
        default: break
        }
    }

    private func persist() {
        var p = preferences.load()
        p.language = language
        p.voice = voice
        p.serverURL = pairedServerURL ?? p.serverURL
        p.onboardingComplete = true
        preferences.save(p)
    }
}

/// Reads the text inside the setup QR code. Only a `zoro://pair` link is accepted.
public enum SetupCodePayload {
    public static func parse(_ payload: String) -> Result<PairingLink, DeepLinkError> {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return .failure(.unsupportedScheme("")) }
        do {
            guard case .pair(let link) = try DeepLink.parse(url) else {
                return .failure(.invalidPairing("This QR code isn't a ZORO setup code."))
            }
            return .success(link)
        } catch {
            return .failure(error)
        }
    }
}
