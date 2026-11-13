import Foundation

/// Exact rupee formatting with Indian digit grouping (₹1,23,45,678.50). `Decimal` in, string out;
/// no floating point anywhere. Rounding is half away from zero to paise.
public enum ZoroMoney {
    public enum Style: Sendable, Equatable {
        /// Always two paise digits: ₹1,500.00.
        case exact
        /// Paise only when non-zero: ₹1,500 / ₹1,500.50.
        case compact
        /// Rounded to whole rupees: ₹1,501.
        case whole
    }

    /// U+2212 MINUS SIGN: the typographic minus, same width as the digits.
    public static let minus = "\u{2212}"
    public static let rupee = "₹"

    public static func format(_ amount: Decimal, style: Style = .exact, showsPlus: Bool = false) -> String {
        let scale = style == .whole ? 0 : 2
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, scale, .plain)
        let negative = rounded < 0
        let magnitude = negative ? -rounded : rounded
        // NSDecimalNumber.stringValue is locale-independent ("1234.5").
        let raw = NSDecimalNumber(decimal: magnitude).stringValue
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        let integer = String(parts.first ?? "0")
        var fraction = parts.count > 1 ? String(parts[1]) : ""
        switch style {
        case .whole:
            fraction = ""
        case .exact:
            fraction = String((fraction + "00").prefix(2))
        case .compact:
            fraction = fraction.isEmpty || Int(fraction) == 0 ? "" : String((fraction + "00").prefix(2))
        }
        var text = rupee + groupIndian(integer)
        if !fraction.isEmpty { text += "." + fraction }
        if negative && magnitude != 0 { return minus + text }
        if showsPlus && magnitude != 0 { return "+" + text }
        return text
    }

    /// Indian grouping of a digit string: last three digits, then pairs. "12345678" → "1,23,45,678".
    public static func groupIndian(_ digits: String) -> String {
        guard digits.count > 3 else { return digits }
        let chars = Array(digits)
        let last3 = String(chars.suffix(3))
        var head = Array(chars.dropLast(3))
        var groups: [String] = []
        while head.count > 2 {
            groups.insert(String(head.suffix(2)), at: 0)
            head.removeLast(2)
        }
        if !head.isEmpty { groups.insert(String(head), at: 0) }
        return (groups + [last3]).joined(separator: ",")
    }

    /// Unit price line: "₹62 per 100 g".
    public static func unitPrice(_ amount: Decimal, per unit: String) -> String {
        "\(format(amount, style: .compact)) per \(unit)"
    }

    /// Exact sum, for totals shown in components (callers pass already-computed line amounts).
    public static func sum(_ amounts: [Decimal]) -> Decimal {
        amounts.reduce(Decimal(0), +)
    }
}

/// How a chart or component writes an amount. Money is rupees (`.rupees`, Indian grouping); model costs
/// are US dollars (`.usDollars`). `Decimal` in, string out; no floating point.
public struct ZoroAmountFormatter: Sendable {
    /// ISO 4217 code, e.g. "INR", "USD".
    public let currencyCode: String
    private let render: @Sendable (Decimal, ZoroMoney.Style) -> String

    public init(currencyCode: String, render: @escaping @Sendable (Decimal, ZoroMoney.Style) -> String) {
        self.currencyCode = currencyCode.uppercased()
        self.render = render
    }

    public func string(_ amount: Decimal, style: ZoroMoney.Style = .exact) -> String { render(amount, style) }

    /// Rupees with Indian grouping: ₹1,23,456.50.
    public static let rupees = ZoroAmountFormatter(currencyCode: "INR") { ZoroMoney.format($0, style: $1) }

    /// US dollars as providers bill them: four fractional digits under one dollar ($0.0042), two from
    /// one dollar up ($12.50), thousands grouping; `.whole` rounds to dollars.
    public static let usDollars = ZoroAmountFormatter(currencyCode: "USD") { amount, style in
        let magnitude = amount < 0 ? -amount : amount
        let scale = style == .whole ? 0 : (magnitude < 1 && magnitude != 0 ? 4 : 2)
        return ZoroMoney.formatWestern(amount, symbol: "$", scale: scale)
    }

    /// `INR` → `.rupees`, `USD` → `.usDollars`; any other code is written as "EUR 1,234.50".
    public static func currency(code: String) -> ZoroAmountFormatter {
        switch code.uppercased() {
        case "INR": .rupees
        case "USD": .usDollars
        default:
            ZoroAmountFormatter(currencyCode: code) { amount, style in
                ZoroMoney.formatWestern(amount, symbol: code.uppercased() + " ", scale: style == .whole ? 0 : 2)
            }
        }
    }
}

extension ZoroMoney {
    /// `symbol` + thousands-grouped amount with exactly `scale` fractional digits, half away from zero.
    public static func formatWestern(_ amount: Decimal, symbol: String, scale: Int) -> String {
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, scale, .plain)
        let negative = rounded < 0
        let magnitude = negative ? -rounded : rounded
        let raw = NSDecimalNumber(decimal: magnitude).stringValue
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        let integer = String(parts.first ?? "0")
        var grouped: [Character] = []
        for (i, ch) in integer.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { grouped.append(",") }
            grouped.append(ch)
        }
        var text = symbol + String(grouped.reversed())
        if scale > 0 {
            let fraction = parts.count > 1 ? String(parts[1]) : ""
            text += "." + String((fraction + String(repeating: "0", count: scale)).prefix(scale))
        }
        return negative && magnitude != 0 ? minus + text : text
    }
}
