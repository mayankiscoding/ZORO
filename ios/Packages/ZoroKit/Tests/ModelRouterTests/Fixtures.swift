import Foundation
import ZoroCore
@testable import ModelRouter

/// Friday 13 November 2026, 10:00 in India (UTC+05:30). Every parsing test runs against this moment.
enum Fixed {
    static let timeZone = TimeZone(identifier: "Asia/Kolkata")!
    static let now = ZoroJSON.parseDate("2026-11-13T10:00:00+05:30")!

    static func classifier(assist: (any OnDeviceIntentAssisting)? = nil) -> LocalIntentClassifier {
        LocalIntentClassifier(clock: { now }, timeZone: timeZone, assist: assist)
    }

    static func intent(_ text: String) async -> LocalIntent? {
        await classifier().classify(text, languageHint: nil)
    }

    static func photoParser() -> PhotoQueryParser {
        PhotoQueryParser(clock: { now }, timeZone: timeZone)
    }
}

extension LocalIntent {
    func string(_ key: String) -> String? { slots[key]?.stringValue }
    func int(_ key: String) -> Int? { slots[key]?.intValue }
}
