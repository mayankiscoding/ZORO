import Foundation

/// JSON coders for the backend contract. Keys are mapped by explicit `CodingKeys` (snake_case on the
/// wire), never by a key strategy, so free-form payload keys (`UICard.payload`, `args`) stay untouched.
public enum ZoroJSON {
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let raw = try c.decode(String.self)
            guard let date = parseDate(raw) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO-8601 date: \(raw)")
            }
            return date
        }
        return d
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatDate(date))
        }
        return e
    }

    /// Parses ISO-8601 with `Z` or a `±HH:MM` offset, with or without fractional seconds (any digits).
    public static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 19 else { return nil }
        let chars = Array(s.utf8)
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= chars.count else { return nil }
            var v = 0
            for i in from..<(from + len) {
                let ch = chars[i]
                guard ch >= 48, ch <= 57 else { return nil }
                v = v * 10 + Int(ch - 48)
            }
            return v
        }
        guard let year = num(0, 4), chars[4] == UInt8(ascii: "-"), let month = num(5, 2),
              chars[7] == UInt8(ascii: "-"), let day = num(8, 2),
              chars[10] == UInt8(ascii: "T") || chars[10] == UInt8(ascii: "t") || chars[10] == UInt8(ascii: " "),
              let hour = num(11, 2), chars[13] == UInt8(ascii: ":"), let minute = num(14, 2),
              chars[16] == UInt8(ascii: ":"), let second = num(17, 2)
        else { return nil }
        var idx = 19
        var fraction = 0.0
        if idx < chars.count, chars[idx] == UInt8(ascii: ".") {
            idx += 1
            var scale = 0.1
            let start = idx
            while idx < chars.count, chars[idx] >= 48, chars[idx] <= 57 {
                fraction += Double(chars[idx] - 48) * scale
                scale /= 10
                idx += 1
            }
            if idx == start { return nil }
        }
        var offsetSeconds = 0
        if idx >= chars.count { return nil }  // timezone is mandatory (AwareDatetime)
        let tz = chars[idx]
        if tz == UInt8(ascii: "Z") || tz == UInt8(ascii: "z") {
            idx += 1
        } else if tz == UInt8(ascii: "+") || tz == UInt8(ascii: "-") {
            guard let oh = num(idx + 1, 2) else { return nil }
            var om = 0
            if idx + 3 < chars.count, chars[idx + 3] == UInt8(ascii: ":") {
                guard let m = num(idx + 4, 2) else { return nil }
                om = m
                idx += 6
            } else if let m = num(idx + 3, 2) {
                om = m
                idx += 5
            } else {
                idx += 3
            }
            offsetSeconds = (oh * 3600 + om * 60) * (tz == UInt8(ascii: "+") ? 1 : -1)
        } else {
            return nil
        }
        guard idx == chars.count else { return nil }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61,
              let base = cal.date(from: comps)
        else { return nil }
        return base.addingTimeInterval(fraction - Double(offsetSeconds))
    }

    /// UTC with `Z`. Fractional seconds (microsecond precision, like Pydantic) only when present.
    public static func formatDate(_ date: Date) -> String {
        var whole = date.timeIntervalSince1970.rounded(.down)
        var micros = Int(((date.timeIntervalSince1970 - whole) * 1_000_000).rounded())
        if micros >= 1_000_000 {
            whole += 1
            micros -= 1_000_000
        }
        let base = isoSeconds(Date(timeIntervalSince1970: whole))
        guard micros > 0 else { return base }
        var fraction = String(format: "%06d", micros)
        while fraction.count > 3, fraction.hasSuffix("0") { fraction.removeLast() }
        return String(base.dropLast()) + "." + fraction + "Z"
    }

    /// `yyyy-MM-ddTHH:mm:ssZ` in UTC: the canonical timestamp inside signed strings.
    public static func isoSeconds(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// Truncates to whole seconds (signed timestamps carry no fraction).
    public static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

// MARK: - Decimal as string

public enum DecimalString {
    public static func parse(_ s: String) -> Decimal? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || "+-.eE".contains($0)) }),
              let d = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        return d
    }

    public static func format(_ d: Decimal) -> String {
        var copy = d
        return NSDecimalString(&copy, Locale(identifier: "en_US_POSIX"))
    }
}

extension KeyedDecodingContainer {
    /// Money and costs are decimal strings on the wire; a bare JSON number is rejected for exactness.
    public func decodeDecimalString(forKey key: Key) throws -> Decimal {
        let raw = try decode(String.self, forKey: key)
        guard let d = DecimalString.parse(raw) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "not a decimal string: \(raw)")
        }
        return d
    }

    public func decodeDecimalStringIfPresent(forKey key: Key) throws -> Decimal? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeDecimalString(forKey: key)
    }
}

extension KeyedEncodingContainer {
    public mutating func encodeDecimalString(_ value: Decimal, forKey key: Key) throws {
        try encode(DecimalString.format(value), forKey: key)
    }
}
