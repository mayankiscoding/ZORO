import Foundation
import LifeSupport
import ZoroCore

/// One chip showing how the query was understood.
public struct PhotoQueryChip: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable { case date, color, label, text, media }
    public var kind: Kind
    public var label: String
    public var id: String { "\(kind.rawValue):\(label)" }

    public var symbol: String {
        switch kind {
        case .date: "calendar"
        case .color: "paintpalette"
        case .label: "tag"
        case .text: "text.quote"
        case .media: "photo"
        }
    }

    /// "Date: 12 Nov 2026", "Colour: blue", "Thing: cap".
    public var accessibilityLabel: String {
        let prefix: String
        switch kind {
        case .date: prefix = "Date"
        case .color: prefix = "Colour"
        case .label: prefix = "Thing"
        case .text: prefix = "Text in the photo"
        case .media: prefix = "Kind"
        }
        return "\(prefix): \(label)"
    }
}

public enum PhotoQueryChips {
    /// The chips for a query, in the server's order: date, colours, things, text, kind. (Same kinds and words as
    /// `query_chips` in backend/app/vision/summaries.py; dates are written for people instead of ISO.)
    public static func chips(for q: PhotoQuery) -> [PhotoQueryChip] {
        var out: [PhotoQueryChip] = []
        switch (q.dateFrom, q.dateTo) {
        case (let from?, let to?):
            out.append(PhotoQueryChip(kind: .date, label: from == to ? LifeFormat.fullDay(from) : "\(LifeFormat.fullDay(from)) to \(LifeFormat.fullDay(to))"))
        case (let from?, nil):
            out.append(PhotoQueryChip(kind: .date, label: "From \(LifeFormat.fullDay(from))"))
        case (nil, let to?):
            out.append(PhotoQueryChip(kind: .date, label: "Until \(LifeFormat.fullDay(to))"))
        default:
            break
        }
        out += q.colors.map { PhotoQueryChip(kind: .color, label: $0) }
        out += q.labels.map { PhotoQueryChip(kind: .label, label: $0) }
        if let text = q.containsText, !text.isEmpty { out.append(PhotoQueryChip(kind: .text, label: "\u{201C}\(text)\u{201D}")) }
        switch q.media {
        case .screenshot: out.append(PhotoQueryChip(kind: .media, label: "Screenshots only"))
        case .photo: out.append(PhotoQueryChip(kind: .media, label: "Photos only"))
        case .any: break
        }
        return out
    }

    /// Chips from a card payload: the server already chose them, and their kinds map onto the same cases.
    public static func chips(from card: [PhotoCardChip], query: PhotoQuery) -> [PhotoQueryChip] {
        let own = chips(for: query)
        return own.isEmpty ? card.compactMap { c in PhotoQueryChip.Kind(rawValue: c.kind).map { PhotoQueryChip(kind: $0, label: c.label) } } : own
    }
}

/// Words for why a photo matched and what it is, for the grid and VoiceOver.
public enum PhotoHitPresenter {
    /// "cap", "blue", "text “sale”", "similar look", "date", "screenshot".
    public static func matchedPhrases(_ matched: [String]) -> [String] {
        matched.compactMap { token in
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            switch (parts.first, parts.count > 1 ? parts[1] : nil) {
            case ("label", let v?), ("color", let v?): return v
            case ("text", let v?): return "text \u{201C}\(v)\u{201D}"
            case ("media", let v?): return v
            case ("similar", _): return "similar look"
            case ("date", _): return "date"
            default: return nil
            }
        }
    }

    /// "Photo from 12 Nov, matched cap and blue." Used as the VoiceOver label of a thumbnail.
    public static func accessibilityLabel(capturedAt: Date?, labels: [String], matched: [String], now: Date, timeZone: TimeZone) -> String {
        var text = "Photo"
        if let capturedAt { text += " from \(LifeFormat.moment(capturedAt, now: now, timeZone: timeZone))" }
        let reasons = matchedPhrases(matched)
        let shown = reasons.isEmpty ? Array(labels.prefix(3)) : reasons
        if !shown.isEmpty {
            text += reasons.isEmpty ? ", shows " : ", matched "
            text += shown.count == 1 ? shown[0] : shown.dropLast().joined(separator: ", ") + " and " + shown.last!
        }
        return text + "."
    }
}

/// How the index looks on screen.
public struct IndexPresentation: Sendable, Equatable {
    public var symbol: String
    public var headline: String
    public var detail: String
    /// 0...1 while indexing or paused with a known total; nil otherwise.
    public var progress: Double?
    public var lastRun: String?
    public var rebuildTitle: String
    public var canRebuild: Bool
    public var canDelete: Bool
    public var isBusy: Bool

    public var accessibilityLabel: String {
        var parts = [headline, detail]
        if let progress { parts.append("\(Int((progress * 100).rounded())) percent") }
        if let lastRun { parts.append(lastRun) }
        return parts.joined(separator: ". ")
    }
}

public enum IndexPresenter {
    public static func presentation(_ s: PhotoIndexStatus, now: Date, timeZone: TimeZone = .current) -> IndexPresentation {
        let indexed = LifeFormat.count(s.indexedCount)
        let total = LifeFormat.count(s.totalCount)
        let fraction: Double? = s.totalCount > 0 ? min(max(Double(s.indexedCount) / Double(s.totalCount), 0), 1) : nil
        let lastRun = s.lastUpdatedAt.map { "Last updated \(LifeFormat.moment($0, now: now, timeZone: timeZone))" }
        switch s.state {
        case .notStarted:
            return IndexPresentation(
                symbol: "square.stack.3d.up", headline: "Your photos are not indexed yet",
                detail: "Build the index to search by date, colour and what is in a photo. It is made on this device and nothing leaves it.",
                progress: nil, lastRun: lastRun, rebuildTitle: "Build index", canRebuild: true, canDelete: false, isBusy: false)
        case .indexing:
            return IndexPresentation(
                symbol: "arrow.triangle.2.circlepath",
                headline: s.totalCount > 0 ? "Indexing: \(indexed) of \(total) photos" : "Indexing your photos",
                detail: "You can search what is indexed so far. Keep the app open for it to finish sooner.",
                progress: fraction, lastRun: lastRun, rebuildTitle: "Rebuild index", canRebuild: false, canDelete: false, isBusy: true)
        case .paused:
            return IndexPresentation(
                symbol: "pause.circle", headline: "Indexing is paused: \(indexed) of \(total) photos",
                detail: pausedSentence(s.pausedReason), progress: fraction, lastRun: lastRun, rebuildTitle: "Rebuild index",
                canRebuild: true, canDelete: true, isBusy: false)
        case .ready:
            let all = s.totalCount == 0 || s.indexedCount >= s.totalCount
            return IndexPresentation(
                symbol: "checkmark.circle",
                headline: all ? "\(indexed) photos indexed" : "\(indexed) of \(total) photos indexed",
                detail: all ? "Search covers all of them." : "Search covers the indexed photos. Rebuild to pick up the rest.",
                progress: nil, lastRun: lastRun, rebuildTitle: "Rebuild index", canRebuild: true, canDelete: true, isBusy: false)
        case .failed:
            return IndexPresentation(
                symbol: "exclamationmark.triangle", headline: "Indexing stopped",
                detail: (s.failureReason.map { $0.hasSuffix(".") ? $0 : $0 + "." } ?? "Something went wrong.") + " Tap Rebuild index to try again.",
                progress: nil, lastRun: lastRun, rebuildTitle: "Rebuild index", canRebuild: true, canDelete: true, isBusy: false)
        }
    }

    static func pausedSentence(_ reason: String?) -> String {
        switch reason {
        case "low_power": "Paused to save battery. It continues when Low Power Mode is off."
        case "thermal": "Paused while the device cools down. It continues by itself."
        case nil: "Paused. It continues when conditions allow."
        case let other?: "Paused (\(other.replacingOccurrences(of: "_", with: " "))). It continues when conditions allow."
        }
    }
}

/// What to tell the owner about photo access, and the one action that helps.
public struct PhotoAccessPresentation: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case allowAccess
        case choosePhotos
        case checkAgain
    }

    public var symbol: String
    public var message: String
    public var actionTitle: String?
    public var action: Action?

    public static func presentation(_ a: MediaAuthorization, isMac: Bool = Platform.isMac) -> PhotoAccessPresentation? {
        switch a {
        case .authorized:
            return nil
        case .notDetermined:
            return PhotoAccessPresentation(
                symbol: "photo.on.rectangle", message: "ZORO searches your photos on this device; they don't leave it. Allow access to start.",
                actionTitle: "Allow photo access", action: .allowAccess)
        case .limited:
            return PhotoAccessPresentation(
                symbol: "photo.badge.plus", message: "ZORO can only search the photos you chose. Add more to search them too.",
                actionTitle: isMac ? nil : "Choose more photos", action: isMac ? nil : .choosePhotos)
        case .denied:
            return PhotoAccessPresentation(
                symbol: "lock", message: isMac
                    ? "Photo access is off. Open System Settings, then Privacy and Security, then Photos, and turn on ZORO."
                    : "Photo access is off. Open Settings, then ZORO, then Photos, and choose Full Access or Limited Access.",
                actionTitle: "Check again", action: .checkAgain)
        case .restricted:
            return PhotoAccessPresentation(
                symbol: "lock.slash",
                message: "Photo access is restricted on this device, for example by Screen Time or a profile. ZORO cannot search photos until it is allowed.",
                actionTitle: "Check again", action: .checkAgain)
        }
    }
}

public enum Platform {
    public static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}
