import Foundation

/// A calendar day without a time or zone (`"YYYY-MM-DD"` on the wire), e.g. `date_from` of a `PhotoQuery`.
public struct CalendarDate: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    /// Fails unless `year`-`month`-`day` is a real Gregorian day.
    public init?(year: Int, month: Int, day: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.day, from: date) == day
        else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `"YYYY-MM-DD"` exactly.
    public init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard string.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The local day that contains `date` in `timeZone`.
    public init(date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        year = c.year ?? 1970
        month = c.month ?? 1
        day = c.day ?? 1
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Midnight at the start of this day in `timeZone`.
    public func start(in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(timeZone: timeZone, year: year, month: month, day: day))
    }

    public static func < (a: CalendarDate, b: CalendarDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        guard let value = CalendarDate(raw) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a YYYY-MM-DD date: \(raw)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// What kind of still image an asset is. Videos are not indexed. A live photo counts as a photo for
/// the `media` filter.
public enum PhotoMediaKind: String, Sendable, Codable, CaseIterable {
    case photo
    case screenshot
    case livePhoto = "live_photo"
}

/// The `PhotoQuery` of `docs/architecture/device-contract.md` (the `query` argument of
/// `device.photos.search`), plus an optional paging `cursor`. Snake_case JSON.
public struct PhotoQuery: Sendable, Equatable, Codable {
    public enum Media: String, Sendable, Codable, CaseIterable {
        case photo, screenshot, any

        public func admits(_ kind: PhotoMediaKind) -> Bool {
            switch self {
            case .any: true
            case .photo: kind != .screenshot
            case .screenshot: kind == .screenshot
            }
        }
    }

    /// The arguments break the contract (maps to `invalid_arguments`).
    public struct ValidationError: Error, Sendable, Equatable, CustomStringConvertible {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
        public var description: String { reason }
    }

    public static let defaultLimit = 30
    public static let maximumLimit = 100

    /// The owner's words.
    public var text: String
    /// First and last calendar day (inclusive) in the owner's time zone; nil = open.
    public var dateFrom: CalendarDate?
    public var dateTo: CalendarDate?
    public var colors: [String]
    public var labels: [String]
    public var containsText: String?
    public var media: Media
    /// 1...`maximumLimit`.
    public var limit: Int
    /// Opaque position from a previous result's `nextCursor`.
    public var cursor: String?

    public init(
        text: String = "", dateFrom: CalendarDate? = nil, dateTo: CalendarDate? = nil, colors: [String] = [],
        labels: [String] = [], containsText: String? = nil, media: Media = .any, limit: Int = PhotoQuery.defaultLimit,
        cursor: String? = nil
    ) {
        self.text = text
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.colors = colors
        self.labels = labels
        self.containsText = containsText
        self.media = media
        self.limit = min(max(1, limit), Self.maximumLimit)
        self.cursor = cursor
    }

    /// True when the query narrows nothing beyond the words.
    public var isUnfiltered: Bool {
        dateFrom == nil && dateTo == nil && colors.isEmpty && labels.isEmpty && containsText == nil && media == .any
    }

    /// From the start of `dateFrom` to the last instant of `dateTo` in `timeZone`; nil without dates.
    public func dateInterval(in timeZone: TimeZone) -> DateInterval? {
        guard dateFrom != nil || dateTo != nil else { return nil }
        let start = dateFrom.flatMap { $0.start(in: timeZone) } ?? .distantPast
        var end = Date.distantFuture
        if let to = dateTo, let toStart = to.start(in: timeZone) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            end = (calendar.date(byAdding: .day, value: 1, to: toStart) ?? toStart).addingTimeInterval(-0.001)
        }
        return start <= end ? DateInterval(start: start, end: end) : nil
    }

    // MARK: JSON

    enum CodingKeys: String, CodingKey {
        case text
        case dateFrom = "date_from"
        case dateTo = "date_to"
        case colors, labels
        case containsText = "contains_text"
        case media, limit, cursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
            dateFrom: try c.decodeIfPresent(CalendarDate.self, forKey: .dateFrom),
            dateTo: try c.decodeIfPresent(CalendarDate.self, forKey: .dateTo),
            colors: try c.decodeIfPresent([String].self, forKey: .colors) ?? [],
            labels: try c.decodeIfPresent([String].self, forKey: .labels) ?? [],
            containsText: try c.decodeIfPresent(String.self, forKey: .containsText),
            media: try c.decodeIfPresent(Media.self, forKey: .media) ?? .any,
            limit: try c.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit,
            cursor: try c.decodeIfPresent(String.self, forKey: .cursor))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(dateFrom, forKey: .dateFrom)
        try c.encode(dateTo, forKey: .dateTo)
        try c.encode(colors, forKey: .colors)
        try c.encode(labels, forKey: .labels)
        try c.encode(containsText, forKey: .containsText)
        try c.encode(media, forKey: .media)
        try c.encode(limit, forKey: .limit)
        try c.encodeIfPresent(cursor, forKey: .cursor)
    }

    /// Contract JSON object (nulls for missing values; `cursor` only when set).
    public var json: JSONObject {
        var o: JSONObject = [
            "text": .string(text),
            "date_from": dateFrom.map { .string($0.description) } ?? .null,
            "date_to": dateTo.map { .string($0.description) } ?? .null,
            "colors": .array(colors.map(JSONValue.string)),
            "labels": .array(labels.map(JSONValue.string)),
            "contains_text": containsText.map(JSONValue.string) ?? .null,
            "media": .string(media.rawValue),
            "limit": .number(Double(limit)),
        ]
        if let cursor { o["cursor"] = .string(cursor) }
        return o
    }

    /// Validating parse of the `query` argument. Dates are `YYYY-MM-DD`; an ISO-8601 timestamp is
    /// accepted too and taken as its local day in `timeZone`.
    public init(json: JSONObject, timeZone: TimeZone) throws {
        func strings(_ key: String) throws -> [String] {
            guard let value = json[key], value != .null else { return [] }
            guard let array = value.arrayValue else { throw ValidationError("\(key) must be a list of strings") }
            return try array.map {
                guard let s = $0.stringValue else { throw ValidationError("\(key) must be a list of strings") }
                return s
            }
        }
        func optionalString(_ key: String) throws -> String? {
            guard let value = json[key], value != .null else { return nil }
            guard let s = value.stringValue else { throw ValidationError("\(key) must be a string") }
            return s
        }
        func day(_ key: String) throws -> CalendarDate? {
            guard let raw = try optionalString(key) else { return nil }
            if let d = CalendarDate(raw) { return d }
            if let instant = ZoroJSON.parseDate(raw) { return CalendarDate(date: instant, timeZone: timeZone) }
            throw ValidationError("\(key) is not a date")
        }
        var media = Media.any
        if let raw = try optionalString("media") {
            guard let parsed = Media(rawValue: raw) else { throw ValidationError("media must be photo, screenshot or any") }
            media = parsed
        }
        var limit = Self.defaultLimit
        if let value = json["limit"], value != .null {
            guard let n = value.intValue, n > 0 else { throw ValidationError("limit must be a positive integer") }
            limit = n
        }
        let from = try day("date_from")
        let to = try day("date_to")
        if let from, let to, from > to { throw ValidationError("date_from is after date_to") }
        self.init(
            text: try optionalString("text") ?? "", dateFrom: from, dateTo: to, colors: try strings("colors"),
            labels: try strings("labels"), containsText: try optionalString("contains_text").flatMap { $0.isEmpty ? nil : $0 },
            media: media, limit: limit, cursor: try optionalString("cursor"))
    }
}

/// One search result (`hits[]` of `device.photos.search`). Identifiers and metadata only, never image bytes.
public struct PhotoHit: Sendable, Equatable, Identifiable, Codable {
    /// The Photos local identifier.
    public var assetId: String
    public var capturedAt: Date?
    public var score: Double
    public var labels: [String]
    /// Why it matched: `label:<label>`, `color:<name>`, `text:<word>`, `similar`, `date`, `media:<kind>`.
    public var matched: [String]
    public var media: PhotoMediaKind
    public var id: String { assetId }

    public init(
        assetId: String, capturedAt: Date? = nil, score: Double, labels: [String] = [], matched: [String] = [],
        media: PhotoMediaKind = .photo
    ) {
        self.assetId = assetId
        self.capturedAt = capturedAt
        self.score = score
        self.labels = labels
        self.matched = matched
        self.media = media
    }

    enum CodingKeys: String, CodingKey {
        case assetId = "asset_id"
        case capturedAt = "captured_at"
        case score, labels, matched, media
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetId = try c.decode(String.self, forKey: .assetId)
        capturedAt = try c.decodeIfPresent(Date.self, forKey: .capturedAt)
        score = try c.decode(Double.self, forKey: .score)
        labels = try c.value(.labels, default: [])
        matched = try c.value(.matched, default: [])
        media = try c.value(.media, default: .photo)
    }
}

/// The result of `device.photos.search`.
public struct PhotoSearchResult: Sendable, Equatable, Codable {
    public var hits: [PhotoHit]
    /// Assets in the on-device index when the search ran.
    public var indexedCount: Int
    /// The owner granted access to selected photos only.
    public var limitedLibrary: Bool
    /// Pass back as `PhotoQuery.cursor` for the next page; nil = last page.
    public var nextCursor: String?

    public init(hits: [PhotoHit], indexedCount: Int, limitedLibrary: Bool, nextCursor: String? = nil) {
        self.hits = hits
        self.indexedCount = indexedCount
        self.limitedLibrary = limitedLibrary
        self.nextCursor = nextCursor
    }

    enum CodingKeys: String, CodingKey {
        case hits
        case indexedCount = "indexed_count"
        case limitedLibrary = "limited_library"
        case nextCursor = "next_cursor"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hits = try c.value(.hits, default: [])
        indexedCount = try c.decode(Int.self, forKey: .indexedCount)
        limitedLibrary = try c.value(.limitedLibrary, default: false)
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

/// Progress of the on-device photo index.
public struct PhotoIndexStatus: Sendable, Equatable {
    public enum State: String, Sendable, CaseIterable {
        case notStarted = "not_started", indexing, paused, ready, failed
    }
    public var state: State
    public var indexedCount: Int
    public var totalCount: Int
    public var lastUpdatedAt: Date?
    public var failureReason: String?
    /// Why indexing is paused (for example `low_power`, `thermal`); set only in `.paused`.
    public var pausedReason: String?

    public init(
        state: State, indexedCount: Int = 0, totalCount: Int = 0, lastUpdatedAt: Date? = nil, failureReason: String? = nil,
        pausedReason: String? = nil
    ) {
        self.state = state
        self.indexedCount = indexedCount
        self.totalCount = totalCount
        self.lastUpdatedAt = lastUpdatedAt
        self.failureReason = failureReason
        self.pausedReason = pausedReason
    }
}
