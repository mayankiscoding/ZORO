# First Xcode build: ZORO on an iPhone 17 (and the Mac companion)

Status: **not compiled here.** The project files were generated with XcodeGen 2.46 and pass `plutil -lint`,
but no Xcode build has ever run. Everything shared by both apps (the `ZoroComposition` package and the Mac
app's sources) compiles and passes its tests on the Mac without Xcode; the iPhone-only files below compile
for the first time on your machine.

## 1. What you need

- A Mac with **Xcode 26** or later (iOS 26 SDK; the app's deployment target is iOS 26.0).
- An **iPhone 17** (any iPhone on iOS 26 works) and a USB-C cable.
- An Apple Account. A free "Personal Team" works for running on your own phone, with two limits noted in step 4.
- Your ZORO server running (`docs/setup/install-on-iphone.md` and the backend README), reachable from the phone over Tailscale.
- XcodeGen, if you change `ios/project.yml` (`brew install xcodegen`). The generated `ios/ZORO.xcodeproj` is already in the repo.

## 2. Open the project

1. In Finder, open the repository folder, then `ios`, and double-click `ZORO.xcodeproj`.
2. Wait until the "Package Dependencies" section in the left sidebar stops spinning: Xcode resolves the ten
   local Swift packages under `ios/Packages`. No package is downloaded from the internet.
3. At the top of the window, choose the **ZORO** scheme and your iPhone as the run destination.

If you edited `ios/project.yml`, regenerate first: `scripts/gen_xcode.sh` (from the repository root).

## 3. Prepare the iPhone

1. Connect the iPhone and tap **Trust** on the phone.
2. On the iPhone: Settings > Privacy & Security > **Developer Mode** > on, then restart when asked.

## 4. Team and signing

Do this for **each** of the two targets **ZORO** and **ZOROWidgets** (select the project in the sidebar, then the
target, then the **Signing & Capabilities** tab):

1. Tick **Automatically manage signing**.
2. Choose your **Team**.
3. Bundle identifiers are `app.zoro.ios` and `app.zoro.ios.widgets`. If Xcode says the identifier is taken,
   change the prefix in both (for example `com.yourname.zoro.ios` and `com.yourname.zoro.ios.widgets`; the
   widget's identifier must start with the app's).

## 5. Capabilities to enable (ZORO target)

The entitlements file `ios/ZORO/ZORO.entitlements` already lists them; Xcode must also enable them for your
App ID. In Signing & Capabilities click **+ Capability** for any that are missing:

| Capability | Why | If you can't enable it |
|---|---|---|
| HealthKit | Fitness answers, `device.health.query` | Remove it; Health shows "unavailable" |
| HomeKit | `ios.home.run_scene` | Remove it **and** set the build setting `ZORO_HOMEKIT_ENTITLED` to `NO` (iOS terminates an app that uses HomeKit without the entitlement; the app only announces the Home tool when this is `YES`) |
| Keychain Sharing (`app.zoro.shared`) | Device keys and identity | Required |
| Background Modes > Background processing | The overnight photo-index task | Optional |

Do **not** add Siri, Push Notifications or the Audio background mode: App Intents need no Siri capability,
and ZORO never listens in the background. A free Personal Team cannot use some capabilities (HealthKit
works; check HomeKit in your account), and its apps expire after 7 days.

## 6. Build and run

1. Press **Cmd-R**. The first build compiles every package for iOS and takes several minutes.
2. On first launch the phone may say "Untrusted Developer": Settings > General > VPN & Device Management >
   your account > **Trust**, then open ZORO again.
3. First run asks for your server address and pairing code (make one on the server with
   `python -m app.cli pairing-code`), or tap **Scan code** to scan the QR the setup script prints.

## 7. Files that have never been compiled: watch these on the first build

Each starts with `// UNVERIFIED-ON-HOST`. Errors here are expected to be small (a renamed symbol, an
availability annotation); fix them in place.

In this project (app and widget targets):

| File | What to check |
|---|---|
| `ios/ZORO/ZOROApp.swift` | `@main` app, `PhoneAppModel`; `SetupCodeScanner` comes from ZoroAppUI's iOS folder |
| `ios/ZORO/PhotoIndexingTask.swift` | `BGTaskScheduler.register` must run before launch finishes (it does, in `init`) |
| `ios/ZORO/AgentTaskActivityController.swift` | `Activity.request(attributes:content:pushType:)`; Live Activities must be on in Settings |
| `ios/ZORO/UITestSupport.swift` | DEBUG only |
| `ios/ZORO/ZOROShortcuts.swift` | Copied from `ios/Packages/ZoroApp/AppTargetTemplates`; the App Intents metadata processor validates the phrases at build time |
| `ios/ZOROWidgets/ZOROWidgetsBundle.swift` | `if #available` inside `@WidgetBundleBuilder` (iOS 26 SDK supports it) |
| `ios/ZOROWidgets/ZOROVoiceControl.swift` | `StaticControlConfiguration`, `ControlWidgetButton(action: StartVoiceIntent())` |
| `ios/ZOROWidgets/AgentTaskLiveActivity.swift` | `ActivityConfiguration` and Dynamic Island regions |
| `ios/ZOROWidgets/ZoroAlarmCountdownActivity.swift` | `AlarmAttributes<ZoroAlarmMetadata>`, `AlarmPresentationState.mode` cases; required for AlarmKit countdown timers |
| `ios/ZOROWidgets/Shared/ZoroTaskActivityAttributes.swift` | Compiled into both the app and the widget |
| `ios/ZOROTests/*`, `ios/ZOROUITests/*` | Swift Testing (unit) and XCUITest (UI); see the README beside them |

In the packages (iPhone branches): `ios/Packages/ZoroComposition/Sources/ZoroComposition/iOS/PhonePlatform.swift`
(device handlers, `MFMessageComposeViewController.canSendText()`), plus every file listed in
`docs/setup/unverified-ios-code.md` (AlarmKit, HomeKit, message composer, audio session, SpeechAnalyzer,
Foundation Models) and the iOS files of ZoroApp's intents (`docs/setup/siri.md`, "Not verified").

## 8. Assign the Action Button and the Lock Screen control

Action Button (iPhone 15 Pro and later, including iPhone 17):

1. Settings > **Action Button**. Swipe to **Shortcut**, tap **Choose a Shortcut**.
2. Under **ZORO**, pick **Talk to ZORO**. Pressing the button now opens ZORO listening.

Lock Screen control:

1. Touch and hold the Lock Screen, tap **Customize**, then **Lock Screen**.
2. Tap the control on the left or right at the bottom, remove it with **−**, tap **+**.
3. Search for **ZORO** and choose **Talk to ZORO**. Tap **Done**.

Control Center: open Control Center, touch and hold an empty area, **Add a Control**, search **ZORO**.

Siri: say "Talk to ZORO" or "Ask ZORO". The phrases appear in the Shortcuts app under ZORO after the first launch.

## 9. The Mac companion

1. Open `macos/ZOROMac.xcodeproj`, choose the **ZOROMac** scheme and **My Mac**.
2. Signing & Capabilities: tick automatic signing, choose your Team (bundle id `app.zoro.mac`). The
   entitlements file turns on App Sandbox with outgoing network, audio input, user-selected files,
   bookmarks, Photos, Contacts, Calendars, Location and Apple Events for Music and Spotify.
3. **Cmd-R**. ZORO appears in the menu bar and as a window. Pair it with its own pairing code: the Mac is
   a separate device with its own keys and its own tools (`mac.*`, `device.*`).
4. In ZORO > Settings (Cmd-,), add the folders ZORO may search.
5. Known risk to check: the Mac's AppleScript tools run `/usr/bin/osascript` as a child process. Inside the
   App Sandbox a child process inherits the sandbox, and macOS may refuse its Apple Events even with the
   temporary exception. If "Pause music" fails in the signed app, report it; the fix is to run the
   allowlisted scripts in-process with `NSAppleScript` (a change in ZoroDevice).

Without Xcode, the same Mac sources build and self-check from the terminal:
`scripts/swiftpm.sh macos build`, then run the built `ZOROMac --smoke-test docs/design/snapshots`.
