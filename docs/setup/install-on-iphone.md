# Installing ZORO on your iPhone

Four ways to get ZORO onto your iPhone, easiest first. Each one says what it needs, how to do it,
what works and what doesn't, and how to keep it running.

**Status on 2026-11-13. Please read this first.**
- Nothing on this page has been tried from start to finish. The GitHub workflows
  (`.github/workflows/ci.yml`, `.github/workflows/ios-build.yml`) **have not run yet**.
- The iPhone and Mac app targets (`ios/project.yml`, `macos/project.yml`) were still being written
  when this page was written. Until they exist, routes B, C and D stop at "project.yml does not
  exist yet".
- The development Mac has no Xcode and only about 3 GB of free disk. Every Xcode step below has
  been checked against Apple's documentation, not run. The scripts' failure paths were run on that Mac.
- Facts from Apple, GitHub and the tool makers are linked under [Sources](#sources). They were read
  on 2026-11-13. Anything we did not confirm is marked **unverified**.

## Which route?

| Route | You need | Cost | Disk on your Mac | Time the first time | Keeps working for |
|---|---|---|---|---|---|
| **A. Web app** | Safari, and your ZORO server reachable over Tailscale | free | none | minutes | until you remove it |
| **B. Mac with Xcode, free Apple ID** | a Mac on macOS 15.6 or later, Xcode 26, a cable | free | a lot: Apple does not publish the installed size; we suggest 40 GB free (our estimate) | 1–2 hours (mostly downloads) | **7 days**, then rebuild |
| **C. Cloud build + sideloading tool** | a GitHub repository with Actions, a computer for Sideloadly, AltStore or SideStore, a free Apple ID | free (GitHub Actions minutes on macOS runners count against your plan) | under 1 GB | about 1 hour | **7 days**, then refresh in the tool |
| **D. Paid account + TestFlight** | Apple Developer Program, an App Store Connect API key, GitHub Actions | 99 USD a year (charged in local currency where available) | none (the cloud builds it) | an afternoon, plus Apple's enrolment wait | **90 days** per build |

For **this** Mac (macOS 15.6.1, about 3 GB free), route B isn't possible until a lot of disk is
freed. Use A today, then C. Move to D if 7-day renewals get tiring or you want Siri or push features.

## Route A: the web app (today)

ZORO's companion web app runs in Safari and can be added to the Home Screen. It follows the same
contract and security rules as the native apps. The native apps remain the main clients.

Setup, supported features and limits: see [`web/README.md`](../../web/README.md). That file was
being written by the web owner on 2026-11-13. If it isn't there yet, the web app isn't ready.

- **Works:** anything the web app's README lists as working.
- **Doesn't work:** native device features: HealthKit, HomeKit, AlarmKit, App Intents and Siri,
  widgets, Live Activities, Secure Enclave keys.
- **Renewal:** none.

## Route B: a Mac with Xcode and a free Apple ID

### What you need
- **macOS and Xcode.** Apple publishes which macOS each Xcode needs (Xcode system requirements):
  | Your macOS | Newest Xcode you can run | iOS SDK it includes |
  |---|---|---|
  | 15.6 – 26.1 (this Mac is 15.6.1) | Xcode 26.3 | iOS 26.2 |
  | 26.2 – 26.5 | Xcode 26.6 | iOS 26.5 |
  | 26.6 or later | Xcode 27.x | iOS 27.x |

  The Mac App Store only offers the newest Xcode (27.2 on 2026-11-13, "Requires macOS 26.6 or
  later", 3.1 GB download). Older versions are at <https://developer.apple.com/download/all/> (sign
  in with a free Apple ID). Since Xcode 26, the iOS platform is a separate download
  (`xcodebuild -downloadPlatform iOS`).
- **Disk:** Apple lists only the download size. Xcode, the iOS platform, and ZORO's DerivedData and
  archive need much more. Plan for **40 GB free**. That number is our estimate, not Apple's.
- **An Apple ID** added in Xcode > Settings > Accounts. Apple creates a *Personal Team* for it.
- **XcodeGen:** `brew install xcodegen`.
- **Your iPhone 17**, a cable, and Developer Mode turned on.
- **iOS version (unverified):** if the iPhone runs a newer iOS than your Xcode's SDK (for example
  iOS 27 with Xcode 26.3), Xcode has to prepare the device. Installing an app built with an older
  SDK normally works, but we couldn't test it.

### Free-account limits (Apple, "Choosing a membership")
- Up to **10 App IDs**, each expiring after **7 days**. ZORO uses one per target: the app, plus one
  for the widget extension if the app target has one.
- Up to **3 devices**, expiring after 7 days.
- Up to **3 apps per device**.
- Apps signed this way stop opening after **7 days**.

### Steps
1. Install Xcode (see the table above) and open it once. Then:
   `sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -runFirstLaunch && xcodebuild -downloadPlatform iOS`
2. In Xcode > Settings > Accounts, add your Apple ID. Note the team ID shown for "Personal Team".
3. Connect the iPhone, unlock it and tap **Trust**. Then run `xcrun devicectl manage pair`.
4. On the iPhone, turn on Settings > Privacy & Security > **Developer Mode**. The iPhone restarts;
   confirm when it asks. (The switch may only appear after Xcode or a sideloading tool has met the iPhone; unverified.)
5. In the repository:
   ```sh
   export ZORO_TEAM_ID=XXXXXXXXXX     # your team ID, 10 characters
   scripts/check_xcode.sh             # lists anything missing and prints the next step
   scripts/build_ios.sh               # generate, archive (automatic signing), export
   scripts/install_ios.sh --launch    # install with devicectl and open ZORO
   ```
   The build output goes to `~/Library/Caches/ZORO/ios-build`, outside iCloud Drive. Set
   `ZORO_BUILD_DIR` to use another folder.
6. If iOS asks, go to Settings > General > VPN & Device Management > your Apple ID > **Trust**.
7. Open ZORO and pair it with your server.

### What works and what doesn't
See the [feature table](#features-by-route). With a free account, Apple's capability table allows
App Groups, Background Modes, Data Protection, HealthKit, HomeKit, Keychain Sharing and Maps. It does
**not** allow Push Notifications, Time Sensitive Notifications, Siri (SiriKit), iCloud, Sign in with
Apple, Associated Domains, Wallet or Apple Pay.

### Renewal
Every 7 days, connect the iPhone and run `scripts/build_ios.sh && scripts/install_ios.sh`.
Installing over the existing app keeps its data and pairing. If you **delete** the expired app
instead, its keys are deleted too and you'll have to pair again.

## Route C: no Xcode: cloud build, signed with your Apple ID

GitHub's macOS runner builds an **unsigned** `ZORO-unsigned.ipa`. A sideloading tool on your
computer signs it with your own Apple ID and installs it. Your Mac never needs Xcode.

### What you need
- The repository on GitHub with Actions enabled. The `macos-26` runner provides Xcode 26.0.1 to
  26.6 (26.6 is the default, with the iOS 26.5 SDK), per the runner image readme of 2026-11-02.
- One of these tools. Each one asks for your Apple ID and signs with it. You can use a separate free
  Apple ID just for signing.
  | Tool | Runs on | Notes from the maker's docs |
  |---|---|---|
  | **Sideloadly** | macOS 10.12+, Windows 7+ (Windows needs the non-Store iTunes and iCloud) | free; says it supports "iOS 7 all the way up to iOS 27+"; free Apple IDs give 7-day apps; a background daemon can re-sign automatically |
  | **AltStore Classic** | AltServer on macOS 11+ (or Windows) | "only 3 sideloaded apps installed on a device at a time"; 10 App IDs, each lasting a week; refreshes through AltServer on the same Wi-Fi or over USB; since 2.3 (September 2026) a "Remote AltServer" option; needs Developer Mode on iOS 16+; may ask you to enable a Mail plug-in |
  | **SideStore** | iloader on Windows 8+, macOS 10.13+ or Linux, needed once to install SideStore | iOS 15+; the LocalDevVPN app (App Store) "is required to be turned on any time you wish to install, update, or refresh apps"; refreshes on the iPhone with no computer |

### Steps
1. On GitHub, go to **Actions > ios-build > Run workflow**. You can leave the Xcode version at 26.6.
   Pushing a tag such as `v0.1.0` also runs it.
2. When the run finishes, download the artifact **ZORO-unsigned-<run number>**. It contains
   `ZORO-unsigned.ipa`, and `ZORO-Mac-unsigned.zip` as a compile check. The run summary lists
   the version, bundle ID and sha256.
3. Install with your tool:
   - **Sideloadly:** connect the iPhone, drop the `.ipa` in, enter your Apple ID, click Start.
   - **AltStore:** install AltStore with AltServer (follow the maker's guide), then add the `.ipa` from
     AltStore's My Apps tab.
   - **SideStore:** install it with iloader, turn on LocalDevVPN, then add the `.ipa` from My Apps.
   The exact buttons in AltStore and SideStore were not in the pages we read: follow their current docs.
4. On the iPhone: Settings > General > VPN & Device Management > your Apple ID > **Trust**. Then turn
   on Developer Mode if iOS asks for it.
5. Open ZORO and pair it with your server.

### How the unsigned .ipa carries capabilities
`ios/release/package_unsigned_ipa.sh` ad-hoc signs the app and each extension with that target's
entitlements file: App Groups, HealthKit and HomeKit, with build variables filled in. It leaves out
keys tied to a team (the application identifier and keychain groups). Sideloading tools read these
entitlements and ask Apple for the ones a free account allows.
**Unverified:** whether each tool keeps every entitlement. If HealthKit or HomeKit shows
"unavailable" inside ZORO, the tool dropped that entitlement. Use route B or D for those features.

### Limits
- The same free-account limits as route B: 7 days, 10 App IDs a week, 3 apps per device.
  AltStore and SideStore are sideloaded apps themselves, so (our understanding) they take one of the three.
- Leave AltStore's experimental **"Randomize Bundle IDs"** setting off for ZORO. A new bundle ID
  makes iOS treat ZORO as a new app, with new storage and no keys, so you'd have to pair again. (This
  is our reading of how iOS app identity works, not something AltStore states.)
- Build artifacts are kept for 30 days. Run the workflow again to get a fresh one.

### Renewal
Every 7 days, refresh in the tool. AltStore and Sideloadly can refresh automatically while their
computer helper is reachable; SideStore refreshes on the iPhone with LocalDevVPN on. Refreshing
re-signs the installed app and keeps its data.

## Route D: paid developer account and TestFlight

### What you need
- **Apple Developer Program** membership: 99 USD a year, charged in local currency where available.
- In App Store Connect, an **app record** with ZORO's bundle ID (My Apps > + > New App).
- An **App Store Connect API key** (Users and Access > Integrations). Give it the Admin role so
  automatic signing can create certificates and profiles. **Unverified:** whether a lower role is enough.
- These GitHub repository secrets (Settings > Secrets and variables > Actions). They never go in the
  repository:
  `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` (`base64 -i AuthKey_XXXX.p8`).
- Since 2026-04-28, App Store Connect only accepts builds made with Xcode 26 or later and the iOS 26 SDK.

### Steps
1. Add the four secrets.
2. Go to **Actions > ios-build > Run workflow** and tick **Also upload to TestFlight**. Pushing a `v*`
   tag also uploads. The `signing-secrets` job skips the upload when any secret is missing.
3. The workflow archives with automatic signing through the API key. It sets the build number to the
   run number and uploads with `ExportOptions-AppStore.plist` set to `destination=upload`.
4. In App Store Connect > TestFlight, add yourself as an **internal tester** (up to 100 internal
   testers). Answer the export-compliance question if asked.
5. On the iPhone, install **TestFlight** from the App Store, accept the invitation, and install ZORO.

On a Mac with Xcode, `scripts/build_ios.sh app-store` builds the same thing locally. Upload it with
Xcode's Organizer.

### What works
Every capability ZORO's targets declare, including the ones a free account can't use (Siri
capability, push). Builds work for **90 days**. Release another build before then: TestFlight
updates in place and keeps data. With a paid team, route B also works, and its apps last longer than
7 days (Sideloadly's site says one year; not checked with Apple).

## Features by route

"Unverified" means it should work according to Apple's documentation, but nobody has tried it on a
device yet.

| ZORO feature | A. Web | B. Xcode, free ID | C. Sideloaded, free ID | D. TestFlight |
|---|---|---|---|---|
| Talk and type to ZORO, answers, cards, approvals list | see web/README.md | yes | yes | yes |
| On-device speech recognition and speech | see web/README.md | yes | yes | yes |
| Device keys in Secure Enclave, Face ID approvals | no | yes | yes (keys belong to the signing team: switching Apple ID or tool means pairing again) | yes |
| Fitness from Apple Health (HealthKit, read-only) | no | yes (Apple allows it for free accounts) | unverified (depends on the tool keeping the entitlement) | yes |
| Home scenes (HomeKit) | no | yes (Apple allows it for free accounts) | unverified (same) | yes |
| Alarms and timers (AlarmKit, iOS 26+) | no | yes with Xcode 26+ (Info.plist key only, no entitlement) | yes, unverified | yes |
| Widgets, Lock Screen control, Live Activity updated by the app | no | yes, unverified (extension uses one more App ID; App Groups allowed) | unverified | yes |
| Live Activity updated by push | no | no (no push on free accounts) | no | needs push, which ZORO doesn't use today |
| App Shortcuts, "Ask ZORO" through Siri, Action Button (App Intents) | no | unverified (Apple's App Intents docs list no entitlement; the Siri *capability* is SiriKit) | unverified | yes |
| Push and Time Sensitive notifications | no | no | no | available (ZORO doesn't use them today) |
| Apple Intelligence on-device model (English intent help) | no | when the iPhone supports it and it's on | same | same |
| Mac app | n/a | build with Xcode on the Mac | `ZORO-Mac-unsigned.zip` is a compile check only, unsigned | Mac TestFlight isn't set up |
| How long it works | always | 7 days | 7 days | 90 days per build |

## Troubleshooting

| What you see | What to do |
|---|---|
| "Untrusted Developer" when opening ZORO | Settings > General > VPN & Device Management > your Apple ID > Trust. |
| "Developer Mode required" | Settings > Privacy & Security > Developer Mode > On, restart, confirm. |
| ZORO stopped opening after a week | The 7-day signature expired. Refresh it in your tool (C) or rebuild and install (B). Don't delete the app. |
| "Maximum number of apps for free development profiles" | 3 apps per device on a free account. Remove another sideloaded app, or deactivate it in AltStore. |
| App ID limit reached | 10 App IDs per 7 days. Wait until older ones expire (AltStore: My Apps > View App IDs). |
| AltStore says "the provisioning profile is banned" | AltStore's 2.3.1 notes suggest "Randomize Bundle IDs". For ZORO that means pairing again (see route C). Try Sideloadly first. |
| `scripts/check_xcode.sh` says "Xcode is not installed" | Install Xcode, or use route C. |
| `scripts/install_ios.sh`: "not paired" or no device | Unlock the iPhone, tap Trust, run `xcrun devicectl manage pair`. |
| `scripts/install_ios.sh`: "unsigned" | That's the cloud build. Install it with a sideloading tool (C). |
| `scripts/build_ios.sh`: "No Accounts" or "No profiles for" | Add your Apple ID in Xcode > Settings > Accounts, connect the iPhone, run again. |
| `build_ios.sh` export fails with a free account | The script then points to the signed `.app` inside the archive. `scripts/install_ios.sh` installs that. |
| Workflow: "project.yml does not exist yet" | The app targets haven't landed in the repository yet. |
| Workflow: "Xcode X is not on this runner" | Run it again with a version from the list it prints. Runner images replace patch versions over time. |
| TestFlight upload: no matching app record | Create the app in App Store Connect with exactly ZORO's bundle ID. |
| HealthKit or HomeKit "unavailable" in a sideloaded build | The tool didn't keep that entitlement. Use route B or D for that feature. |

## Files

| File | Purpose |
|---|---|
| `scripts/check_xcode.sh` | macOS, Xcode and SDK, XcodeGen, free disk, signing identities, team ID, devices; prints the next step |
| `scripts/build_ios.sh [development\|ad-hoc\|app-store]` | generate, archive with automatic signing for `ZORO_TEAM_ID`, export an `.ipa` |
| `scripts/install_ios.sh [--list] [path] [--device X] [--launch]` | lists devices and installs with `devicectl` |
| `ios/release/ExportOptions-{Development,AdHoc,AppStore}.plist` | export options; the team ID is added from the environment at build time |
| `ios/release/PrivacyInfo.xcprivacy`, `PrivacyInfo-macOS.xcprivacy` | privacy manifests: no tracking, no collected data, UserDefaults `CA92.1` (and file timestamps `3B52.1` on the Mac) |
| `ios/release/package_unsigned_ipa.sh` | turns the unsigned archive into `ZORO-unsigned.ipa` |
| `ios/release/tests/*.sh` | tests for the packaging script and a check that the privacy manifest covers the code |
| `.github/workflows/ci.yml`, `.github/workflows/ios-build.yml` | CI and app builds (not run yet) |

## Sources

All read on 2026-11-13.
- Apple, Xcode system requirements: <https://developer.apple.com/xcode/system-requirements/>
- Apple, Xcode on the Mac App Store (version 27.2, 3.1 GB, requires macOS 26.6): <https://apps.apple.com/us/app/xcode/id497799835?mt=12>
- Apple, Upcoming requirements (Xcode 26 / iOS 26 SDK since 2026-04-28): <https://developer.apple.com/news/upcoming-requirements/>
- Apple, Choosing a membership (free-account limits): <https://developer.apple.com/support/compare-memberships/>
- Apple, Supported capabilities (iOS) ("Apple Developer" column = free account): <https://developer.apple.com/help/account/reference/supported-capabilities-ios>
- Apple, Enrollment (99 USD, local currency): <https://developer.apple.com/support/enrollment/>
- Apple, TestFlight overview (100 internal testers, 90 days): <https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/>
- Apple, Interacting with devices using the command line (devicectl): <https://developer.apple.com/documentation/xcode/interacting-with-devices-using-the-command-line>
- Apple, Describing use of required reason API, and the NSPrivacyAccessedAPIType reason codes: <https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api>
- Apple, Displaying live data with Live Activities (Info.plist key, push updates): <https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities>
- Apple, Scheduling an alarm with AlarmKit (`NSAlarmKitUsageDescription`): <https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit>
- GitHub, runner-images README (labels, Xcode policy) and the macOS 26 arm64 image readme (image 20261102.0473.1): <https://github.com/actions/runner-images>
- XcodeGen 2.46.0 release (checksum pinned in the workflow): <https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0>
- Sideloadly: <https://sideloadly.io/>
- AltStore Classic (install on macOS, App IDs, AltServer, release notes 2.3 / 2.3.1): <https://faq.altstore.io/>
- SideStore prerequisites: <https://docs.sidestore.io/docs/installation/prerequisites>
