import Foundation
import ShoppingInterface
import SystemFeatures
import ZoroAppUI
import ZoroCore

/// Home's suggestion context from the server: waiting approvals, and the active basket's item count
/// from the shopping package. The basket suggestion appears only when a basket exists; a basket call
/// that fails or finds nothing leaves the count nil instead of guessing.
public struct ShoppingHomeContext: HomeContextProviding {
    private let api: any ZoroAPI
    public init(api: any ZoroAPI) { self.api = api }

    public func suggestionContext() async -> SuggestionContext {
        async let approvals = try? api.pendingApprovals()
        async let basket = try? ShoppingClient(api: api).basket()
        let pending = await approvals?.count ?? 0
        let items = await basket?.basket?.items.count
        return SuggestionContext(basketItemCount: items.flatMap { $0 > 0 ? $0 : nil }, pendingApprovalCount: pending)
    }
}

/// Integrations' device rows, from PermissionManager's registry with the live permission state.
struct RegistryCapabilities: SystemFeatures.DeviceCapabilityRegistry {
    let rows: @Sendable () async -> [Capability]
    func capabilities() async -> [Capability] { await rows() }
}

/// Settings shows the address this device is paired with.
struct EndpointAddress: ServerAddressProviding {
    let endpoint: ServerEndpoint
    func serverAddress() async -> String? { endpoint.current?.absoluteString }
}

/// Wraps the shell's pairing so the address is recorded the moment the server accepts the device;
/// every API call, the device channel and Settings then use it.
struct EndpointRecordingPairing: ServerPairing {
    let base: any ServerPairing
    let endpoint: ServerEndpoint
    let store: ServerAddressStore

    func createKeys() async throws { try await base.createKeys() }

    func pair(serverURL: URL, code: String) async throws -> PairResponse {
        let response = try await base.pair(serverURL: serverURL, code: code)
        endpoint.set(serverURL)
        store.save(serverURL)
        return response
    }
}

/// The paired address, kept beside the shell's preferences so it is known before first run finishes.
struct ServerAddressStore: @unchecked Sendable {
    let defaults: UserDefaults
    let key = "zoro.server-url"

    func load() -> URL? { defaults.string(forKey: key).flatMap(URL.init(string:)) }
    func save(_ url: URL?) { defaults.set(url?.absoluteString, forKey: key) }
}

extension DeviceQuickActions {
    /// Device control's quick actions with the real device-contract tool names for this platform.
    static func systemActions(for platform: DevicePlatform) -> [DeviceQuickAction] {
        specs(for: platform).map {
            DeviceQuickAction(id: $0.id, title: $0.title, detail: $0.detail, symbol: $0.symbol, tool: $0.tool, args: $0.args, risk: $0.risk)
        }
    }
}
