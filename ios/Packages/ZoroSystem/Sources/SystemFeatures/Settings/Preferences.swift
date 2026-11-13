import Foundation

/// Small per-device preferences that never leave the device (appearance).
public protocol PreferencesStoring: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

/// `UserDefaults`-backed store. `UserDefaults` is thread-safe.
public final class UserDefaultsPreferences: PreferencesStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "zoro.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func string(forKey key: String) -> String? { defaults.string(forKey: prefix + key) }
    public func set(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: prefix + key) } else { defaults.removeObject(forKey: prefix + key) }
    }
}

/// In-memory store for previews and tests.
public final class InMemoryPreferences: PreferencesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init(_ initial: [String: String] = [:]) { values = initial }
    public func string(forKey key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ value: String?, forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = value }
}

public enum AppearancePreference: String, CaseIterable, Sendable, Equatable {
    case system, light, dark

    public var title: String {
        switch self {
        case .system: "Match this device"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public static let storageKey = "appearance"
}
