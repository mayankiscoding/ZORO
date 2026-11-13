// UNVERIFIED-ON-HOST
// Apple's on-device model, used only to normalise English commands (Apple Intelligence does not list Hindi).
// Checked against developer.apple.com/documentation/foundationmodels:
//   SystemLanguageModel.default (iOS 26.0+, macOS 26.0+), .availability == .available, .supportsLocale(_:),
//   LanguageModelSession(instructions: String) and respond(to: String, generating:) async throws ->
//   Response<Content>, both exactly as in Apple's sample code (re-checked 2026-11-13), Response.content,
//   @Generable / @Guide(description:) for guided generation.
// FoundationModels is not in the macOS 15.5 SDK on this machine, so this file is compiled only by Xcode 26+.
#if canImport(FoundationModels) && compiler(>=6.2)
import FoundationModels
import Foundation

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedIntentGuess {
    @Guide(description: "One of: alarm, timer, reminder, calendar, music, photos, open_section, none. Use none when the request is not one of these device commands.")
    var intent: String
    @Guide(description: "For a reminder: what to be reminded of, without the time words. Otherwise empty.")
    var title: String
    @Guide(description: "The time words exactly as the user said them, for example 'tomorrow at 6 pm' or '10 minutes'. Empty when none.")
    var timePhrase: String
    @Guide(description: "For music: the song, artist or playlist to play. For photos: what the photos show. Otherwise empty.")
    var query: String
    @Guide(description: "For music only: play, pause, next or previous. Otherwise empty.")
    var musicAction: String
    @Guide(description: "For open_section: one of shopping, finance, investments, fitness, photos, music, memory, integrations, device control, security, settings, history, activity. Otherwise empty.")
    var section: String
}

@available(iOS 26.0, macOS 26.0, *)
struct FoundationModelsIntentAssist: OnDeviceIntentAssisting {
    private static let instructions = """
        You read one short English command to a personal assistant and say which device command it is. \
        You never invent details: copy time words and names exactly as written. If it is not an alarm, timer, \
        reminder, calendar lookup, music control, photo search or opening a part of the app, answer none.
        """

    func isAvailable() async -> Bool {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return false }
        return model.supportsLocale(Locale(identifier: "en_US"))
    }

    func guess(for text: String) async throws -> IntentGuess? {
        // String forms as in Apple's own samples (Instructions and guided-generation articles). The builder
        // closures document only `buildExpression(Instructions)` / `buildExpression(Prompt)`, so a String
        // variable inside `{ }` is not a documented form.
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(to: text, generating: GeneratedIntentGuess.self)
        let g = response.content
        func opt(_ s: String) -> String? { s.isEmpty ? nil : s }
        guard g.intent != "none" else { return nil }
        return IntentGuess(
            intent: g.intent, title: opt(g.title), timePhrase: opt(g.timePhrase), query: opt(g.query),
            musicAction: opt(g.musicAction), section: opt(g.section))
    }
}

public enum SystemIntentAssist {
    /// Apple's on-device model as an intent assistant, or nil on an OS that does not have it.
    public static func make() -> (any OnDeviceIntentAssisting)? {
        if #available(iOS 26.0, macOS 26.0, *) { return FoundationModelsIntentAssist() }
        return nil
    }
}
#else
public enum SystemIntentAssist {
    /// Apple's on-device model is not part of this SDK.
    public static func make() -> (any OnDeviceIntentAssisting)? { nil }
}
#endif
