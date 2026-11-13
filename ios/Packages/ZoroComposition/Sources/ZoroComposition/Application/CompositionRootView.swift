import CommerceSupport
import PhotosFeature
import SwiftUI
import ZoroAppUI
import ZoroCore
import ZoroDesign

/// The app's root view: the shell's root with every environment value the feature packages read,
/// and the lifecycle hooks (foreground, background, pairing changes).
public struct CompositionRootView: View {
    let app: ZoroApplication
    let scanner: ((@escaping (PairingLink) -> Void) -> AnyView)?
    let openSystemSettings: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    public init(
        app: ZoroApplication, scanner: ((@escaping (PairingLink) -> Void) -> AnyView)? = nil,
        openSystemSettings: @escaping () -> Void = {}
    ) {
        self.app = app
        self.scanner = scanner
        self.openSystemSettings = openSystemSettings
    }

    public var body: some View {
        ZoroRootView(shell: app.shell, scanner: scanner, openSystemSettings: openSystemSettings)
            .zoroEnvironment(app)
            .onChange(of: app.shell.isPaired) { Task { await app.pairingChanged() } }
            // A long Siri answer continues in the app: open that conversation.
            .onChange(of: app.shell.inbox.pendingConversationId, initial: true) { _, id in
                guard id != nil, let id = app.shell.inbox.takeConversation() else { return }
                Task { await app.shell.openConversation(id: id) }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active: Task { await app.becameActive() }
                case .background: Task { await app.movedToBackground() }
                default: break
                }
            }
    }
}

extension View {
    /// Every environment value the feature packages read: services, the file uploader, the photo
    /// thumbnail provider, the limited-library picker (iPhone) and the owner's appearance choice.
    public func zoroEnvironment(_ app: ZoroApplication) -> some View {
        zoroServices(app.services)
            .environment(\.commerceFileUploader, app.fileUploader)
            .environment(\.photoThumbnailProvider, ThumbnailProviders.make())
            .environment(\.limitedLibraryPresenter, PlatformHooks.limitedLibraryPresenter())
            .preferredColorScheme(app.system.preferredColorScheme)
    }
}

/// Real thumbnails by Photos local identifier.
enum ThumbnailProviders {
    static func make() -> any PhotoThumbnailProviding {
        #if canImport(Photos)
        PhotoKitThumbnailProvider()
        #else
        UnavailableThumbnailProvider()
        #endif
    }
}

/// The view for a launch that is still building the service graph (opening the encrypted store and
/// reading the device identity takes a moment).
public struct CompositionLaunchView: View {
    public init() {}
    public var body: some View {
        ZoroStateView(.loading, message: "Opening ZORO. Your conversations and keys are being unlocked on this device.")
            .padding(ZoroSpace.l.value)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ZoroNeutral.background)
    }
}
