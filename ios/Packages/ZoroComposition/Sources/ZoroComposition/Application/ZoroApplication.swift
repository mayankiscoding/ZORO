import AgentClient
import CommerceSupport
import ConversationManager
import FitnessFeature
import Foundation
import ModelRouter
import NativeActionBroker
import Observation
import PermissionManager
import PhotoIntelligence
import SecurityManager
import SystemFeatures
import VoiceInterface
import ZoroAppUI
import ZoroCore
import ZoroDesign

/// The composition root of both apps. `make` builds the whole service graph from concrete
/// implementations, wires the shell, registers every screen and card, and the lifecycle methods keep
/// the device channel, permissions and local data in step with the app's foreground state.
@MainActor
@Observable
public final class ZoroApplication {
    public let configuration: CompositionConfiguration
    public let shell: ZoroAppShell
    /// Injected into SwiftUI with `\.zoroServices`.
    public let services: ZoroServices
    public let system: SystemFeaturesContainer
    public let permissions: PermissionCenter
    public let inbox: ApprovalInbox
    public let fileUploader: APIFileUploader
    /// The client context every turn carries (platform, locale, time zone).
    public let clientContext: ClientContext
    /// Device-channel state for the Mac's status line and tests.
    public private(set) var channelState: DeviceChannelState = .idle

    @ObservationIgnored public let api: ServerBoundAPI
    @ObservationIgnored public let deviceActions: CompositeDeviceActionExecutor
    @ObservationIgnored public let photoService: PhotoIntelligenceService?
    @ObservationIgnored let identity: any DeviceIdentityProviding
    @ObservationIgnored let foreground: ForegroundWork
    @ObservationIgnored let addressStore: ServerAddressStore
    @ObservationIgnored private(set) var registry: DeviceToolRegistry
    @ObservationIgnored private var channel: DeviceChannel?
    @ObservationIgnored private var channelWatcher: Task<Void, Never>?
    #if os(macOS)
    /// Folders the owner approved for file search, kept as security-scoped bookmarks.
    @ObservationIgnored public let folders: SecurityScopedFolderStore
    #endif

    // MARK: - Building

    public static func make(_ configuration: CompositionConfiguration) async -> ZoroApplication {
        // The bundled Devanagari serif (ZoroDesign); idempotent, falls back to the system face.
        ZoroFonts.register()
        let defaults = configuration.defaults
        let addressStore = ServerAddressStore(defaults: defaults)
        let shellPreferences = ZoroAppUI.UserDefaultsPreferences(defaults: defaults)

        // Identity and keys.
        let items: any SecureItemStoring
        let keys: any KeyStoring
        switch configuration.storage {
        case .keychain(let service, let group):
            items = KeychainStore(service: service, accessGroup: group)
            keys = DeviceKeyStores.makeDefault(items: KeychainStore(service: "app.zoro.keys", accessGroup: group))
        case .inMemory:
            items = InMemorySecureItemStore()
            keys = InMemoryKeyStore()
        }
        let identity = DeviceIdentity(keys: keys, items: items)
        let endpoint = ServerEndpoint(configuration.serverURL ?? addressStore.load() ?? shellPreferences.load().serverURL)
        let api = ServerBoundAPI(endpoint: endpoint, identity: identity, transport: configuration.transport)
        let client = ClientContext(
            platform: configuration.platform, locale: Locale.current.identifier(.bcp47),
            timezone: TimeZone.current.identifier)

        // Device actions: the broker with this platform's handlers, plus photo search.
        let photoService = Self.makePhotoService(configuration)
        #if os(macOS)
        let folders = SecurityScopedFolderStore(
            storage: configuration.storage == .inMemory ? InMemoryBookmarkStorage() : UserDefaultsBookmarkStorage(defaults: defaults))
        let handlers = PlatformDeviceHandlers.make(folders: folders)
        #else
        let handlers = PlatformDeviceHandlers.make()
        #endif
        let broker = NativeActionBroker(platform: configuration.platform, handlers: handlers, confirmer: nil)
        var parts: [any DeviceActionExecuting] = [broker]
        if let photoService { parts.append(PhotoSearchActionHandler(service: photoService)) }
        let deviceActions = CompositeDeviceActionExecutor(parts)

        // On-device intent help and the capability registry.
        let assist = SystemIntentAssist.make()
        let modelAvailable = await assist?.isAvailable() ?? false
        let registry = DeviceToolRegistry(environment: .current(
            canComposeMessages: PlatformHooks.canComposeMessages(),
            homeKitScenesEnabled: configuration.homeKitEntitled && configuration.platform == .ios,
            onDeviceLanguageModelAvailable: modelAvailable))

        let health = PlatformHooks.health()
        let music = AppleMusicServices.make()
        let voice = SystemVoice.makeSession(api: api, client: client, webSockets: configuration.webSockets)
        let biometrics = BiometricAuthenticator()
        var services = ZoroServices(
            api: api, identity: identity, keys: keys, biometrics: biometrics, approvals: UnavailableService(), voice: voice,
            deviceActions: deviceActions, photos: photoService.map { $0 as any PhotoSearching } ?? UnavailableService(),
            health: health, music: music, intents: LocalIntentClassifier(assist: assist))

        // The shell, with pairing that records the server address the moment pairing succeeds.
        let store = try? await ConversationStore.open(
            at: configuration.dataDirectory.appendingPathComponent("conversations.sqlite"), keys: keys)
        let pairing = EndpointRecordingPairing(
            base: IdentityServerPairing(
                keys: keys, identity: identity, makeAuthAPI: { api.authClient(for: $0) }, deviceName: configuration.deviceName,
                platform: configuration.platform, capabilities: registry.supportedTools(permissions: [:]),
                appVersion: configuration.appVersion),
            endpoint: endpoint, store: addressStore)
        let paired: Bool
        if configuration.assumePaired {
            paired = endpoint.current != nil
        } else {
            paired = await identity.deviceId() != nil && endpoint.current != nil
        }
        let shell = ZoroAppShell.make(
            services: services, clientContext: client, store: store, pairing: pairing, preferences: shellPreferences,
            context: ShoppingHomeContext(api: api), isPaired: paired)

        // Approvals outside a turn use the same sheet as turn approvals.
        let approvals = ApprovalCoordinator(identity: identity, biometrics: biometrics, presenter: shell.approvals)
        services.approvals = approvals
        let inbox = ApprovalInbox(api: api, approvals: approvals)

        let permissions = PermissionCenter.system()
        let registryRows: @Sendable () async -> [Capability] = { [registry] in
            let statuses = await MainActor.run { permissions.statuses }
            return registry.capabilities(permissions: statuses)
        }
        let system = SystemFeaturesContainer(
            services: services, conversations: shell.home.conversation, deviceRegistry: RegistryCapabilities(rows: registryRows),
            localHistory: store, serverAddress: EndpointAddress(endpoint: endpoint),
            quickActions: DeviceQuickActions.systemActions(for: configuration.platform),
            onPair: { [weak shell] in shell?.pairAgain() },
            onContinueConversation: { [weak shell] id in
                guard let shell else { return }
                shell.navigation.open(.home)
                Task { await shell.openConversation(id: id) }
            })

        Registrations.registerSections(in: shell.sections, shell: shell, system: system, inbox: inbox)
        Registrations.registerCards(in: shell.cards)

        let foreground = ForegroundWork(
            fitness: configuration.platform == .ios ? HealthFitnessSync(health: health, server: FitnessAPIClient(api: api)) : nil,
            health: health, photos: photoService)

        #if os(macOS)
        return ZoroApplication(
            configuration: configuration, shell: shell, services: services, system: system, permissions: permissions,
            inbox: inbox, api: api, deviceActions: deviceActions, photoService: photoService, identity: identity,
            foreground: foreground, addressStore: addressStore, registry: registry, clientContext: client, folders: folders)
        #else
        return ZoroApplication(
            configuration: configuration, shell: shell, services: services, system: system, permissions: permissions,
            inbox: inbox, api: api, deviceActions: deviceActions, photoService: photoService, identity: identity,
            foreground: foreground, addressStore: addressStore, registry: registry, clientContext: client)
        #endif
    }

    #if os(macOS)
    private init(
        configuration: CompositionConfiguration, shell: ZoroAppShell, services: ZoroServices, system: SystemFeaturesContainer,
        permissions: PermissionCenter, inbox: ApprovalInbox, api: ServerBoundAPI, deviceActions: CompositeDeviceActionExecutor,
        photoService: PhotoIntelligenceService?, identity: any DeviceIdentityProviding, foreground: ForegroundWork,
        addressStore: ServerAddressStore, registry: DeviceToolRegistry, clientContext: ClientContext,
        folders: SecurityScopedFolderStore
    ) {
        self.folders = folders
        self.configuration = configuration
        self.shell = shell
        self.services = services
        self.system = system
        self.permissions = permissions
        self.inbox = inbox
        self.api = api
        self.deviceActions = deviceActions
        self.photoService = photoService
        self.identity = identity
        self.foreground = foreground
        self.addressStore = addressStore
        self.registry = registry
        self.fileUploader = APIFileUploader(api: api)
        self.clientContext = clientContext
    }
    #else
    private init(
        configuration: CompositionConfiguration, shell: ZoroAppShell, services: ZoroServices, system: SystemFeaturesContainer,
        permissions: PermissionCenter, inbox: ApprovalInbox, api: ServerBoundAPI, deviceActions: CompositeDeviceActionExecutor,
        photoService: PhotoIntelligenceService?, identity: any DeviceIdentityProviding, foreground: ForegroundWork,
        addressStore: ServerAddressStore, registry: DeviceToolRegistry, clientContext: ClientContext
    ) {
        self.configuration = configuration
        self.shell = shell
        self.services = services
        self.system = system
        self.permissions = permissions
        self.inbox = inbox
        self.api = api
        self.deviceActions = deviceActions
        self.photoService = photoService
        self.identity = identity
        self.foreground = foreground
        self.addressStore = addressStore
        self.registry = registry
        self.fileUploader = APIFileUploader(api: api)
        self.clientContext = clientContext
    }
    #endif

    private static func makePhotoService(_ configuration: CompositionConfiguration) -> PhotoIntelligenceService? {
        let store: PhotoIndexStore?
        if configuration.storage == .inMemory {
            store = try? PhotoIndexStore()
        } else {
            store = try? PhotoIndexStore(fileURL: configuration.dataDirectory.appendingPathComponent("photo-index.sqlite"))
        }
        guard let store else { return nil }
        return PhotoIntelligenceService(
            library: PhotoKitLibrary(), analyzer: VisionImageAnalyzer(), sampler: CoreGraphicsPixelSampler(),
            power: SystemPowerMonitor(), store: store)
    }

    // MARK: - Lifecycle

    /// The app became active: re-read permissions (the owner may have changed Settings), refresh what
    /// the device announces, open the channel, load waiting approvals and run the polite foreground work.
    public func becameActive() async {
        await permissions.refreshAll()
        guard shell.isPaired else { return }
        await ZoroIntentDiscovery.refresh()
        await startChannelIfNeeded()
        _ = await channel?.refreshCapabilities()
        await inbox.refresh()
        await foreground.appBecameActive()
    }

    /// The app left the foreground: a voice session ends (ZORO never listens in the background), photo
    /// indexing stops, and on iPhone the channel closes until the app is active again.
    public func movedToBackground() async {
        await services.voice.stop()
        await foreground.appMovedToBackground()
        if !configuration.keepsChannelInBackground { await stopChannel() }
    }

    /// Pairing finished (or the owner chose to pair again).
    public func pairingChanged() async {
        if shell.isPaired {
            if api.endpoint.current == nil, let saved = addressStore.load() { api.endpoint.set(saved) }
            await becameActive()
        } else {
            await stopChannel()
            await api.signOut()
            await ZoroIntentDiscovery.removeAll()
        }
    }

    /// Tool names announced in the channel hello with the current permissions.
    public func helloTools() async -> [String] {
        registry.helloTools(permissions: permissions.statuses, registered: await deviceActions.supportedTools)
    }

    /// Gives Siri, Shortcuts, Spotlight and the Action Button the real services (the entry point the
    /// intents package documents in docs/setup/siri.md). Call once, right after `make`.
    public func registerIntents(updateShortcutParameters: @escaping @Sendable () -> Void = {}) {
        ZoroIntents.register(
            services: services, clientContext: clientContext,
            preferences: ZoroAppUI.UserDefaultsPreferences(defaults: configuration.defaults),
            updateShortcutParameters: updateShortcutParameters)
    }

    @discardableResult
    public func handle(_ url: URL) -> Bool { shell.handle(url) }

    public func continueActivity(_ activity: NSUserActivity) { shell.continueActivity(activity) }

    // MARK: - Device channel

    private func startChannelIfNeeded() async {
        guard configuration.startsDeviceChannel, channel == nil, let url = api.endpoint.current, let tokens = try? api.tokens() else { return }
        let deviceId = await identity.deviceId()
        guard channel == nil else { return }
        let inbox = self.inbox
        let executor = ConfirmingDeviceActionExecutor(base: deviceActions, confirmer: shell.confirmations)
        let channel = DeviceChannel(
            baseURL: url, connector: configuration.webSockets, tokens: tokens, executor: executor, deviceId: deviceId,
            onApprovalRequired: { request in await inbox.receive(request) },
            capabilities: { [weak self] in await self?.helloTools() ?? [] })
        self.channel = channel
        channelWatcher = Task { [weak self] in
            for await state in channel.states {
                self?.channelState = state
            }
        }
        Task { await channel.start() }
    }

    private func stopChannel() async {
        let current = channel
        channel = nil
        channelWatcher?.cancel()
        channelWatcher = nil
        await current?.stop()
        channelState = .stopped
    }
}
