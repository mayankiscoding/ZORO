// UNVERIFIED-ON-HOST
// iPhone-only composition: device handlers, Health, the message-composer check and the limited-library
// picker. Thin: every call is a public initialiser from ZoroDevice or ZoroLife, or one UIKit/MessageUI
// call checked against Apple's documentation (MFMessageComposeViewController.canSendText(),
// UIApplication.connectedScenes, UIWindowScene.windows, UIWindow.isKeyWindow,
// UIViewController.presentedViewController).
#if os(iOS)
import Foundation
import HealthIntegration
import MusicIntegration
import NativeActionBroker
import PhotosFeature
import UIKit
import ZoroCore
#if canImport(MessageUI)
import MessageUI
#endif

enum PlatformHooks {
    static func health() -> any HealthDataProviding { HealthService(store: HealthKitSampleStore()) }

    static func canComposeMessages() -> Bool {
        #if canImport(MessageUI)
        return MFMessageComposeViewController.canSendText()
        #else
        return false
        #endif
    }

    static func limitedLibraryPresenter() -> any LimitedLibraryPresenting { PhotoKitLimitedLibraryPresenter() }
}

/// The iPhone's device handlers: the system set (with AlarmKit, the message composer and HomeKit where
/// the SDK has them), the health query and music control (Apple Music through MusicKit, Spotify by
/// opening its app). The photo search executor is added by the composition root.
enum PlatformDeviceHandlers {
    @MainActor
    static func make() -> [any DeviceActionHandler] {
        var handlers = SystemDeviceHandlers.make(presenter: { topViewController() })
        handlers.append(HealthQueryHandler(store: HealthKitSampleStore()))
        let backend = MusicKitBackend()
        let probe = MusicAvailabilityProbe(
            appleMusic: backend, spotifyInstalled: { await MainActor.run { SpotifyAppPresence.isInstalled() } })
        handlers.append(MusicControlHandler(
            controls: [
                AppleMusicKitControl(controller: AppleMusicController(backend: backend)),
                SpotifyHandoffControl(opener: UIApplicationURLOpener()),
            ],
            availability: { await probe.current() }))
        return handlers
    }

    @MainActor
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
#endif
