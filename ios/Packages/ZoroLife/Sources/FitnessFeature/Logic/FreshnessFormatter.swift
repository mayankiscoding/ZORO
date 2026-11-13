import Foundation
import LifeSupport

/// Wording for "how old is this figure". Every fitness number shows a data source and a freshness line.
public enum FreshnessFormatter {
    /// "just now", "5 minutes ago", "1 hour ago", "3 days ago"; nil when nothing was ever synced.
    /// Uses `lastSyncedAt` against `now` when the server sent it (so the text keeps up with the clock), otherwise the
    /// server's own `age_value` / `age_unit`.
    public static func age(_ freshness: FitnessFreshness, now: Date) -> String? {
        let value: Int
        let unit: FitnessFreshness.Unit
        if let last = freshness.lastSyncedAt {
            let seconds = max(now.timeIntervalSince(last), 0)
            if seconds < 3600 {
                (value, unit) = (Int(seconds / 60), .minutes)
            } else if seconds < 2 * 86400 {
                (value, unit) = (Int(seconds / 3600), .hours)
            } else {
                (value, unit) = (Int(seconds / 86400), .days)
            }
        } else if let v = freshness.ageValue, let u = freshness.ageUnit {
            (value, unit) = (v, u)
        } else {
            return nil
        }
        if unit == .minutes && value == 0 { return "just now" }
        let noun = value == 1 ? String(unit.rawValue.dropLast()) : unit.rawValue
        return "\(value) \(noun) ago"
    }

    /// "From Apple Health (synced from your iPhone), synced 2 hours ago." or "Nothing has been synced yet."
    public static func line(source: String, freshness: FitnessFreshness, now: Date) -> String {
        guard let age = age(freshness, now: now) else {
            return "From \(source). Nothing has been synced yet."
        }
        return age == "just now" ? "From \(source), synced just now." : "From \(source), synced \(age)."
    }

    /// The warning that goes with a stale figure, with what to do next. nil when the data is fresh.
    public static func staleNote(_ freshness: FitnessFreshness) -> String? {
        if freshness.neverSynced { return "Nothing has been synced yet. Tap Sync now to bring in your Health data." }
        return freshness.stale ? "This may be out of date. Tap Sync now for current figures." : nil
    }

    /// "Latest day: 13 Nov" or nil.
    public static func latestDay(_ freshness: FitnessFreshness) -> String? {
        freshness.latestDataDate.map { "Latest day: \(LifeFormat.shortDay($0))" }
    }
}
