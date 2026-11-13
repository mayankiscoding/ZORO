import Foundation

/// Locale-stable formatting helpers. Money is Decimal; costs from the backend are US dollars.
public enum SystemFormat {
    /// "$0.0042", "$12.50": four fractional digits under one dollar, two from one dollar up. Half away from zero.
    public static func usd(_ amount: Decimal) -> String {
        let magnitude = amount < 0 ? -amount : amount
        let scale = magnitude < 1 ? 4 : 2
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, scale, .plain)
        let negative = rounded < 0
        let mag = negative ? -rounded : rounded
        let raw = NSDecimalNumber(decimal: mag).stringValue
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        var integer = String(parts.first ?? "0")
        let fraction = String(((parts.count > 1 ? String(parts[1]) : "") + String(repeating: "0", count: scale)).prefix(scale))
        integer = groupThousands(integer)
        return (negative && mag != 0 ? "\u{2212}" : "") + "$" + integer + "." + fraction
    }

    static func groupThousands(_ digits: String) -> String {
        var out: [Character] = []
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return String(out.reversed())
    }

    /// "12 Nov, 4:12 pm" in the given calendar and locale (English interface copy).
    public static func dateTime(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_IN")
        f.timeZone = timeZone
        f.dateFormat = "d MMM, h:mm a"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f.string(from: date)
    }

    public static func relative(_ date: Date, to now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "en_IN")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }

    /// "1,234 tokens" style integer with thousands separators.
    public static func count(_ n: Int) -> String { groupThousands(String(n)) }

    /// A short, readable name for a tool id: "finance.spending_summary" -> "Spending summary".
    public static func toolTitle(_ tool: String) -> String {
        let last = tool.split(separator: ".").last.map(String.init) ?? tool
        return sentenceCase(last.replacingOccurrences(of: "_", with: " "))
    }

    public static func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
