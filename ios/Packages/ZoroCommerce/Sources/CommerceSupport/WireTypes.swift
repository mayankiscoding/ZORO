import Foundation
import ZoroCore

// Wire types shared by the commerce DTOs. Money and quantities arrive as decimal strings (Pydantic
// `Decimal` in JSON mode) and become `Decimal` here; a bare JSON number is rejected so nothing passes
// through floating point. Calendar dates (`date`) arrive as "YYYY-MM-DD".

/// A non-optional decimal decoded from a JSON string. `@WireDecimal var amount: Decimal`.
@propertyWrapper
public struct WireDecimal: Codable, Sendable, Hashable {
    public var wrappedValue: Decimal

    public init(wrappedValue: Decimal) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        guard let value = DecimalString.parse(raw) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a decimal string: \(raw)")
        }
        wrappedValue = value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(DecimalString.format(wrappedValue))
    }
}

/// An optional decimal decoded from a JSON string, `null` or a missing key.
@propertyWrapper
public struct WireDecimalOptional: Codable, Sendable, Hashable {
    public var wrappedValue: Decimal?

    public init(wrappedValue: Decimal?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            wrappedValue = nil
            return
        }
        wrappedValue = try WireDecimal(from: decoder).wrappedValue
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let value = wrappedValue {
            try c.encode(DecimalString.format(value))
        } else {
            try c.encodeNil()
        }
    }
}

extension KeyedDecodingContainer {
    /// Lets synthesized `Decodable` treat a missing key as `nil` for `@WireDecimalOptional`.
    public func decode(_ type: WireDecimalOptional.Type, forKey key: Key) throws -> WireDecimalOptional {
        try decodeIfPresent(type, forKey: key) ?? WireDecimalOptional(wrappedValue: nil)
    }
}

/// A calendar day as the server sends it ("2026-11-13"), without a time or time zone.
public struct CalendarDay: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(_ raw: String) {
        let parts = raw.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        guard let value = CalendarDay(raw) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a calendar day: \(raw)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Noon in the given time zone, for charts and display (never shifts the day).
    public func date(in timeZone: TimeZone = TimeZone(identifier: "Asia/Kolkata")!) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date(timeIntervalSince1970: 0)
    }

    /// "13 Nov 2026".
    public var display: String {
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(day) \(names[month - 1]) \(year)"
    }

    /// "13 Nov".
    public var shortDisplay: String {
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(day) \(names[month - 1])"
    }
}

/// Decodes a payload with the shared contract decoder (used by card views and tests).
public enum CommerceJSON {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try ZoroJSON.decoder().decode(T.self, from: data)
    }
}
