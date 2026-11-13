// Ready file for the app targets (ios/ZORO and macos/ZOROMac). Not compiled in this package: the
// provider is kept in the app target. Add AppShortcuts.xcstrings (Hindi phrases) and
// Localizable.xcstrings (Hindi titles and prompts) from this folder to the same target.
//
// The phrases mirror ZoroShortcutPhrases.all in ZoroAppUI; RegistryIntentHandoffTests parses this file
// and fails when they drift. Rules checked by the tests: every phrase contains \(.applicationName)
// exactly once, at most one parameter per phrase (AppEnum parameters only), at most 10 shortcuts,
// short titles of 24 characters or fewer.
//
// Checked against Apple's documentation: AppShortcutsProvider (iOS 16 / macOS 13),
// AppShortcut.init(intent:phrases:shortTitle:systemImageName:) (iOS 17 / macOS 14),
// AppShortcutsProvider.updateAppShortcutParameters() (iOS 16 / macOS 13),
// AppIntentsPackage.includedPackages (iOS 17 / macOS 14).
import AppIntents
import ZoroAppUI

struct ZOROShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskZoroIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) something",
                "\(.applicationName) se poochho",
                "\(.applicationName) se kuch poochna hai",
            ],
            shortTitle: "Ask ZORO",
            systemImageName: "circle.circle")
        AppShortcut(
            intent: StartVoiceIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start \(.applicationName) voice",
                "\(.applicationName) se baat karo",
            ],
            shortTitle: "Talk to ZORO",
            systemImageName: "waveform")
        AppShortcut(
            intent: CheckSpendingIntent(),
            phrases: [
                "Ask \(.applicationName) how much I spent \(\.$period)",
                "Ask \(.applicationName) how much I spent on \(\.$category)",
                "Check my spending in \(.applicationName)",
                "\(.applicationName) se poochho \(\.$period) kitna kharch hua",
            ],
            shortTitle: "Check spending",
            systemImageName: "indianrupeesign")
        AppShortcut(
            intent: CompareBasketIntent(),
            phrases: [
                "Compare my basket with \(.applicationName)",
                "Ask \(.applicationName) to compare my basket",
                "\(.applicationName) basket compare karo",
            ],
            shortTitle: "Compare basket",
            systemImageName: "basket")
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: [
                "Play music with \(.applicationName)",
                "Ask \(.applicationName) to play something",
                "\(.applicationName) gaana chalao",
            ],
            shortTitle: "Play music",
            systemImageName: "music.note")
        AppShortcut(
            intent: RememberThisIntent(),
            phrases: [
                "Ask \(.applicationName) to remember something",
                "Remember this with \(.applicationName)",
                "\(.applicationName) yaad rakhna",
            ],
            shortTitle: "Remember this",
            systemImageName: "brain")
        AppShortcut(
            intent: FindPhotoIntent(),
            phrases: [
                "Find a photo with \(.applicationName)",
                "Search photos in \(.applicationName)",
                "\(.applicationName) photo dhoondo",
            ],
            shortTitle: "Find a photo",
            systemImageName: "photo.on.rectangle")
        AppShortcut(
            intent: SwitchToPrivateModeIntent(),
            phrases: [
                "Turn on private mode in \(.applicationName)",
                "Switch \(.applicationName) to private mode",
                "\(.applicationName) private mode on karo",
            ],
            shortTitle: "Private mode",
            systemImageName: "lock.shield")
        AppShortcut(
            intent: OpenSectionIntent(),
            phrases: [
                "Open \(\.$section) in \(.applicationName)",
                "Show \(.applicationName) \(\.$section)",
                "\(.applicationName) mein \(\.$section) kholo",
            ],
            shortTitle: "Open a section",
            systemImageName: "square.grid.2x2")
    }
}

/// Includes the intents, entities and queries declared in the ZoroAppUI package.
struct ZOROAppIntents: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [ZoroAppIntentsPackage.self] }
}
