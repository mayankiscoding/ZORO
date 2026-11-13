import Foundation
import ZoroDesign

/// Formatting for figures that are not plain rupee amounts. Decimal in, string out; no floating point
/// for money. Analytics ratios that the server sends as floats are formatted as floats.
public enum Figures {
    /// Rupees with Indian grouping (delegates to `ZoroMoney`).
    public static func money(_ amount: Decimal, style: ZoroMoney.Style = .exact, showsPlus: Bool = false) -> String {
        ZoroMoney.format(amount, style: style, showsPlus: showsPlus)
    }

    /// Money that may be unknown: "Not known" instead of ₹0.
    public static func money(_ amount: Decimal?, style: ZoroMoney.Style = .exact, unknown: String = "Not known") -> String {
        amount.map { ZoroMoney.format($0, style: style) } ?? unknown
    }

    /// "12.5%" / "−3.2%" / "+3.2%". Rounded half away from zero.
    public static func percent(_ value: Decimal, places: Int = 1, showsPlus: Bool = false) -> String {
        var v = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &v, places, .plain)
        let negative = rounded < 0
        let magnitude = negative ? -rounded : rounded
        var text = NSDecimalNumber(decimal: magnitude).stringValue
        if places > 0 {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            let fraction = parts.count > 1 ? String(parts[1]) : ""
            text = String(parts[0]) + "." + String((fraction + String(repeating: "0", count: places)).prefix(places))
        }
        if negative && magnitude != 0 { return ZoroMoney.minus + text + "%" }
        if showsPlus && magnitude != 0 { return "+" + text + "%" }
        return text + "%"
    }

    /// Float analytics (Sharpe, z-scores): fixed places, typographic minus.
    public static func ratio(_ value: Double?, places: Int = 2, unknown: String = "Not enough data") -> String {
        guard let value, value.isFinite else { return unknown }
        let text = String(format: "%.\(places)f", abs(value))
        return value < 0 && text != String(format: "%.\(places)f", 0.0) ? ZoroMoney.minus + text : text
    }

    /// Quantities (shares can be fractional on the wire): "10", "2.5".
    public static func quantity(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    /// "4:12 pm" today, "12 Nov" otherwise (India locale), for "checked …" lines.
    public static func moment(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_IN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(date, inSameDayAs: now) ? "hmma" : "dMMM")
        return formatter.string(from: date)
    }
}
