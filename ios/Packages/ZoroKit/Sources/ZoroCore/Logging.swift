import Foundation
import os

/// Privacy-aware logging. Identifiers and states are public; user content is either omitted or passed
/// through `ZoroLog.redact` and still marked private, so it never reaches a sysdiagnose in clear.
public struct ZoroLog: Sendable {
    public static let subsystem = "app.zoro"

    private let logger: Logger
    public let category: String

    public init(_ category: String) {
        self.category = category
        self.logger = Logger(subsystem: Self.subsystem, category: category)
    }

    /// Operational event: only non-sensitive identifiers belong in `message`.
    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    /// Error with its category; the description is redacted and private.
    public func error(_ message: String, error: Error? = nil) {
        let detail = error.map { Self.redact(String(describing: $0)) } ?? ""
        logger.error("\(message, privacy: .public) \(detail, privacy: .private)")
    }

    /// User content (transcripts, card text). Redacted, then private.
    public func content(_ label: String, _ text: String) {
        logger.debug("\(label, privacy: .public): \(Self.redact(text), privacy: .private)")
    }

    // MARK: - Redaction

    private static let patterns: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            (#"(?i)bearer\s+[A-Za-z0-9\-\._~\+/]+=*"#, "Bearer [token]"),
            (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "[email]"),
            (#"[A-Za-z0-9.\-_]{2,}@[A-Za-z]{2,}"#, "[upi]"),
            (#"\b[A-Z]{5}[0-9]{4}[A-Z]\b"#, "[pan]"),
            (#"\+?\d[\d \-]{7,}\d"#, "[number]"),
        ]
        return specs.compactMap { spec in
            (try? NSRegularExpression(pattern: spec.0)).map { ($0, spec.1) }
        }
    }()

    /// Masks emails, UPI ids, PAN, bearer tokens and long digit runs (phone, card, account, Aadhaar).
    public static func redact(_ text: String) -> String {
        var out = text
        for (regex, replacement) in patterns {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: replacement)
        }
        return out
    }
}
