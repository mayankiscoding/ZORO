import Foundation

/// One normalisation for everything that is stored or searched, so Latin, Devanagari and romanised
/// Hindi compare consistently:
/// - lower case, Latin diacritics removed ("café" → "cafe");
/// - Devanagari nukta dropped ("सफ़ेद" == "सफेद") and chandrabindu folded into anusvara;
/// - `_` and punctuation become spaces (Vision identifiers like `sunset_sunrise`).
public enum TextNormalizer {
    public static func normalize(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }

    public static func tokens(_ text: String) -> [String] {
        let decomposed = text.lowercased().decomposedStringWithCanonicalMapping
        var scalars = String.UnicodeScalarView()
        for scalar in decomposed.unicodeScalars {
            switch scalar.value {
            case 0x0300...0x036F, 0x093C:  // Latin combining diacritics, Devanagari nukta
                continue
            case 0x0901:  // chandrabindu → anusvara
                scalars.append(Unicode.Scalar(0x0902)!)
            default:
                if isWordScalar(scalar) {
                    scalars.append(scalar)
                } else {
                    scalars.append(" ")
                }
            }
        }
        return String(scalars).precomposedStringWithCanonicalMapping
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// Whether `phrase` (normalised words) occurs as whole words inside `haystack` (normalised words).
    public static func containsPhrase(_ haystack: String, _ phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        return " \(haystack) ".contains(" \(phrase) ")
    }
}
