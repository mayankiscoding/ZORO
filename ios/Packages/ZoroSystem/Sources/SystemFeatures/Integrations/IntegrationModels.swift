import Foundation
import ZoroCore

/// Where a capability is reported from.
public enum IntegrationSource: String, Sendable, Equatable, Hashable, CaseIterable {
    case server, device
}

/// The six plain-language groups the Integrations screen uses. Order here is the order on screen
/// and the order of "how restrictive" when the server and the device disagree.
public enum IntegrationGroup: Int, CaseIterable, Sendable, Equatable, Hashable, Comparable {
    case working
    case needsTap
    case needsCredentials
    case needsPartnerAgreement
    case notAllowedByIOS
    case notAvailable

    public static func < (lhs: IntegrationGroup, rhs: IntegrationGroup) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(status: CapabilityStatus) {
        switch status {
        case .workingNative, .workingLocal, .workingIntegration: self = .working
        case .manualUserStep: self = .needsTap
        case .requiresCredentials: self = .needsCredentials
        case .requiresPartnership: self = .needsPartnerAgreement
        case .restrictedByIos: self = .notAllowedByIOS
        case .unavailable: self = .notAvailable
        }
    }

    public var title: String {
        switch self {
        case .working: "Working"
        case .needsTap: "Needs a tap from you"
        case .needsCredentials: "Needs your credentials"
        case .needsPartnerAgreement: "Needs a partner agreement"
        case .notAllowedByIOS: "Not allowed by iOS"
        case .notAvailable: "Not available"
        }
    }

    /// One sentence on what the group means and what the owner can do about it.
    public var explanation: String {
        switch self {
        case .working: "Ready to use now."
        case .needsTap: "ZORO prepares it, and you finish it in the other app."
        case .needsCredentials: "Add the key or sign in on your ZORO server to turn this on."
        case .needsPartnerAgreement: "The provider only works with approved partners. ZORO can't connect until that exists."
        case .notAllowedByIOS: "iOS doesn't let apps do this, so ZORO doesn't pretend to."
        case .notAvailable: "Nothing in ZORO can do this today."
        }
    }

    public var symbol: String {
        switch self {
        case .working: "checkmark.circle"
        case .needsTap: "hand.tap"
        case .needsCredentials: "key"
        case .needsPartnerAgreement: "signature"
        case .notAllowedByIOS: "iphone.slash"
        case .notAvailable: "minus.circle"
        }
    }
}

public enum IntegrationCopy {
    public static func levelLabel(_ level: IntegrationLevel) -> String {
        switch level {
        case .fullyIntegrated: "Built in"
        case .officialApi: "Official connection"
        case .affiliateSearch: "Search through a partner link"
        case .deepLinkHandoff: "Opens the app with details ready"
        case .manualFallback: "You do the last step"
        case .unavailable: "No official route"
        }
    }

    public static func statusLabel(_ status: CapabilityStatus) -> String {
        switch status {
        case .workingNative: "Working on this device"
        case .workingLocal: "Working on your server"
        case .workingIntegration: "Working through a connection"
        case .requiresCredentials: "Needs your credentials"
        case .requiresPartnership: "Needs a partner agreement"
        case .manualUserStep: "Needs a tap from you"
        case .restrictedByIos: "Not allowed by iOS"
        case .unavailable: "Not available"
        }
    }
}

/// One row on the Integrations screen: a server capability, a device capability, or both merged.
public struct IntegrationItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var domain: String
    public var status: CapabilityStatus
    public var group: IntegrationGroup
    public var level: IntegrationLevel?
    public var requires: [String]
    public var note: String
    public var sources: Set<IntegrationSource>

    public var levelLabel: String? { level.map(IntegrationCopy.levelLabel) }
}

public struct IntegrationSection: Identifiable, Equatable, Sendable {
    public var group: IntegrationGroup
    public var items: [IntegrationItem]
    public var id: Int { group.rawValue }
}

public enum IntegrationGrouping {
    /// Merges the server registry with the device registry. The same id from both: the more
    /// restrictive group wins (the server knows about credentials, the device knows about what the OS
    /// allows, and the owner should see the reason a feature can't run). Titles prefer the server's.
    public static func merge(server: [Capability], device: [Capability]) -> [IntegrationItem] {
        var byId: [String: IntegrationItem] = [:]
        var order: [String] = []
        func add(_ c: Capability, source: IntegrationSource) {
            let group = IntegrationGroup(status: c.status)
            let candidate = IntegrationItem(
                id: c.id, title: c.title, domain: c.domain, status: c.status, group: group,
                level: c.integrationLevel, requires: c.requires, note: c.note, sources: [source])
            guard var existing = byId[c.id] else {
                byId[c.id] = candidate
                order.append(c.id)
                return
            }
            existing.sources.insert(source)
            if group > existing.group {
                existing.status = c.status
                existing.group = group
                existing.level = c.integrationLevel ?? existing.level
                existing.note = c.note.isEmpty ? existing.note : c.note
            }
            if existing.title.isEmpty { existing.title = c.title }
            for r in c.requires where !existing.requires.contains(r) { existing.requires.append(r) }
            byId[c.id] = existing
        }
        server.forEach { add($0, source: .server) }
        device.forEach { add($0, source: .device) }
        return order.compactMap { byId[$0] }
    }

    /// Items grouped under the six labels; empty groups are left out; items sorted by title.
    public static func sections(_ items: [IntegrationItem], domain: String? = nil, search: String = "") -> [IntegrationSection] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = items.filter { item in
            (domain == nil || item.domain == domain)
                && (q.isEmpty || item.title.lowercased().contains(q) || item.domain.lowercased().contains(q) || item.note.lowercased().contains(q))
        }
        return IntegrationGroup.allCases.compactMap { group in
            let inGroup = filtered.filter { $0.group == group }.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return inGroup.isEmpty ? nil : IntegrationSection(group: group, items: inGroup)
        }
    }
}

/// What this device can do natively, as capabilities. Implemented by the app shell from the native
/// action broker; the default adapter below uses `DeviceActionExecuting.supportedTools`.
public protocol DeviceCapabilityRegistry: Sendable {
    func capabilities() async -> [Capability]
}

/// Lists every tool the executor reports as supported, as "working on this device".
public struct ExecutorCapabilityRegistry: DeviceCapabilityRegistry {
    private let executor: any DeviceActionExecuting
    public init(executor: any DeviceActionExecuting) { self.executor = executor }

    public func capabilities() async -> [Capability] {
        await executor.supportedTools.sorted().map {
            Capability(id: $0, title: SystemFormat.toolTitle($0), domain: "device", status: .workingNative, integrationLevel: .fullyIntegrated)
        }
    }
}
