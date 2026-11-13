// UNVERIFIED-ON-HOST
#if os(iOS) && canImport(UIKit)
import UIKit

/// The iPhone's system handlers. Add `HealthQueryHandler`, `MusicControlHandler` and the photos handler
/// from their own packages with `NativeActionBroker.register`.
public enum SystemDeviceHandlers {
    @MainActor
    public static func make(
        presenter: @escaping @MainActor () -> UIViewController?, urlPolicy: URLPolicy = .standard
    ) -> [any DeviceActionHandler] {
        let opener = UIApplicationURLOpener()
        var handlers: [any DeviceActionHandler] = [
            CalendarHandler(store: EventKitCalendarStore()),
            ContactsHandler(store: SystemContactsStore()),
            NotificationHandler(scheduler: SystemNotificationScheduler()),
            LocationHandler(provider: SystemLocationProvider()),
            OpenURLHandler(opener: opener, policy: urlPolicy),
            ShortcutHandler(runner: URLShortcutRunner(opener: opener), successStatus: .workingIntegration),
            WhatsAppComposeHandler(opener: opener),
        ]
        #if canImport(AlarmKit)
        handlers.append(AlarmHandler(scheduler: AlarmKitScheduler()))
        #endif
        #if canImport(MessageUI)
        handlers.append(MessageComposeHandler(composer: SystemMessageComposer(presenter: presenter)))
        #endif
        #if canImport(HomeKit)
        handlers.append(HomeSceneHandler(runner: HomeKitSceneRunner()))
        #endif
        return handlers
    }
}
#endif
