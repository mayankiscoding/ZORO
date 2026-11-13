# Siri, Shortcuts, the Action Button and Spotlight

Status: **compiled and unit-tested on the macOS host** (intents, turn runner, wording, phrase catalogue,
entity queries: `scripts/swiftpm.sh ZoroApp test`). **Not yet run on a device or under Xcode**: Siri, the
App Shortcuts metadata, Spotlight indexing and the iOS 26+ code paths need the first Xcode build (see
"Not verified" at the end).

## What this is, plainly

An app cannot replace Siri or its wake word, and ZORO does not try to. "Hey Siri" is Apple's, it stays
Apple's, and ZORO never listens in the background. The supported way to be hands-free is to let Siri
hand a request to ZORO through **App Intents**: you say a phrase that names ZORO, Siri passes the request
to the app, ZORO runs a normal turn on your own server, and Siri speaks the answer. For most questions
the app never comes to the front.

## What to say

Every phrase contains the app's name. Siri can fill **one** value from the sentence (a period, a category
or a section); anything else it asks for. "Ask ZORO" then asks "What should I ask ZORO?", and you say the
rest. Siri cannot capture free text in the same breath as the app name; that is an Apple limit.

| Action | English | हिन्दी | Hinglish |
|---|---|---|---|
| Ask anything | "Hey Siri, ask ZORO" → "how much did I spend on food last month" | "Hey Siri, ZORO से पूछें" | "Hey Siri, ZORO se poochho" |
| Spending | "Ask ZORO how much I spent last month" · "Ask ZORO how much I spent on food" (then Siri asks for the period) · "Check my spending in ZORO" | "ZORO से पूछें पिछले महीने कितना खर्च हुआ" · "ZORO से पूछें खाने पर कितना खर्च हुआ" | "ZORO se poochho pichhle mahine kitna kharch hua" |
| Compare basket | "Compare my basket with ZORO" | "ZORO से मेरी बास्केट की तुलना करें" | "ZORO basket compare karo" |
| Play music | "Play music with ZORO" → "Kishore Kumar on my Mac" | "ZORO से गाना चलाएँ" | "ZORO gaana chalao" |
| Remember | "Ask ZORO to remember something" | "ZORO से कुछ याद रखने को कहें" | "ZORO yaad rakhna" |
| Find a photo | "Find a photo with ZORO" (opens the app on the results) | "ZORO से फ़ोटो ढूँढें" | "ZORO photo dhoondo" |
| Private mode | "Turn on private mode in ZORO" | "ZORO में प्राइवेट मोड चालू करें" | "ZORO private mode on karo" |
| Live voice | "Talk to ZORO" (opens Live Voice) | "ZORO से बात करें" | "ZORO se baat karo" |
| A section | "Open Finance in ZORO" | "ZORO में Finance खोलें" | "ZORO mein Finance kholo" |

English and Hinglish phrases are recognised when Siri's language is English (India); the Hindi phrases
when Siri's language is Hindi. The full list, with the counts Apple allows, is
`ZoroShortcutPhrases.all` in `ios/Packages/ZoroApp/Sources/ZoroAppUI/Intents/ZoroShortcutPhrases.swift`
and the Hindi catalogue is `AppTargetTemplates/AppShortcuts.xcstrings`. The app's Settings can show the
tip "Say: “Hey Siri, ask ZORO …”" (`ZoroSiriTip`, or Apple's `SiriTipView` on iPhone).

## Action Button, Lock Screen and Control Center

- **Action Button** (iPhone 15 Pro and later): Settings → Action Button → Shortcut → ZORO → *Talk to
  ZORO*. One press opens Live Voice and starts listening. Choosing *Ask ZORO* instead makes Siri ask
  "What should I ask ZORO?" and answer without opening the app.
- **Lock Screen / Control Center**: long-press the Lock Screen → Customize → Lock Screen → add a control →
  ZORO → *Talk to ZORO* (the widget extension's `ZOROVoiceControl`). Control Center works the same way.
  Opening the app from a locked phone asks for Face ID first; that is iOS behaviour.
- **Spotlight and Shortcuts**: every action above appears in the Shortcuts app under ZORO and in
  Spotlight. Sections and the titles of recent conversations are indexed in Spotlight (titles only,
  never message text); a result opens that conversation in the app.

## What Siri hands to ZORO, and what stays in the app

| Handed to ZORO by Siri | Answered by Siri | Always in the app |
|---|---|---|
| The words of the request, as Siri transcribed them, plus the period / category / section values | The reply text (the spoken dialog) and a snippet: the reply and the first card's title with up to two lines | Approvals of any kind (signed on this device, with Face ID when the action needs it) |
| | | Device steps: alarms, the message composer, Home scenes, playback that needs the app |
| | | Long answers (over 300 characters: Siri reads the first sentence and says the rest is in ZORO) |
| | | Answers with *secret* data, which Siri never sees |
| | | Turning cloud intelligence back on (Siri can only switch **to** private mode) |

How a request runs: the intent sends one turn to your server (marked `surface: siri`, voice modality, your
language as the hint) and waits at most 20 seconds. If the turn finishes, Siri speaks the reply. If the
server suspends it for an approval or a device action, ZORO **cancels that turn on the server**, Siri says
why ("This needs your approval. Approvals happen only in the ZORO app, so it continues there."), and on
your tap the app opens and asks again in the foreground, where the normal approval sheet appears. Siri
never approves anything. If you say no, nothing was done. If the time runs out, the turn is stopped on the
server and Siri says so.

Siri's own speech recognition and voice are Apple's. Depending on the device and the language, Apple may
process the audio on its servers, under Apple's Siri privacy terms. **Private mode on your ZORO server does
not change what Siri does with your voice**: if a request must never leave your devices, open ZORO and use
its own Live Voice, which uses on-device speech in private mode.

## Locked phone

Every intent that sends a turn (Ask, spending, basket, music, remember, private mode, open a
conversation) uses `IntentAuthenticationPolicy.requiresAuthentication`: on a locked phone Siri asks you to
unlock (Face ID, Touch ID or passcode) before anything reaches ZORO. The policy is fixed per intent because
the data class of an answer is known only after it is computed, so it is applied to all of them. Data
classes that count as private here: **personal, sensitive, financial, health and secret**. Only *public*
answers would be safe to read on a locked phone, and no intent relies on that. *Secret* answers are not
spoken or shown by Siri even when the phone is unlocked. *Talk to ZORO*, *Open a section* and *Find a
photo* open the app, which iOS unlocks first.

## Limits

- One value per spoken phrase (see above); free text needs a second step.
- Siri waits a limited time; ZORO stops after 20 seconds.
- Approvals, payments and orders are never completed through Siri (product rules 3 and 8).
- Hindi phrases need Siri set to Hindi; Hinglish phrases need Siri set to English (India). How well Siri
  matches Hinglish has not been measured.
- Siri speaks Hindi replies with the voice of Siri's language; a Devanagari reply read by an English Siri
  voice has not been tested.
- On iPhones without Apple Intelligence, everything above still works through App Shortcuts. ZORO does
  not adopt Apple Intelligence assistant schemas: none of the published domains (mail, photos, books,
  browser, system search …) describes a general personal assistant, and the `.assistant` domain is a
  side-button action available only in Japan.
- Interactive snippets (iOS 26) are not used: the only action a snippet could offer is "continue in
  ZORO", which foreground continuation already does, and approvals stay out of Siri by design.

## For the engineer assembling the app

1. At launch (the `App` initializer, before any scene): `ZoroIntents.register(services:clientContext:
   updateShortcutParameters: { ZOROShortcuts.updateAppShortcutParameters() })`. Already in
   `AppTargetTemplates/ZOROApp.swift`.
2. Add `ZOROShortcuts.swift`, `AppShortcuts.xcstrings` and `Localizable.xcstrings` from
   `ios/Packages/ZoroApp/AppTargetTemplates/` to both app targets; add Hindi (`hi`) to the project's
   localisations. The Siri capability and `NSSiriUsageDescription` are not needed for App Intents.
3. When `shell.inbox.pendingConversationId` changes, `takeConversation()` and
   `await shell.openConversation(id:)` (in the template). Ask links arrive through the existing inbox.
4. Call `ZoroIntentDiscovery.refresh()` when the app becomes active and after pairing (in the template),
   and `ZoroIntentDiscovery.removeAll()` after unpairing.
5. Optionally donate what the owner does in the app: `ZoroIntentDiscovery.donate(.voice)`,
   `.section(_)`, `.ask(text, replyDataClasses:)` (sensitive replies are skipped automatically).

## Not verified

- No Xcode here, so the App Intents metadata processor has not run: phrase validity, the one-parameter
  rule, the 10-shortcut and 1,000-phrase ceilings (from Apple's WWDC22 session, not the symbol pages) and
  the String Catalog keys are checked only by this project's tests.
- Intents in a Swift package are found through `AppIntentsPackage` (`ZOROAppIntents` in the app,
  `ZoroAppIntentsPackage` in the package). Apple's runtime-behaviour article also mentions shipping such
  code as a binary framework; whether a static package needs that for foreground continuation is
  unconfirmed.
- The iOS 26+ paths (`supportedModes`, `continueInForeground`, `systemContext.currentMode`) are behind
  `#if compiler(>=6.2)` and were not compiled here. `ForegroundContinuableIntent` (used for iOS 18–25) is
  deprecated in iOS 26; expect deprecation warnings with Xcode 26.
- Whether the control widget runs `StartVoiceIntent` in the app (needed so `IntentInbox` reaches the UI)
  must be checked on a device; `allowedExecutionTargets` exists only from iOS 27.
- The Face ID prompt for signing the private-mode change while Siri is on screen has not been seen on a
  device; if it cannot appear, Siri says the mode was not changed and points to the app.
