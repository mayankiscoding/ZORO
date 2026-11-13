import AppIntents
import Foundation
import Testing
import ZoroCore
@testable import ZoroAppUI

@Suite("Siri wording")
struct IntentCopyTests {
    static let failures: [IntentTurnFailure] = [
        .timeout, .offline, .notPaired, .unauthorized, .paused, .cancelled, .empty, .notConfigured,
        .server(code: "x", message: "Finance took too long.", retryable: true),
    ]

    @Test func englishSentences() {
        let en = IntentCopy(.english)
        #expect(en.askPrompt == "What should I ask ZORO?")
        #expect(en.failure(.paused) == "ZORO is paused. Turn it back on in Security and privacy.")
        #expect(en.privateModeOn == "Private mode is on.")
        #expect(en.siriTip == "Say: “Hey Siri, ask ZORO …”")
    }

    @Test func hindiSentences() {
        let hi = IntentCopy(.hindi)
        #expect(hi.askPrompt == "ZORO से क्या पूछना है?")
        #expect(hi.continuation(.approval) == "इसके लिए आपकी मंज़ूरी चाहिए। मंज़ूरी सिर्फ़ ZORO ऐप में दी जाती है, इसलिए यह वहीं जारी रहेगा।")
        #expect(hi.privateModeOn == "प्राइवेट मोड चालू है।")
        #expect(hi.siriTip == "कहें: “Hey Siri, ZORO से पूछें …”")
        #expect(IntentCopy(.hinglish).siriTip == "Kahein: “Hey Siri, ZORO se poochho …”")
    }

    @Test func everySentenceExistsInEveryLanguageAndFollowsTheRules() {
        for language in ZoroLanguage.allCases {
            let copy = IntentCopy(language)
            var all = Self.failures.map(copy.failure)
            all += IntentSuspension.allCases.map(copy.continuation)
            all += [copy.askPrompt, copy.playPrompt, copy.rememberPrompt, copy.photoPrompt, copy.periodPrompt, copy.longReply,
                    copy.privateReply, copy.notContinued, copy.openAppToContinue, copy.privateModeOn,
                    copy.privateModeAlreadyOn, copy.privateModeUnchanged, copy.siriTip, copy.siriTipDetail, copy.openingPhotos]
            for sentence in all {
                #expect(!sentence.isEmpty)
                #expect(!sentence.contains("!"), "no exclamation marks: \(sentence)")
                #expect(!sentence.lowercased().contains("sorry"))
                let devanagari = sentence.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
                #expect(devanagari == (language == .hindi), "\(language): \(sentence)")
                #expect(!sentence.contains("तुम"), "formal आप only")
            }
        }
    }

    @Test func replyLanguage() {
        #expect(IntentCopy.language(ofReply: "hi", fallback: .english) == .hindi)
        #expect(IntentCopy.language(ofReply: "hi-Latn", fallback: .english) == .hinglish)
        #expect(IntentCopy.language(ofReply: "hinglish", fallback: .english) == .hinglish)
        #expect(IntentCopy.language(ofReply: "en-IN", fallback: .hindi) == .english)
        #expect(IntentCopy.language(ofReply: nil, fallback: .hindi) == .hindi)
        #expect(IntentCopy.language(ofReply: "ta", fallback: .hinglish) == .hinglish)
    }
}

@Suite("Intent parameters to turn text")
struct IntentTurnTextTests {
    @Test func spending() {
        #expect(IntentTurnText.spending(period: .lastMonth, category: .food, language: .english) == "How much did I spend on food last month?")
        #expect(IntentTurnText.spending(period: .thisWeek, category: nil, language: .english) == "How much did I spend this week?")
        #expect(IntentTurnText.spending(period: .lastMonth, category: .food, language: .hindi) == "पिछले महीने खाने पर मैंने कितना खर्च किया?")
        #expect(IntentTurnText.spending(period: .today, category: nil, language: .hindi) == "आज मैंने कितना खर्च किया?")
        #expect(IntentTurnText.spending(period: .lastMonth, category: .eatingOut, language: .hinglish) == "Pichhle mahine bahar khane par maine kitna kharch kiya?")
    }

    @Test func everyCaseHasWordsAndATitle() {
        for language in ZoroLanguage.allCases {
            #expect(Set(SpendingPeriod.allCases.map { $0.words(language) }).count == SpendingPeriod.allCases.count)
            #expect(Set(SpendingCategory.allCases.map { $0.words(language) }).count == SpendingCategory.allCases.count)
        }
        #expect(SpendingPeriod.caseDisplayRepresentations.count == SpendingPeriod.allCases.count)
        #expect(SpendingCategory.caseDisplayRepresentations.count == SpendingCategory.allCases.count)
    }

    @Test func otherIntents() {
        #expect(IntentTurnText.compareBasket(language: .english) == "Compare my basket across stores.")
        #expect(IntentTurnText.playMusic(" Lata Mangeshkar ", onMac: true, language: .english) == "Play Lata Mangeshkar on my Mac.")
        #expect(IntentTurnText.playMusic("lo-fi", onMac: false, language: .hindi) == "lo-fi चलाएँ।")
        #expect(IntentTurnText.playMusic("lo-fi", onMac: true, language: .hinglish) == "Mere Mac par lo-fi chalayein.")
        #expect(IntentTurnText.playMusic("   ", onMac: false, language: .english) == nil)
        #expect(IntentTurnText.remember("Asha's birthday is 3 March", language: .english) == "Remember this: Asha's birthday is 3 March")
        #expect(IntentTurnText.remember("", language: .hindi) == nil)
        #expect(IntentTurnText.findPhoto("the beach in Goa", language: .english) == "Find a photo of the beach in Goa.")
        #expect(IntentTurnText.findPhoto("गोवा का समुद्र", language: .hindi) == "गोवा का समुद्र की फ़ोटो ढूँढें।")
        let long = String(repeating: "x", count: AskLimits.maxPhraseLength * 2)
        #expect(IntentTurnText.remember(long, language: .english)!.count <= AskLimits.maxPhraseLength)
    }
}

@Suite("App Shortcuts phrase catalogue")
struct ShortcutPhraseTests {
    static let templates = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("AppTargetTemplates")

    @Test func everyPhraseHasTheAppNameAndAtMostOneParameter() {
        for shortcut in ZoroShortcutPhrases.all {
            #expect(shortcut.shortTitle.count <= ZoroShortcutPhrases.maxShortTitleLength)
            #expect(shortcut.phrases.contains { $0.script == .english })
            #expect(shortcut.phrases.contains { $0.script == .hinglish })
            for phrase in shortcut.phrases {
                #expect(ZoroShortcutPhrases.occurrences(of: ZoroShortcutPhrases.appNameToken, in: phrase.key) == 1, "\(phrase.key)")
                #expect(ZoroShortcutPhrases.occurrences(of: ZoroShortcutPhrases.appNameToken, in: phrase.hindi) == 1, "\(phrase.hindi)")
                let parameters = ZoroShortcutPhrases.parameters(in: phrase.key)
                #expect(parameters.count <= ZoroShortcutPhrases.maxParametersPerPhrase)
                #expect(ZoroShortcutPhrases.parameters(in: phrase.hindi) == parameters, "Hindi keeps the parameter: \(phrase.hindi)")
                for p in parameters { #expect(ZoroShortcutPhrases.parameterCaseCounts[p] != nil, "unknown parameter \(p)") }
                #expect(phrase.hindi.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) })
            }
        }
    }

    @Test func countsAreWithinApplesLimits() {
        let phrases = ZoroShortcutPhrases.all.flatMap(\.phrases)
        #expect(ZoroShortcutPhrases.all.count <= ZoroShortcutPhrases.maxShortcuts)
        #expect(Set(phrases.map(\.key)).count == phrases.count, "phrases are unique")
        #expect(Set(phrases.map(\.hindi)).count == phrases.count, "Hindi phrases are unique")
        #expect(ZoroShortcutPhrases.expandedPhraseCount <= ZoroShortcutPhrases.maxExpandedPhrases)
        #expect(Set(ZoroShortcutPhrases.all.map(\.intent)).count == ZoroShortcutPhrases.all.count)
    }

    /// Turns `"Open \(\.$section) in \(.applicationName)",` into `Open ${section} in ${applicationName}`.
    static func catalogueForm(_ line: String) -> String {
        var s = String(line.dropFirst().prefix { $0 != "\"" })
        s = s.replacingOccurrences(of: "\\(.applicationName)", with: "${applicationName}")
        while let r = s.range(of: #"\\\(\\\.\$\w+\)"#, options: .regularExpression) {
            let name = s[r].dropFirst(5).dropLast()
            s.replaceSubrange(r, with: "${\(name)}")
        }
        return s
    }

    /// The provider in the app target spells the same phrases, titles and symbols.
    @Test func templateProviderMatchesTheCatalogue() throws {
        let source = try String(contentsOf: Self.templates.appendingPathComponent("ZOROShortcuts.swift"), encoding: .utf8)
        let blocks = Array(source.components(separatedBy: "AppShortcut(\n").dropFirst())
        #expect(blocks.count == ZoroShortcutPhrases.all.count)
        for (block, expected) in zip(blocks, ZoroShortcutPhrases.all) {
            #expect(block.contains("intent: \(expected.intent)()"))
            #expect(block.contains("shortTitle: \"\(expected.shortTitle)\""))
            #expect(block.contains("systemImageName: \"\(expected.systemImageName)\""))
            let phraseList = block.components(separatedBy: "phrases: [")[1].components(separatedBy: "],")[0]
            let literals = phraseList.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("\"") }
                .map(Self.catalogueForm)
            #expect(literals == expected.phrases.map(\.key), "\(expected.intent)")
        }
    }

    @Test func stringCatalogHasEveryHindiPhrase() throws {
        let data = try Data(contentsOf: Self.templates.appendingPathComponent("AppShortcuts.xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["sourceLanguage"] as? String == "en")
        let strings = try #require(json["strings"] as? [String: Any])
        let phrases = ZoroShortcutPhrases.all.flatMap(\.phrases)
        #expect(Set(strings.keys) == Set(phrases.map(\.key)))
        for phrase in phrases {
            let entry = strings[phrase.key] as? [String: Any]
            let hi = ((entry?["localizations"] as? [String: Any])?["hi"] as? [String: Any])?["stringUnit"] as? [String: Any]
            #expect(hi?["value"] as? String == phrase.hindi)
            #expect(hi?["state"] as? String == "translated")
        }
    }

    @Test func localizableCatalogCoversRequestDialogsAndEnumTitles() throws {
        let data = try Data(contentsOf: Self.templates.appendingPathComponent("Localizable.xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let keys = Set((json["strings"] as? [String: Any] ?? [:]).keys)
        let required = ["Ask ZORO", "What should I ask ZORO?", "For which period?", "What should ZORO play?",
                        "What should ZORO remember?", "What's in the photo?", "Last month", "Food"]
            + ZoroShortcutPhrases.all.map(\.shortTitle)
        for key in required { #expect(keys.contains(key), "missing \(key)") }
    }
}
