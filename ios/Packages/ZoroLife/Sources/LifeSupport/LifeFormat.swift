import Foundation
import ZoroCore
import ZoroDesign

/// Number, date and time text for the life screens. Pure functions: nothing here reads the clock or the locale
/// unless it is passed in, so tests are exact.
public enum LifeFormat {
    /// A whole count with Indian digit grouping: 8421 becomes "8,421", 123456 becomes "1,23,456".
    public static func count(_ value: Int) -> String {
        let text = ZoroMoney.groupIndian(String(abs(value)))
        return value < 0 ? ZoroMoney.minus + text : text
    }

    /// A measurement: whole numbers without a fraction, otherwise at most `places` digits, trailing zeros dropped.
    /// "6.1", "412", "6.7". Not for money.
    public static func number(_ value: Double, places: Int = 1) -> String {
        guard value.isFinite else { return "Not known" }
        let factor = pow(10.0, Double(places))
        let rounded = (abs(value) * factor).rounded(.toNearestOrAwayFromZero) / factor
        var text = String(format: "%.\(places)f", rounded)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        let isZero = Double(text) == 0
        if rounded >= 1000 {
            let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            text = ZoroMoney.groupIndian(parts[0]) + (parts.count > 1 ? "." + parts[1] : "")
        }
        return value < 0 && !isZero ? ZoroMoney.minus + text : text
    }

    /// "+12%" or "\u{2212}5.6%": a signed change in percent.
    public static func signedPercent(_ value: Double, places: Int = 1) -> String {
        let text = number(abs(value), places: places)
        if Double(text.replacingOccurrences(of: ",", with: "")) == 0 { return "0%" }
        return (value < 0 ? ZoroMoney.minus : "+") + text + "%"
    }

    /// Seconds per kilometre as "6:24".
    public static func pace(secondsPerKm: Double) -> String {
        let total = Int(secondsPerKm.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "13 Nov".
    public static func shortDay(_ day: CalendarDate) -> String {
        "\(day.day) \(monthNames[day.month - 1])"
    }

    /// "13 Nov 2026".
    public static func fullDay(_ day: CalendarDate) -> String {
        "\(day.day) \(monthNames[day.month - 1]) \(day.year)"
    }

    /// "4:12 pm" when `date` is on the same day as `now`, otherwise "12 Nov". India locale, 12-hour clock.
    public static func moment(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_IN")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(date, inSameDayAs: now) ? "hmma" : "dMMM")
        return formatter.string(from: date)
    }

    /// A track position: "1:05", or "1:02:03" past an hour.
    public static func clock(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}

/// Pauses between polls. Injected so tests never wait.
public typealias LifeSleep = @Sendable (Duration) async throws -> Void

public enum LifeSleeper {
    public static let real: LifeSleep = { try await Task.sleep(for: $0) }
}
