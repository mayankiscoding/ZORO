import Foundation
import ZoroCore

/// Makes the `SignedProof` that security-settings and memory actions carry. The proof is made with the
/// approval key, so a user-presence prompt (Face ID, Touch ID or passcode) appears on a real device.
/// When no proof can be made the caller must not send the request: the server would refuse it anyway,
/// and a refused request is worse than one that never left the device.
public struct ProofAuthorizer: Sendable {
    private let identity: any DeviceIdentityProviding
    private let now: @Sendable () -> Date

    public init(identity: any DeviceIdentityProviding, now: @escaping @Sendable () -> Date = { Date() }) {
        self.identity = identity
        self.now = now
    }

    /// Throws `ZoroError.notPaired`, `.userCancelled`, `.authenticationFailed`, `.signingFailed` or
    /// `.keyUnavailable`; never returns an unsigned or foreign-device proof.
    public func proof(for action: SignedAction) async throws -> SignedProof {
        guard let deviceId = await identity.deviceId() else { throw ZoroError.notPaired }
        let proof = try await identity.signProof(action, key: .approval, at: now())
        guard proof.deviceId == deviceId, !proof.signatureB64.isEmpty else {
            throw ZoroError.signingFailed("the proof did not come from this device")
        }
        return proof
    }
}
