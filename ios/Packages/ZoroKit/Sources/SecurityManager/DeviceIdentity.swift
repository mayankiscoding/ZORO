import Foundation
import ZoroCore

/// The paired device: builds the pairing payload, stores the server-issued device id, and signs every
/// string the server verifies. `confirm` approvals and challenges use the auth key; `biometric`
/// approvals use the approval (user-presence) key; proofs use the key the caller names.
public actor DeviceIdentity: DeviceIdentityProviding {
    static let deviceIdAccount = "device.id"
    static let serverNameAccount = "device.server_name"

    let keys: any KeyStoring
    private let items: any SecureItemStoring

    public init(keys: any KeyStoring, items: any SecureItemStoring) {
        self.keys = keys
        self.items = items
    }

    public func deviceId() async -> String? {
        (try? items.read(Self.deviceIdAccount)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
    }

    public func serverName() -> String? {
        (try? items.read(Self.serverNameAccount)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
    }

    public func pairRequest(
        pairingCode: String, deviceName: String, platform: DevicePlatform, capabilities: [String], appVersion: String?
    ) async throws -> PairRequest {
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw ZoroError.invalidResponse("empty pairing code") }
        try await keys.ensureSigningKeys()
        let auth = try await keys.publicKey(for: .auth)
        let approval = try await keys.publicKey(for: .approval)
        guard auth.count == 65, approval.count == 65 else { throw ZoroError.keyUnavailable("unexpected public key format") }
        return PairRequest(
            pairingCode: code, deviceName: deviceName, platform: platform, authPublicKeyB64: auth.base64EncodedString(),
            approvalPublicKeyB64: approval.base64EncodedString(), capabilities: capabilities, appVersion: appVersion)
    }

    public func completePairing(_ response: PairResponse) async throws {
        guard !response.deviceId.isEmpty else { throw ZoroError.invalidResponse("empty device id") }
        try items.write(Data(response.deviceId.utf8), account: Self.deviceIdAccount, access: .afterFirstUnlockThisDeviceOnly)
        try items.write(Data(response.serverName.utf8), account: Self.serverNameAccount, access: .afterFirstUnlockThisDeviceOnly)
    }

    private func requireDeviceId() async throws -> String {
        guard let id = await deviceId() else { throw ZoroError.notPaired }
        return id
    }

    public func signChallenge(nonce: String) async throws -> TokenRequest {
        let id = try await requireDeviceId()
        let message = SignedStrings.auth(deviceId: id, nonce: nonce)
        let signature = try await keys.sign(Data(message.utf8), with: .auth, reason: "Connect to your ZORO server")
        return TokenRequest(deviceId: id, nonce: nonce, signatureB64: signature.base64EncodedString())
    }

    public func signApproval(_ request: ApprovalRequest, approved: Bool, at date: Date) async throws -> ApprovalDecision {
        let keys = self.keys
        return try await signApproval(request, approved: approved, at: date) { message, purpose in
            try await keys.sign(message, with: purpose, reason: request.title)
        }
    }

    func signApproval(
        _ request: ApprovalRequest, approved: Bool, at date: Date,
        sign: @Sendable (Data, DeviceKeyPurpose) async throws -> Data
    ) async throws -> ApprovalDecision {
        let id = try await requireDeviceId()
        let signedAt = ZoroJSON.wholeSeconds(date)
        let message = SignedStrings.approval(
            approvalId: request.approvalId, actionDigest: request.actionDigest, approved: approved, signedAt: signedAt)
        let purpose: DeviceKeyPurpose = request.level == .biometric ? .approval : .auth
        let signature = try await sign(Data(message.utf8), purpose)
        return ApprovalDecision(
            approvalId: request.approvalId, approved: approved, actionDigest: request.actionDigest, deviceId: id,
            signedAt: signedAt, signatureB64: signature.base64EncodedString())
    }

    public func signProof(action: String, subject: String, key: ProofKey, at date: Date) async throws -> SignedProof {
        let id = try await requireDeviceId()
        let signedAt = ZoroJSON.wholeSeconds(date)
        let message = SignedStrings.action(action, subject: subject, signedAt: signedAt)
        let purpose: DeviceKeyPurpose = key == .approval ? .approval : .auth
        let signature = try await keys.sign(Data(message.utf8), with: purpose, reason: "Confirm this security change")
        return SignedProof(deviceId: id, signedAt: signedAt, signatureB64: signature.base64EncodedString(), key: key)
    }

    public func unpair() async throws {
        try await keys.deleteAllKeys()
        try items.delete(Self.deviceIdAccount)
        try items.delete(Self.serverNameAccount)
    }
}
