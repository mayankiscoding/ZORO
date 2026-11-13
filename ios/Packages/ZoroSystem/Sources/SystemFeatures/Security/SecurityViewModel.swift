import Foundation
import Observation
import ZoroCore

/// Plain words for the two privacy modes.
public enum PrivacyCopy {
    public static func title(_ mode: PrivacyMode) -> String {
        switch mode {
        case .strictPrivate: "Private mode"
        case .cloudIntelligence: "Cloud intelligence"
        }
    }

    /// One line, as in the voice and copy guide.
    public static func line(_ mode: PrivacyMode) -> String {
        switch mode {
        case .strictPrivate: "Nothing leaves your ZORO server."
        case .cloudIntelligence: "Only what you allowed is sent out, with personal details removed."
        }
    }

    /// What the mode means in practice.
    public static func explanation(_ mode: PrivacyMode) -> String {
        switch mode {
        case .strictPrivate:
            "ZORO answers with models that run on your server or this device. Your memory, photos, health and money details are never sent to a cloud provider. Finance stays read-only."
        case .cloudIntelligence:
            "ZORO may use approved cloud models for harder questions. It sends only the kinds of data you allow below, and removes card and account numbers, UPI IDs, phone numbers and email addresses first. Sensitive, financial and health data stay on your server unless you allow them."
        }
    }

    /// Shown before switching to cloud intelligence.
    public static let loosenSheet = "Turning this on lets ZORO send the data types you allow to approved cloud providers, with personal details removed. You can switch back any time."

    public static func switched(to mode: PrivacyMode) -> String {
        switch mode {
        case .cloudIntelligence: "Cloud intelligence is on."
        case .strictPrivate: "Private mode is on."
        }
    }

    /// Switching to cloud intelligence loosens privacy; switching to private mode tightens it.
    public static func isLoosening(from current: PrivacyMode, to next: PrivacyMode) -> Bool {
        current == .strictPrivate && next == .cloudIntelligence
    }
}

public struct SessionInfo: Equatable, Sendable {
    public var deviceId: String?
    public var expiresAt: Date
    public var keyProtection: KeyProtection
    public var biometry: BiometricAvailability

    public var keyProtectionText: String {
        switch keyProtection {
        case .secureEnclave: "Your approval key lives in this device's Secure Enclave."
        case .keychainSoftware: "Your approval key is in the Keychain, not the Secure Enclave."
        case .memory: "Your keys are held in memory only and are lost when the app closes."
        }
    }

    public var biometryText: String {
        switch biometry.kind {
        case .faceID: biometry.canAuthenticate ? "Face ID is ready." : "Face ID isn't ready. Set it up in Settings."
        case .touchID: biometry.canAuthenticate ? "Touch ID is ready." : "Touch ID isn't ready. Set it up in Settings."
        case .opticID: biometry.canAuthenticate ? "Optic ID is ready." : "Optic ID isn't ready."
        case .none: biometry.canAuthenticate ? "Your device passcode confirms changes." : "No Face ID, Touch ID or passcode is set up. Set a passcode in Settings."
        }
    }

    public func expiryText(now: Date = Date()) -> String {
        expiresAt <= now ? "This session ended. ZORO signs in again on the next request." : "This session ends \(SystemFormat.relative(expiresAt, to: now))."
    }
}

/// Security and privacy: privacy mode, kill switch, permission grants, registered devices and session
/// information. Every change carries a signed proof from the approval key; when a proof can't be made
/// the request is not sent and nothing changes.
@MainActor
@Observable
public final class SecurityViewModel {
    public private(set) var phase: ScreenPhase = .idle
    public private(set) var state: SecurityState?
    public private(set) var session: SessionInfo?
    public private(set) var notice: SystemNotice?
    /// Set when the owner asked to move to a looser privacy mode; the screen shows the explanation and waits.
    public private(set) var pendingPrivacyChange: PrivacyMode?
    /// Set when the owner asked to remove a device; the screen confirms first.
    public private(set) var pendingRevoke: DeviceInfo?
    public private(set) var isChangingPrivacy = false
    public private(set) var isChangingKillSwitch = false
    public private(set) var busyPermissionKeys: Set<String> = []
    public private(set) var revokingDeviceId: String?

    @ObservationIgnored private let api: any ZoroAPI
    @ObservationIgnored private let authorizer: ProofAuthorizer
    @ObservationIgnored private let identity: any DeviceIdentityProviding
    @ObservationIgnored private let keys: any KeyStoring
    @ObservationIgnored private let biometrics: any BiometricAuthenticating
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(
        api: any ZoroAPI, identity: any DeviceIdentityProviding, keys: any KeyStoring,
        biometrics: any BiometricAuthenticating, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.identity = identity
        self.keys = keys
        self.biometrics = biometrics
        self.now = now
        authorizer = ProofAuthorizer(identity: identity, now: now)
    }

    // MARK: - Derived

    public var privacyMode: PrivacyMode? { state?.privacyMode }
    public var killSwitchOn: Bool { state?.killSwitch ?? false }
    public var permissions: [PermissionGrant] { state?.permissions.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } ?? [] }
    /// The grants that decide which data classes may reach cloud providers.
    public var cloudPermissions: [PermissionGrant] { permissions.filter { $0.key.hasPrefix("cloud.") } }
    public var otherPermissions: [PermissionGrant] { permissions.filter { !$0.key.hasPrefix("cloud.") } }
    public var devices: [DeviceRow] {
        let me = session?.deviceId
        return (state?.devices ?? []).filter { !$0.revoked }.map { DeviceRow(info: $0, isThisDevice: $0.deviceId == me) }
    }
    public var removedDevices: [DeviceInfo] { (state?.devices ?? []).filter(\.revoked) }

    public var emptyMessage: String { "No security information yet. Pull to reload." }

    public func isThisDevice(_ info: DeviceInfo) -> Bool { info.deviceId == session?.deviceId }

    // MARK: - Loading

    public func load() async {
        phase = .loading
        do {
            let loaded = try await api.securityState()
            state = loaded
            session = await makeSession(from: loaded)
            phase = .loaded
        } catch {
            guard let next = SystemFailure.phase(for: error) else { return }
            phase = next
        }
    }

    private func makeSession(from state: SecurityState) async -> SessionInfo {
        SessionInfo(
            deviceId: await identity.deviceId(), expiresAt: state.sessionExpiresAt, keyProtection: keys.protection,
            biometry: await biometrics.availability())
    }

    private func reloadQuietly() async {
        guard let loaded = try? await api.securityState() else { return }
        state = loaded
        session = await makeSession(from: loaded)
    }

    // MARK: - Privacy mode

    /// Moving to a looser mode (cloud intelligence) shows the explanation first; moving to the stricter
    /// mode applies at once. Both are signed.
    public func requestPrivacyMode(_ mode: PrivacyMode) async {
        guard let current = state?.privacyMode, mode != current, !isChangingPrivacy else { return }
        if PrivacyCopy.isLoosening(from: current, to: mode) {
            pendingPrivacyChange = mode
        } else {
            await applyPrivacyMode(mode)
        }
    }

    public func confirmPrivacyChange() async {
        guard let mode = pendingPrivacyChange else { return }
        pendingPrivacyChange = nil
        await applyPrivacyMode(mode)
    }

    public func cancelPrivacyChange() { pendingPrivacyChange = nil }

    private func applyPrivacyMode(_ mode: PrivacyMode) async {
        guard !isChangingPrivacy else { return }
        isChangingPrivacy = true
        defer { isChangingPrivacy = false }
        do {
            let proof = try await authorizer.proof(for: .setPrivacyMode(mode))
            try await api.setPrivacyMode(PrivacyModeUpdate(mode: mode, proof: proof))
            state?.privacyMode = mode
            await reloadQuietly()
            notice = .success(PrivacyCopy.switched(to: mode))
        } catch {
            notice = SystemNotice.failed(error, action: "Switching to \(PrivacyCopy.title(mode).lowercased())")
        }
    }

    // MARK: - Kill switch

    public func setKillSwitch(_ enabled: Bool) async {
        guard state != nil, state?.killSwitch != enabled, !isChangingKillSwitch else { return }
        isChangingKillSwitch = true
        defer { isChangingKillSwitch = false }
        do {
            let proof = try await authorizer.proof(for: .setKillSwitch(enabled))
            try await api.setKillSwitch(KillSwitchUpdate(enabled: enabled, proof: proof))
            state?.killSwitch = enabled
            notice = .success(enabled ? "ZORO is paused." : "ZORO is running again.")
        } catch {
            notice = SystemNotice.failed(error, action: enabled ? "Pausing ZORO" : "Turning ZORO back on")
        }
    }

    // MARK: - Permissions

    public func setPermission(_ grant: PermissionGrant, granted: Bool) async {
        guard grant.granted != granted, !busyPermissionKeys.contains(grant.key) else { return }
        busyPermissionKeys.insert(grant.key)
        defer { busyPermissionKeys.remove(grant.key) }
        do {
            let proof = try await authorizer.proof(for: .setPermission(key: grant.key, granted: granted))
            try await api.setPermission(key: grant.key, PermissionUpdate(granted: granted, proof: proof))
            if let i = state?.permissions.firstIndex(where: { $0.key == grant.key }) {
                state?.permissions[i].granted = granted
                state?.permissions[i].updatedAt = now()
            }
            notice = .success(granted ? "Allowed: \(grant.title)." : "Not allowed: \(grant.title).")
        } catch {
            notice = SystemNotice.failed(error, action: "Changing \(grant.title.lowercased())")
        }
    }

    // MARK: - Devices

    public func requestRevoke(_ device: DeviceInfo) {
        guard !device.revoked else { return }
        pendingRevoke = device
    }

    public func cancelRevoke() { pendingRevoke = nil }

    public func confirmRevoke() async {
        guard let device = pendingRevoke, revokingDeviceId == nil else { return }
        pendingRevoke = nil
        revokingDeviceId = device.deviceId
        defer { revokingDeviceId = nil }
        do {
            let proof = try await authorizer.proof(for: .revokeDevice(id: device.deviceId))
            try await api.revokeDevice(id: device.deviceId, DeviceRevoke(proof: proof))
            if let i = state?.devices.firstIndex(where: { $0.deviceId == device.deviceId }) {
                state?.devices[i].revoked = true
                state?.devices[i].online = false
            }
            await reloadQuietly()
            notice = .success("Removed \(device.name).")
        } catch {
            notice = SystemNotice.failed(error, action: "Removing \(device.name)")
        }
    }

    public func dismissNotice() { notice = nil }
}
