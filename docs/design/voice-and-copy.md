# ZORO voice and copy

Status: **design rules + reference strings**. English strings that ZoroDesign uses itself are in code
(`OrbState.accessibilityValue`, `ZoroPrivacyMode`, `AgentActivityStatus`, `ConfidenceLevel`,
`ProductAvailability`, `SourceStamp.line`, `ApprovalSummary.expiryText`). The Hindi column is the
reference translation for the app's string catalogue; it has not been reviewed by a second native speaker.

## 1. Tone

ZORO is a capable assistant who works for one person. It sounds calm, brief and exact.

- **Say what happened, then what to do.** "Store B didn't answer, so it's left out of the comparison."
  Not "Oops! Something went wrong."
- **Plain verbs, sentence case, no filler.** No "Sure!", "Great question", "I'd be happy to".
- **Never apologise for the system, never blame the owner.** Errors don't say sorry; they explain.
- **Numbers come only from tools.** ZORO never says a price, total, balance or time that a tool did not
  return. When a source is down it says so and names it.
- **Honest about limits.** "iOS doesn't let apps read messages. I can open WhatsApp with the text ready."
- **One name per action through a flow.** The button that says *Approve* leads to a toast that says
  *Approved*. *Decline* leads to *Declined*. *Open basket in Store A* opens the basket in Store A.
- **No all-caps labels, no arrows in buttons, no exclamation marks.**
- **Spoken answers are shorter than written ones.** Speech gives the answer and the one next step; detail
  goes in the card.

## 2. Bilingual rules

1. **Reply in the owner's language and script.** Devanagari in → Hindi in Devanagari out. Latin-script
   Hinglish in ("kal subah 6 baje alarm laga do") → Hinglish in Latin script out. English in → English
   out. Interface chrome follows the app language setting, not the last turn.
2. **Digits are Western (0–9) in both languages.** Money is `₹` with Indian grouping (₹1,23,456.50)
   everywhere, including Hindi sentences. Never lakh/crore words in a figure; they may be spoken ("सवा लाख").
3. **Names stay as their owners write them.** Store, app and brand names stay in Latin script
   (Instamart, WhatsApp, Spotify) inside Hindi sentences.
4. **Dates and times.** English: "12 Nov", "4:12 pm". Hindi: "12 नवंबर", "शाम 4:12". 12-hour clock with
   the period of day in Hindi (सुबह, दोपहर, शाम, रात).
5. **Grammatical gender.** Interface labels avoid first-person verbs, so they need no gender ("जवाब तैयार
   हो रहा है", not "मैं सोच रहा हूँ"). In conversation ZORO's first-person verb forms follow the voice the
   owner picked during setup; the catalogue keeps both forms where a sentence needs one.
6. **Formal "आप"**, never "तुम" or "तू".
7. **Mixed-script lines get extra leading** (`ZoroTextStyle.mixedScriptLeading`), and are never set in
   all caps or letter-spaced.
8. **Layout.** ZORO's words, in either script, stand on the rekha in New York (Hindi falls back to the
   system Devanagari face). The owner's words hang below it in SF Pro.

## 3. Orb states (VoiceOver value after the label "ZORO")

| State | English | हिन्दी |
|---|---|---|
| idle | Ready. Tap to talk. | तैयार। बात करने के लिए टैप करें। |
| listening | Listening | आपकी बात सुनी जा रही है |
| processing | Thinking | जवाब तैयार हो रहा है |
| delegating | Working with Shopping and Finance | Shopping और Finance के साथ काम जारी है |
| tool execution | Carrying out a step with Shopping | Shopping के साथ एक कदम पूरा हो रहा है |
| speaking | Speaking | जवाब सुनाया जा रहा है |
| error | Something went wrong | कुछ गड़बड़ हुई |
| private | Private mode. Nothing leaves your server. | प्राइवेट मोड। कुछ भी आपके सर्वर से बाहर नहीं जाता। |

The error value is short because the screen always shows the specific error sentence next to it.

## 4. Status words

| Where | English | हिन्दी |
|---|---|---|
| Agent waiting | Waiting to start | शुरू होने का इंतज़ार |
| Agent working | Working | काम जारी है |
| Agent needs owner | Needs your approval | आपकी मंज़ूरी चाहिए |
| Agent done | Done | हो गया |
| Agent failed | Couldn't finish | पूरा नहीं हो सका |
| Match ≥ 0.8 | Good match | सही मेल |
| Match ≥ 0.5 | Close match | मिलता-जुलता |
| Match < 0.5 | Check this | एक बार देख लें |
| Stock | In stock / Few left / Out of stock / Stock not reported | उपलब्ध / कुछ ही बचे / उपलब्ध नहीं / स्टॉक की जानकारी नहीं |
| Source line | From Instamart, checked 4:12 pm | Instamart से, शाम 4:12 पर देखा गया |
| Stale price | Price may have changed. | कीमत बदल सकती है। |
| Comparison best | Lowest | सबसे कम |
| Comparison missing | 1 item missing / 3 items missing | 1 चीज़ नहीं है / 3 चीज़ें नहीं हैं |
| Unavailable cell | Not available | उपलब्ध नहीं |
| No complete store | No store has every item. Totals cover only what each store has. | किसी भी स्टोर में सब कुछ नहीं है। कुल रकम में सिर्फ़ वही है जो हर स्टोर में है। |

## 5. Privacy mode

| | English | हिन्दी |
|---|---|---|
| Strict title | Private mode | प्राइवेट मोड |
| Strict line | Nothing leaves your ZORO server. | कुछ भी आपके ZORO सर्वर से बाहर नहीं जाता। |
| Cloud title | Cloud intelligence | क्लाउड इंटेलिजेंस |
| Cloud line | Only what you allowed is sent out, with personal details removed. | सिर्फ़ वही बाहर भेजा जाता है जिसकी आपने अनुमति दी है, निजी जानकारी हटाकर। |
| Switch to cloud, sheet | Turning this on lets ZORO send the data types you choose to the providers listed below. | इसे चालू करने पर ZORO आपकी चुनी हुई जानकारी नीचे दिए गए प्रदाताओं को भेज सकेगा। |
| Switched | Cloud intelligence is on. | क्लाउड इंटेलिजेंस चालू है। |
| Switched back | Private mode is on. | प्राइवेट मोड चालू है। |

## 6. Approvals

| | English | हिन्दी |
|---|---|---|
| Buttons | Approve, Approve with Face ID, Decline | मंज़ूर करें, Face ID से मंज़ूर करें, मना करें |
| After approve | Approved. Sending now. | मंज़ूर। अभी भेजा जा रहा है। |
| After decline | Declined. Nothing was sent. | मना कर दिया। कुछ नहीं भेजा गया। |
| Expiry | Expires in 1:45 | 1:45 में समय खत्म होगा |
| Expired | Expired. Ask again to approve. | समय खत्म। मंज़ूरी के लिए फिर से कहें। |
| Face ID failed | Face ID didn't match. Try again or use your passcode. | Face ID मेल नहीं खाया। फिर से कोशिश करें या पासकोड डालें। |
| Tainted turn | This came from a web page ZORO read. Check the details. | यह ZORO के पढ़े किसी वेब पेज से आया है। जानकारी जाँच लें। |
| Payment hand-off | You'll pay in Store A's app. ZORO never pays for you. | भुगतान आप Store A के ऐप में करेंगे। ZORO कभी आपकी ओर से भुगतान नहीं करता। |

## 7. Empty, loading, error and disconnected states

| Situation | English | हिन्दी | Action |
|---|---|---|---|
| No baskets | No baskets yet. Ask ZORO to start one, like "add milk and eggs". | अभी कोई बास्केट नहीं है। ZORO से कहें, जैसे "दूध और अंडे जोड़ दो"। | — |
| No activity | Nothing running. Agents show up here while they work. | अभी कुछ नहीं चल रहा। काम करते समय एजेंट यहाँ दिखेंगे। | — |
| No memories | ZORO hasn't saved anything about you yet. | ZORO ने अभी आपके बारे में कुछ सेव नहीं किया है। | — |
| Loading prices | Checking prices at 3 stores. | 3 स्टोर पर कीमतें देखी जा रही हैं। | — |
| Server unreachable | Can't reach your ZORO server. Check that your Mac is awake and on Tailscale. | आपके ZORO सर्वर से जुड़ नहीं पा रहे। देखें कि आपका Mac चालू है और Tailscale पर है। | Reconnect / फिर से जोड़ें |
| Pairing code wrong | That code didn't match. Check the code on your server and try again. | यह कोड मेल नहीं खाया। सर्वर पर कोड देखकर फिर से डालें। | Try again / फिर से कोशिश करें |
| Pairing code expired | That code expired. Make a new one on your server: python -m app.cli pairing-code | यह कोड पुराना हो गया। सर्वर पर नया कोड बनाएँ: python -m app.cli pairing-code | Try again |
| Store didn't answer | Store B didn't answer, so it's left out of the comparison. | Store B से जवाब नहीं आया, इसलिए वह तुलना में शामिल नहीं है। | Try again |
| No cloud model | I can do this part without the cloud. For the rest, turn on cloud intelligence. | यह हिस्सा क्लाउड के बिना हो सकता है। बाकी के लिए क्लाउड इंटेलिजेंस चालू करें। | Open settings / सेटिंग खोलें |
| Credential expired | Spotify needs you to sign in again. | Spotify में फिर से साइन इन करना होगा। | Sign in / साइन इन करें |
| Microphone off | ZORO needs the microphone to hear you. Turn it on in Settings. | आपकी बात सुनने के लिए ZORO को माइक्रोफ़ोन चाहिए। इसे सेटिंग में चालू करें। | Open Settings |
| Speech unavailable | Speech recognition isn't available right now. You can type instead. | अभी बोलकर पहचान उपलब्ध नहीं है। आप टाइप कर सकते हैं। | Type / टाइप करें |
| Tool timed out | Finance took too long to answer. Nothing was changed. | Finance ने जवाब देने में बहुत देर लगाई। कुछ नहीं बदला गया। | Try again |
| Kill switch on | ZORO is paused. Turn it back on in Security and privacy. | ZORO रुका हुआ है। Security and privacy में इसे फिर से चालू करें। | Open / खोलें |
| Device revoked | This iPhone was removed from ZORO. Pair it again to continue. | यह iPhone ZORO से हटा दिया गया है। जारी रखने के लिए फिर से जोड़ें। | Pair again / फिर से जोड़ें |
| iOS limit | iOS doesn't let apps read your messages. I can open WhatsApp with the text ready. | iOS ऐप्स को आपके मैसेज पढ़ने नहीं देता। मैं WhatsApp में मैसेज तैयार करके खोल सकता हूँ। | Open WhatsApp |

## 8. Permission prompts (one sentence each, asked in context)

| Permission | English | हिन्दी |
|---|---|---|
| Microphone | ZORO listens only while the orb is listening, after you press or tap. | ZORO सिर्फ़ तभी सुनता है जब आप बटन दबाएँ या ऑर्ब पर टैप करें। |
| Speech recognition | Your words are turned into text on this iPhone. | आपकी बात इसी iPhone पर टेक्स्ट में बदली जाती है। |
| Photos | ZORO searches your photos on this iPhone; they don't leave it. | ZORO आपकी फ़ोटो इसी iPhone पर खोजता है; वे बाहर नहीं जातीं। |
| Health | ZORO reads activity and workouts to answer your fitness questions. | फ़िटनेस के सवालों के जवाब के लिए ZORO आपकी एक्टिविटी और वर्कआउट पढ़ता है। |
| Reminders / Calendar | ZORO adds and reads reminders and events when you ask. | आपके कहने पर ZORO रिमाइंडर और इवेंट जोड़ता और पढ़ता है। |
| Notifications | ZORO tells you when an approval is waiting or a task finishes. | मंज़ूरी बाकी हो या काम पूरा हो, तो ZORO आपको बताता है। |

The Info.plist purpose strings use these sentences. "ZORO सुनता है" / "खोजता है" are third person and
need no gender choice; the iOS-limit line in section 7 uses the first person and has a feminine form
("खोल सकती हूँ") in the catalogue.
