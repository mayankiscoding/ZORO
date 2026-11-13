import AppIntents
import Foundation

/// Period for "check spending". A Siri phrase may carry it ("… how much I spent last month").
public enum SpendingPeriod: String, CaseIterable, Sendable, Codable, AppEnum {
    case today
    case thisWeek = "this-week"
    case lastWeek = "last-week"
    case thisMonth = "this-month"
    case lastMonth = "last-month"
    case thisYear = "this-year"

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Period"

    public static let caseDisplayRepresentations: [SpendingPeriod: DisplayRepresentation] = [
        .today: DisplayRepresentation(title: "Today", synonyms: ["aaj"]),
        .thisWeek: DisplayRepresentation(title: "This week", synonyms: ["is hafte"]),
        .lastWeek: DisplayRepresentation(title: "Last week", synonyms: ["previous week", "pichhle hafte"]),
        .thisMonth: DisplayRepresentation(title: "This month", synonyms: ["is mahine"]),
        .lastMonth: DisplayRepresentation(title: "Last month", synonyms: ["previous month", "pichhle mahine"]),
        .thisYear: DisplayRepresentation(title: "This year", synonyms: ["is saal"]),
    ]

    /// Words used inside a turn, per language.
    public func words(_ language: ZoroLanguage) -> String {
        switch (self, language) {
        case (.today, .english): "today"
        case (.thisWeek, .english): "this week"
        case (.lastWeek, .english): "last week"
        case (.thisMonth, .english): "this month"
        case (.lastMonth, .english): "last month"
        case (.thisYear, .english): "this year"
        case (.today, .hindi): "आज"
        case (.thisWeek, .hindi): "इस हफ़्ते"
        case (.lastWeek, .hindi): "पिछले हफ़्ते"
        case (.thisMonth, .hindi): "इस महीने"
        case (.lastMonth, .hindi): "पिछले महीने"
        case (.thisYear, .hindi): "इस साल"
        case (.today, .hinglish): "aaj"
        case (.thisWeek, .hinglish): "is hafte"
        case (.lastWeek, .hinglish): "pichhle hafte"
        case (.thisMonth, .hinglish): "is mahine"
        case (.lastMonth, .hinglish): "pichhle mahine"
        case (.thisYear, .hinglish): "is saal"
        }
    }
}

/// Spending category for "check spending". Optional: nil means all spending.
public enum SpendingCategory: String, CaseIterable, Sendable, Codable, AppEnum {
    case food, groceries
    case eatingOut = "eating-out"
    case transport, shopping, bills, entertainment, health, travel, fuel

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Category"

    public static let caseDisplayRepresentations: [SpendingCategory: DisplayRepresentation] = [
        .food: DisplayRepresentation(title: "Food", synonyms: ["khana", "khane"]),
        .groceries: DisplayRepresentation(title: "Groceries", synonyms: ["grocery", "kirana"]),
        .eatingOut: DisplayRepresentation(title: "Eating out", synonyms: ["restaurants", "dining out", "bahar khana"]),
        .transport: DisplayRepresentation(title: "Transport", synonyms: ["cabs", "travel to work", "aana jaana"]),
        .shopping: DisplayRepresentation(title: "Shopping"),
        .bills: DisplayRepresentation(title: "Bills", synonyms: ["utilities"]),
        .entertainment: DisplayRepresentation(title: "Entertainment", synonyms: ["movies"]),
        .health: DisplayRepresentation(title: "Health", synonyms: ["medical", "sehat"]),
        .travel: DisplayRepresentation(title: "Travel", synonyms: ["trips", "safar"]),
        .fuel: DisplayRepresentation(title: "Fuel", synonyms: ["petrol", "diesel"]),
    ]

    public func words(_ language: ZoroLanguage) -> String {
        switch language {
        case .english:
            switch self {
            case .food: "food"
            case .groceries: "groceries"
            case .eatingOut: "eating out"
            case .transport: "transport"
            case .shopping: "shopping"
            case .bills: "bills"
            case .entertainment: "entertainment"
            case .health: "health"
            case .travel: "travel"
            case .fuel: "fuel"
            }
        case .hindi:
            switch self {
            case .food: "खाने"
            case .groceries: "किराने"
            case .eatingOut: "बाहर खाने"
            case .transport: "आने-जाने"
            case .shopping: "शॉपिंग"
            case .bills: "बिलों"
            case .entertainment: "मनोरंजन"
            case .health: "सेहत"
            case .travel: "यात्रा"
            case .fuel: "पेट्रोल"
            }
        case .hinglish:
            switch self {
            case .food: "khane"
            case .groceries: "grocery"
            case .eatingOut: "bahar khane"
            case .transport: "aane-jaane"
            case .shopping: "shopping"
            case .bills: "bills"
            case .entertainment: "entertainment"
            case .health: "health"
            case .travel: "travel"
            case .fuel: "petrol"
            }
        }
    }
}

/// The turn text each focused intent sends, in the owner's language so the reply comes back in it.
/// Pure, so the mapping is unit-tested.
public enum IntentTurnText {
    public static func spending(period: SpendingPeriod, category: SpendingCategory?, language: ZoroLanguage) -> String {
        let when = period.words(language)
        switch language {
        case .english:
            let on = category.map { " on \($0.words(.english))" } ?? ""
            return "How much did I spend\(on) \(when)?"
        case .hindi:
            let on = category.map { " \($0.words(.hindi)) पर" } ?? ""
            return "\(when)\(on) मैंने कितना खर्च किया?"
        case .hinglish:
            let on = category.map { " \($0.words(.hinglish)) par" } ?? ""
            return "\(capitalised(when))\(on) maine kitna kharch kiya?"
        }
    }

    public static func compareBasket(language: ZoroLanguage) -> String {
        switch language {
        case .english: "Compare my basket across stores."
        case .hindi: "मेरी बास्केट की कीमतें सभी स्टोर में मिलाकर दिखाएँ।"
        case .hinglish: "Meri basket ki keemat sab stores mein compare karein."
        }
    }

    /// nil when the query is empty.
    public static func playMusic(_ query: String, onMac: Bool, language: ZoroLanguage) -> String? {
        guard let q = clean(query) else { return nil }
        switch language {
        case .english: return onMac ? "Play \(q) on my Mac." : "Play \(q)."
        case .hindi: return onMac ? "मेरे Mac पर \(q) चलाएँ।" : "\(q) चलाएँ।"
        case .hinglish: return onMac ? "Mere Mac par \(q) chalayein." : "\(q) chalayein."
        }
    }

    public static func remember(_ note: String, language: ZoroLanguage) -> String? {
        guard let n = clean(note) else { return nil }
        switch language {
        case .english: return "Remember this: \(n)"
        case .hindi: return "यह याद रखें: \(n)"
        case .hinglish: return "Yeh yaad rakhein: \(n)"
        }
    }

    public static func findPhoto(_ query: String, language: ZoroLanguage) -> String? {
        guard let q = clean(query) else { return nil }
        switch language {
        case .english: return "Find a photo of \(q)."
        case .hindi: return "\(q) की फ़ोटो ढूँढें।"
        case .hinglish: return "\(q) ki photo dhoondhein."
        }
    }

    /// Trimmed and cut to `AskLimits.maxPhraseLength`; nil when empty.
    public static func clean(_ text: String?) -> String? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Leave room for the words around it.
        return String(trimmed.prefix(AskLimits.maxPhraseLength - 64))
    }

    private static func capitalised(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
