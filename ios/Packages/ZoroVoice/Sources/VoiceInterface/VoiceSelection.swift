import Foundation
import ZoroCore

/// A system voice as the selector sees it (no AVFoundation types, so selection is testable).
public struct SpeechVoiceDescriptor: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// BCP-47, for example "hi-IN".
    public var language: String
    public var gender: VoiceSettings.Gender?
    /// 0 default, 1 enhanced, 2 premium.
    public var quality: Int

    public init(id: String, name: String, language: String, gender: VoiceSettings.Gender? = nil, quality: Int = 0) {
        self.id = id
        self.name = name
        self.language = language
        self.gender = gender
        self.quality = quality
    }
}

public enum VoiceSelector {
    /// The owner's chosen voice when it speaks `language`; otherwise the best voice for the exact
    /// locale, then for the language ("hi-*"), preferring the chosen gender, then higher quality.
    public static func select(
        from voices: [SpeechVoiceDescriptor], language: String, gender: VoiceSettings.Gender, preferredId: String?
    ) -> SpeechVoiceDescriptor? {
        let wanted = normalize(language)
        let base = wanted.split(separator: "-").first.map(String.init) ?? wanted
        if let preferredId, let v = voices.first(where: { $0.id == preferredId }), normalize(v.language).hasPrefix(base) {
            return v
        }
        let exact = voices.filter { normalize($0.language) == wanted }
        let sameLanguage = voices.filter { normalize($0.language).split(separator: "-").first.map(String.init) == base }
        let pool = exact.isEmpty ? sameLanguage : exact
        return pool.sorted { a, b in
            let ga = a.gender == gender ? 1 : 0
            let gb = b.gender == gender ? 1 : 0
            if ga != gb { return ga > gb }
            if a.quality != b.quality { return a.quality > b.quality }
            return a.id < b.id
        }.first
    }

    static func normalize(_ language: String) -> String {
        language.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}

/// Maps the owner's settings onto synthesiser parameters.
public enum SpeechStyle {
    /// `speakingRate` 0.5...2.0 (1 = normal) scales the synthesiser's default rate, clamped to its range.
    /// AVSpeechUtterance: default 0.5, minimum 0, maximum 1.
    public static func rate(speakingRate: Double, defaultRate: Float = 0.5, minimum: Float = 0, maximum: Float = 1) -> Float {
        let r = Float(max(0.5, min(2.0, speakingRate.isFinite ? speakingRate : 1)))
        return max(minimum, min(maximum, defaultRate * r))
    }

    public static func pitch(_ personality: VoiceSettings.Personality) -> Float {
        switch personality {
        case .calm: 0.95
        case .warm: 1.0
        case .crisp: 1.05
        }
    }
}
