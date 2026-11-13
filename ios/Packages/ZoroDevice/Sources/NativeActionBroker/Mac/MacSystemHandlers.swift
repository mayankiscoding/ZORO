#if os(macOS)
import Foundation

/// The Mac's system handlers. Add `HealthQueryHandler` (not on Mac), `MusicControlHandler` and the
/// photos handler from their own packages with `NativeActionBroker.register`.
public enum SystemDeviceHandlers {
    @MainActor
    public static func make(
        folders: any ApprovedFoldersProviding, urlPolicy: URLPolicy = .standard,
        appleScript: any AppleScriptRunning = OSAScriptRunner()
    ) -> [any DeviceActionHandler] {
        let opener = WorkspaceURLOpener()
        return [
            CalendarHandler(store: EventKitCalendarStore()),
            ContactsHandler(store: SystemContactsStore()),
            NotificationHandler(scheduler: SystemNotificationScheduler()),
            LocationHandler(provider: SystemLocationProvider()),
            OpenURLHandler(opener: opener, policy: urlPolicy),
            ShortcutHandler(runner: ProcessShortcutRunner()),
            WhatsAppComposeHandler(opener: opener),
            AppleScriptHandler(runner: appleScript),
            FileHandler(folders: folders, searcher: SpotlightFileSearcher(), opener: opener),
        ]
    }
}
#endif
