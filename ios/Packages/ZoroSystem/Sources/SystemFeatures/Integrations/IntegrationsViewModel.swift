import Foundation
import Observation
import ZoroCore

/// The capability registry from `GET /v1/capabilities`, merged with the device registry when one is
/// injected, grouped under plain labels. Read-only: turning an integration on happens on the server.
@MainActor
@Observable
public final class IntegrationsViewModel {
    public private(set) var phase: ScreenPhase = .idle
    public private(set) var items: [IntegrationItem] = []
    /// Set when only the device registry could be read.
    public private(set) var serverNote: String?

    public var domainFilter: String?
    public var searchText = ""

    @ObservationIgnored private let api: any ZoroAPI
    @ObservationIgnored private let deviceRegistry: (any DeviceCapabilityRegistry)?

    public init(api: any ZoroAPI, deviceRegistry: (any DeviceCapabilityRegistry)? = nil) {
        self.api = api
        self.deviceRegistry = deviceRegistry
    }

    public var domains: [String] { Array(Set(items.map(\.domain))).sorted() }

    public var sections: [IntegrationSection] {
        IntegrationGrouping.sections(items, domain: domainFilter, search: searchText)
    }

    public var workingCount: Int { items.filter { $0.group == .working }.count }

    public var summary: String {
        guard !items.isEmpty else { return "" }
        return "\(workingCount) of \(items.count) working."
    }

    public var emptyMessage: String {
        if items.isEmpty { return "No integrations are listed yet. Check that your ZORO server is up to date." }
        return "Nothing matches. Clear the filter or search to see everything."
    }

    public func load() async {
        phase = .loading
        serverNote = nil
        let device = await deviceRegistry?.capabilities() ?? []
        do {
            let server = try await api.capabilities()
            items = IntegrationGrouping.merge(server: server, device: device)
            phase = items.isEmpty ? .empty : .loaded
        } catch {
            guard let failure = SystemFailure.phase(for: error) else { return }
            if device.isEmpty {
                items = []
                phase = failure
            } else {
                items = IntegrationGrouping.merge(server: [], device: device)
                serverNote = "Showing only what this device can do. " + (failure.failure?.message ?? "")
                phase = .loaded
            }
        }
    }
}
