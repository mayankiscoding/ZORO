import AgentClient
import Foundation
import ZoroCore

/// What differs between the iPhone app, the Mac app, tests and the smoke test.
public struct CompositionConfiguration: Sendable {
    public enum Storage: Sendable, Equatable {
        /// Keys in the Secure Enclave (Keychain fallback), device id and secrets in the Keychain.
        case keychain(service: String, accessGroup: String?)
        /// Nothing persisted: tests and `--smoke-test`.
        case inMemory
    }

    public var platform: DevicePlatform
    public var storage: Storage
    /// Conversation store and photo index live here (Application Support in the apps).
    public var dataDirectory: URL
    /// Overrides the paired address (smoke test); nil reads the address saved at pairing.
    public var serverURL: URL?
    /// Treat the device as paired without reading the identity (smoke test only).
    public var assumePaired: Bool
    public var deviceName: String
    public var appVersion: String?
    /// True only when the app is signed with `com.apple.developer.homekit`; without it iOS terminates
    /// the app on first HomeKit use, so `ios.home.run_scene` is announced only with the entitlement.
    public var homeKitEntitled: Bool
    /// The Mac companion keeps its channel open in the background (the iPhone hands it tasks);
    /// the iPhone closes it when it leaves the foreground.
    public var keepsChannelInBackground: Bool
    /// False in tests: no WebSocket is opened.
    public var startsDeviceChannel: Bool
    public var transport: any HTTPTransport
    public var webSockets: any WebSocketConnecting
    /// `UserDefaults` suite for preferences (nil = standard).
    public var defaultsSuite: String?

    public init(
        platform: DevicePlatform, storage: Storage, dataDirectory: URL, serverURL: URL? = nil, assumePaired: Bool = false,
        deviceName: String, appVersion: String? = nil, homeKitEntitled: Bool = false, keepsChannelInBackground: Bool = false,
        startsDeviceChannel: Bool = true, transport: any HTTPTransport = URLSessionTransport(),
        webSockets: any WebSocketConnecting = URLSessionWebSocketConnector(), defaultsSuite: String? = nil
    ) {
        self.platform = platform
        self.storage = storage
        self.dataDirectory = dataDirectory
        self.serverURL = serverURL
        self.assumePaired = assumePaired
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.homeKitEntitled = homeKitEntitled
        self.keepsChannelInBackground = keepsChannelInBackground
        self.startsDeviceChannel = startsDeviceChannel
        self.transport = transport
        self.webSockets = webSockets
        self.defaultsSuite = defaultsSuite
    }

    /// The shipping configuration for this platform.
    public static func standard(
        deviceName: String, appVersion: String?, homeKitEntitled: Bool, keychainAccessGroup: String? = nil
    ) -> CompositionConfiguration {
        #if os(iOS)
        let platform = DevicePlatform.ios
        let keepAlive = false
        #else
        let platform = DevicePlatform.macos
        let keepAlive = true
        #endif
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return CompositionConfiguration(
            platform: platform, storage: .keychain(service: "app.zoro.secure", accessGroup: keychainAccessGroup),
            dataDirectory: support.appendingPathComponent("zoro", isDirectory: true), deviceName: deviceName,
            appVersion: appVersion, homeKitEntitled: homeKitEntitled && platform == .ios, keepsChannelInBackground: keepAlive)
    }

    var defaults: UserDefaults {
        defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }
}
