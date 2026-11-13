import Foundation
import ZoroCore

/// Typed, validating access to a tool's `args`. Every failure is `DeviceActionError.invalidArgument`.
public struct ToolArguments: Sendable, Equatable {
    public let raw: JSONObject
    public init(_ raw: JSONObject) { self.raw = raw }

    private func present(_ key: String) -> JSONValue? {
        guard let v = raw[key], v != .null else { return nil }
        return v
    }

    public func string(_ key: String, maxLength: Int = 2000, allowEmpty: Bool = false) throws -> String? {
        guard let v = present(key) else { return nil }
        guard let s = v.stringValue else { throw DeviceActionError.invalidArgument(key, "must be a string") }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty && !allowEmpty { throw DeviceActionError.invalidArgument(key, "must not be empty") }
        if t.count > maxLength { throw DeviceActionError.invalidArgument(key, "is longer than \(maxLength) characters") }
        if t.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t" }) {
            throw DeviceActionError.invalidArgument(key, "contains control characters")
        }
        return t
    }

    public func requiredString(_ key: String, maxLength: Int = 2000) throws -> String {
        guard let s = try string(key, maxLength: maxLength) else { throw DeviceActionError.invalidArgument(key, "is required") }
        return s
    }

    public func int(_ key: String, range: ClosedRange<Int>) throws -> Int? {
        guard let v = present(key) else { return nil }
        guard let n = v.intValue else { throw DeviceActionError.invalidArgument(key, "must be a whole number") }
        guard range.contains(n) else {
            throw DeviceActionError.invalidArgument(key, "must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return n
    }

    /// ISO-8601 with an offset (`ZoroJSON.parseDate`).
    public func date(_ key: String) throws -> Date? {
        guard let v = present(key) else { return nil }
        guard let s = v.stringValue, let d = ZoroJSON.parseDate(s) else {
            throw DeviceActionError.invalidArgument(key, "must be an ISO-8601 time with an offset")
        }
        return d
    }

    public func requiredDate(_ key: String) throws -> Date {
        guard let d = try date(key) else { throw DeviceActionError.invalidArgument(key, "is required") }
        return d
    }

    public func stringArray(_ key: String, maxCount: Int, maxLength: Int = 200) throws -> [String]? {
        guard let v = present(key) else { return nil }
        guard let items = v.arrayValue else { throw DeviceActionError.invalidArgument(key, "must be a list") }
        guard items.count <= maxCount else { throw DeviceActionError.invalidArgument(key, "has more than \(maxCount) items") }
        return try items.map { item in
            guard let s = item.stringValue?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.count <= maxLength else {
                throw DeviceActionError.invalidArgument(key, "must contain non-empty strings")
            }
            return s
        }
    }

    public func enumValue<E: RawRepresentable>(_ key: String, as type: E.Type) throws -> E? where E.RawValue == String {
        guard let v = present(key) else { return nil }
        guard let s = v.stringValue, let e = E(rawValue: s) else {
            throw DeviceActionError.invalidArgument(key, "has an unsupported value")
        }
        return e
    }

    public func requiredEnum<E: RawRepresentable>(_ key: String, as type: E.Type) throws -> E where E.RawValue == String {
        guard let e = try enumValue(key, as: type) else { throw DeviceActionError.invalidArgument(key, "is required") }
        return e
    }

    /// A flat object of string values (AppleScript `params`).
    public func stringMap(_ key: String) throws -> [String: String]? {
        guard let v = present(key) else { return nil }
        guard let o = v.objectValue else { throw DeviceActionError.invalidArgument(key, "must be an object") }
        var out: [String: String] = [:]
        for (k, value) in o {
            switch value {
            case .string(let s): out[k] = s
            case .number: out[k] = value.intValue.map(String.init) ?? value.doubleValue.map { String($0) }
            case .bool(let b): out[k] = b ? "true" : "false"
            default: throw DeviceActionError.invalidArgument("\(key).\(k)", "must be a string, number or boolean")
            }
        }
        return out
    }
}

/// Wall-clock and timestamp formatting shared by handlers.
public enum DeviceTime {
    /// Parses `"HH:MM"` (24-hour).
    public static func parseClock(_ s: String) -> (hour: Int, minute: Int)? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m)
        else { return nil }
        return (h, m)
    }

    /// ISO-8601 with the given zone's offset, e.g. `2026-11-13T06:30:00+05:30`.
    public static func iso(_ date: Date, timeZone: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// `yyyy-MM-dd` in the calendar's time zone.
    public static func day(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
