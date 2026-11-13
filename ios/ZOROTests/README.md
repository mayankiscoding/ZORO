# ZOROTests and ZOROUITests: Xcode only

Status: **not compiled here**. `ZOROTests` uses Swift Testing hosted in the app and `ZOROUITests` uses XCUITest (UI tests
require XCTest); both need the iOS SDK inside Xcode, so they have never been built or run here.

- `ZOROTests` (unit, Swift Testing): launch builds every screen; the iPhone announces only iPhone and shared
  device tools; HomeKit is not announced without the entitlement flag; a `zoro://` link opens a section.
- `ZOROUITests` (XCUITest): launch, every section of the Spaces, Activity and You tabs, first run, and
  the approval sheet (decline). The app is launched with DEBUG-only arguments defined in
  `ios/ZORO/UITestSupport.swift`: an in-memory service graph against an unreachable server, so no
  keychain, network or permission prompt is involved.

Run them in Xcode with Product > Test (Cmd-U) on an iOS 26 simulator, or:

    xcodebuild test -project ios/ZORO.xcodeproj -scheme ZORO -destination 'platform=iOS Simulator,name=iPhone 17'

The same composition logic is covered on the host by Swift Testing:
`scripts/swiftpm.sh ZoroComposition test` and `scripts/swiftpm.sh macos test`.
Expect to adjust element queries (button labels) on the first run: they were written from the
SwiftUI source, not recorded from a running app.
