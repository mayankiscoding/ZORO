import CryptoKit
import Foundation
import Testing
import ZoroCore
@testable import SecurityManager

private let fixedNow = Date(timeIntervalSince1970: 1_794_475_815.75)  // 2026-11-12T09:30:15.75Z

private func verify(_ signatureB64: String, _ message: String, publicKey: Data) throws -> Bool {
    let key = try P256.Signing.PublicKey(x963Representation: publicKey)
    guard let der = Data(base64Encoded: signatureB64) else { return false }
    let signature = try P256.Signing.ECDSASignature(derRepresentation: der)
    return key.isValidSignature(signature, for: Data(message.utf8))
}

private func pairedIdentity(keys: any KeyStoring = InMemoryKeyStore()) async throws -> DeviceIdentity {
    let identity = DeviceIdentity(keys: keys, items: InMemorySecureItemStore())
    _ = try await identity.pairRequest(pairingCode: "123456", deviceName: "iPhone", platform: .ios, capabilities: [], appVersion: nil)
    try await identity.completePairing(PairResponse(deviceId: "dev_1", serverName: "home", serverTime: fixedNow))
    return identity
}

private func approval(level: ApprovalLevel, expires: Date = fixedNow.addingTimeInterval(120)) -> ApprovalRequest {
    ApprovalRequest(
        approvalId: "ap_1", tool: "comms.send_email", risk: .high, level: level, title: "Send email to hr@example.com",
        summary: "Leave on Friday", actionDigest: String(repeating: "ab", count: 32), expiresAt: expires)
}

@Suite("Signed strings")
struct SignedStringTests {
    @Test func exactFormats() {
        #expect(SignedStrings.auth(deviceId: "dev_1", nonce: "n0nce") == "zoro-auth-v1|dev_1|n0nce")
        #expect(
            SignedStrings.approval(approvalId: "ap_1", actionDigest: "d1", approved: true, signedAt: fixedNow)
                == "zoro-approval-v1|ap_1|d1|1|2026-11-12T09:30:15Z")
        #expect(
            SignedStrings.approval(approvalId: "ap_1", actionDigest: "d1", approved: false, signedAt: fixedNow)
                == "zoro-approval-v1|ap_1|d1|0|2026-11-12T09:30:15Z")
        #expect(
            SignedStrings.action("set_privacy_mode", subject: "cloud_intelligence", signedAt: fixedNow)
                == "zoro-action-v1|set_privacy_mode|cloud_intelligence|2026-11-12T09:30:15Z")
    }

    @Test func signedActionSubjects() {
        #expect(SignedAction.setPermission(key: "finance.read", granted: true).subject == "finance.read=true")
        #expect(SignedAction.setKillSwitch(false).subject == "false")
        #expect(SignedAction.exportMemory(nil).subject == "all")
        #expect(SignedAction.deleteMemoryCategory(.financial).action == "delete_memory_category")
    }

    @Test func pythonSignatureVerifiesWithCryptoKit() throws {
        let url = try #require(Bundle.module.url(forResource: "signature_vector", withExtension: "json", subdirectory: "Fixtures"))
        let vector = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
        let pubB64 = try #require(vector["public_key_b64"])
        let signature = try #require(vector["signature_b64"])
        let message = try #require(vector["message"])
        let pub = try #require(Data(base64Encoded: pubB64))
        #expect(pub.count == 65 && pub.first == 0x04)
        #expect(try verify(signature, message, publicKey: pub))
        #expect(try !verify(signature, "zoro-auth-v1|dev_test|other", publicKey: pub))
    }
}

@Suite("Device identity")
struct DeviceIdentityTests {
    @Test func pairRequestCarriesX963Keys() async throws {
        let keys = InMemoryKeyStore()
        let identity = DeviceIdentity(keys: keys, items: InMemorySecureItemStore())
        let request = try await identity.pairRequest(
            pairingCode: " 123456\n", deviceName: "Maya's iPhone", platform: .ios, capabilities: ["ios.alarm.create"], appVersion: "1.0")
        #expect(request.pairingCode == "123456")
        let auth = try #require(Data(base64Encoded: request.authPublicKeyB64))
        let approval = try #require(Data(base64Encoded: request.approvalPublicKeyB64))
        #expect(auth.count == 65 && approval.count == 65 && auth != approval)
        #expect(await identity.deviceId() == nil)
        await #expect(throws: ZoroError.notPaired) { try await identity.signChallenge(nonce: "n") }
    }

    @Test func challengeIsSignedWithAuthKey() async throws {
        let keys = InMemoryKeyStore()
        let identity = try await pairedIdentity(keys: keys)
        let token = try await identity.signChallenge(nonce: "nonce-1")
        #expect(token.deviceId == "dev_1" && token.nonce == "nonce-1")
        let authKey = try await keys.publicKey(for: .auth)
        let approvalKey = try await keys.publicKey(for: .approval)
        #expect(try verify(token.signatureB64, "zoro-auth-v1|dev_1|nonce-1", publicKey: authKey))
        #expect(try !verify(token.signatureB64, "zoro-auth-v1|dev_1|nonce-1", publicKey: approvalKey))
    }

    @Test func approvalKeyDependsOnLevel() async throws {
        let keys = InMemoryKeyStore()
        let identity = try await pairedIdentity(keys: keys)
        let authKey = try await keys.publicKey(for: .auth)
        let approvalKey = try await keys.publicKey(for: .approval)

        let confirm = try await identity.signApproval(approval(level: .confirm), approved: true, at: fixedNow)
        let expected = "zoro-approval-v1|ap_1|\(String(repeating: "ab", count: 32))|1|2026-11-12T09:30:15Z"
        #expect(try verify(confirm.signatureB64, expected, publicKey: authKey))
        #expect(confirm.signedAt == Date(timeIntervalSince1970: 1_794_475_815))  // whole seconds, matches the string

        let biometric = try await identity.signApproval(approval(level: .biometric), approved: false, at: fixedNow)
        let declined = expected.replacingOccurrences(of: "|1|", with: "|0|")
        #expect(try verify(biometric.signatureB64, declined, publicKey: approvalKey))
        #expect(try !verify(biometric.signatureB64, declined, publicKey: authKey))
        #expect(!biometric.approved)
    }

    @Test func proofSignsActionString() async throws {
        let keys = InMemoryKeyStore()
        let identity = try await pairedIdentity(keys: keys)
        let proof = try await identity.signProof(.setPrivacyMode(.cloudIntelligence), at: fixedNow)
        #expect(proof.key == .approval && proof.deviceId == "dev_1")
        #expect(try verify(
            proof.signatureB64, "zoro-action-v1|set_privacy_mode|cloud_intelligence|2026-11-12T09:30:15Z",
            publicKey: try await keys.publicKey(for: .approval)))
        let json = String(decoding: try ZoroJSON.encoder().encode(proof), as: UTF8.self)
        #expect(json.contains(#""signed_at":"2026-11-12T09:30:15Z""#))
    }

    @Test func cancelledUserPresencePropagates() async throws {
        let keys = InMemoryKeyStore(approvalGate: { _ in throw ZoroError.userCancelled })
        let identity = try await pairedIdentity(keys: keys)
        await #expect(throws: ZoroError.userCancelled) {
            try await identity.signApproval(approval(level: .biometric), approved: true, at: fixedNow)
        }
        // Confirm-level approvals do not need user presence.
        _ = try await identity.signApproval(approval(level: .confirm), approved: true, at: fixedNow)
    }

    @Test func unpairRemovesIdentityAndKeys() async throws {
        let keys = InMemoryKeyStore()
        let identity = try await pairedIdentity(keys: keys)
        try await identity.unpair()
        #expect(await identity.deviceId() == nil)
        await #expect(throws: ZoroError.self) { try await keys.publicKey(for: .auth) }
    }
}

@Suite("Software key store")
struct SoftwareKeyStoreTests {
    @Test func keysPersistInTheItemStoreWithTheRightAccess() async throws {
        let items = InMemorySecureItemStore()
        let first = SoftwareKeyStore(items: items)
        try await first.ensureSigningKeys()
        let pub = try await first.publicKey(for: .approval)
        #expect(items.access(of: "signing.approval") == .userPresence)
        #expect(items.access(of: "signing.auth") == .whenUnlockedThisDeviceOnly)

        let reopened = SoftwareKeyStore(items: items)
        try await reopened.ensureSigningKeys()  // must not replace existing keys
        #expect(try await reopened.publicKey(for: .approval) == pub)
        let sig = try await reopened.sign(Data("hello".utf8), with: .approval, reason: "test")
        #expect(try verify(sig.base64EncodedString(), "hello", publicKey: pub))

        let sym1 = try await reopened.symmetricKey(named: "conversations")
        #expect(sym1.count == 32)
        #expect(try await first.symmetricKey(named: "conversations") == sym1)
        #expect(try await first.symmetricKey(named: "other") != sym1)

        try await reopened.deleteAllKeys()
        await #expect(throws: ZoroError.self) { try await reopened.sign(Data(), with: .auth, reason: "") }
    }
}

// MARK: - Approval coordinator

private struct FakePresenter: ApprovalPresenting {
    let answer: Result<Bool, ZoroError>
    let shown = LockedList()
    let notices = LockedList()
    @MainActor func present(_ request: ApprovalRequest) async throws -> Bool {
        shown.append(request.approvalId)
        return try answer.get()
    }
    @MainActor func present(_ request: ApprovalRequest, notice: String?) async throws -> Bool {
        notices.append(notice ?? "")
        return try await present(request)
    }
}

/// Fails with the scripted errors first, then succeeds. Shares its context like `BiometricAuthenticator`.
private final class ScriptedPresence: BiometricAuthenticating, PresenceAuthenticating, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [ZoroError]
    let calls = LockedList()
    init(failures: [ZoroError]) { self.failures = failures }
    func availability() async -> BiometricAvailability { BiometricAvailability(kind: .faceID, canAuthenticate: true) }
    func authenticate(reason: String) async throws { _ = try await authenticatePresence(reason: reason) }
    func authenticatePresence(reason: String) async throws -> PresenceContext {
        calls.append(reason)
        let next: ZoroError? = lock.withLock { failures.isEmpty ? nil : failures.removeFirst() }
        if let next { throw next }
        return PresenceContext()
    }
}

final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private struct FakeBiometrics: BiometricAuthenticating {
    let fail: ZoroError?
    let calls = LockedList()
    func availability() async -> BiometricAvailability { BiometricAvailability(kind: .faceID, canAuthenticate: true) }
    func authenticate(reason: String) async throws {
        calls.append(reason)
        if let fail { throw fail }
    }
}

@Suite("Approval coordinator")
struct ApprovalCoordinatorTests {
    @Test func confirmApprovalSkipsBiometrics() async throws {
        let bio = FakeBiometrics(fail: nil)
        let coordinator = ApprovalCoordinator(
            identity: try await pairedIdentity(), biometrics: bio, presenter: FakePresenter(answer: .success(true)), now: { fixedNow })
        let decision = try await coordinator.decide(approval(level: .confirm))
        #expect(decision.approved && decision.approvalId == "ap_1")
        #expect(bio.calls.all.isEmpty)
    }

    @Test func biometricApprovalAuthenticatesFirst() async throws {
        let bio = FakeBiometrics(fail: nil)
        let coordinator = ApprovalCoordinator(
            identity: try await pairedIdentity(), biometrics: bio, presenter: FakePresenter(answer: .success(true)), now: { fixedNow })
        let decision = try await coordinator.decide(approval(level: .biometric))
        #expect(decision.approved)
        #expect(bio.calls.all == ["Send email to hr@example.com"])
    }

    @Test func failedBiometricsProducesNoSignature() async throws {
        let keys = InMemoryKeyStore()
        let coordinator = ApprovalCoordinator(
            identity: try await pairedIdentity(keys: keys), biometrics: FakeBiometrics(fail: .authenticationFailed("no match")),
            presenter: FakePresenter(answer: .success(true)), now: { fixedNow })
        await #expect(throws: ZoroError.authenticationFailed("no match")) { try await coordinator.decide(approval(level: .biometric)) }
        #expect(await keys.signatures.isEmpty)  // after the last of `maximumAttempts` tries
    }

    @Test func declineIsSignedWithoutBiometrics() async throws {
        let bio = FakeBiometrics(fail: nil)
        let coordinator = ApprovalCoordinator(
            identity: try await pairedIdentity(), biometrics: bio, presenter: FakePresenter(answer: .success(false)), now: { fixedNow })
        let decision = try await coordinator.decide(approval(level: .biometric))
        #expect(!decision.approved)
        #expect(bio.calls.all.isEmpty)
    }

    @Test func expiredRequestIsNeverShown() async throws {
        let presenter = FakePresenter(answer: .success(true))
        let coordinator = ApprovalCoordinator(
            identity: try await pairedIdentity(), biometrics: FakeBiometrics(fail: nil), presenter: presenter, now: { fixedNow })
        await #expect(throws: ZoroError.approvalExpired) { try await coordinator.decide(approval(level: .confirm, expires: fixedNow)) }
        #expect(presenter.shown.all.isEmpty)
    }

    @Test func cancelledOrFailedBiometricReturnsToThePresenter() async throws {
        let keys = InMemoryKeyStore()
        let presence = ScriptedPresence(failures: [.userCancelled, .authenticationFailed("no match")])
        let presenter = FakePresenter(answer: .success(true))
        let coordinator = ApprovalCoordinator(
            identity: try await pairedIdentity(keys: keys), biometrics: presence, presenter: presenter, now: { fixedNow })
        let decision = try await coordinator.decide(approval(level: .biometric))
        #expect(decision.approved)
        #expect(presenter.shown.all.count == 3)
        #expect(presenter.notices.all == [ApprovalCoordinator.cancelledNotice, ApprovalCoordinator.failedNotice])
        #expect(presence.calls.all.count == 3)
        #expect(await keys.signatures.count == 1)
    }

    @Test func biometricApprovalAsksForUserPresenceOnce() async throws {
        let gate = LockedList()
        let keys = InMemoryKeyStore(approvalGate: { reason in gate.append(reason) })
        let presence = ScriptedPresence(failures: [])
        let coordinator = ApprovalCoordinator(
            identity: try await pairedIdentity(keys: keys), biometrics: presence, presenter: FakePresenter(answer: .success(true)),
            now: { fixedNow })
        let decision = try await coordinator.decide(approval(level: .biometric))
        #expect(presence.calls.all == ["Send email to hr@example.com"])
        #expect(gate.all.isEmpty)  // the key reused the authenticated context: no second prompt
        let expected = "zoro-approval-v1|ap_1|\(String(repeating: "ab", count: 32))|1|2026-11-12T09:30:15Z"
        #expect(try verify(decision.signatureB64, expected, publicKey: try await keys.publicKey(for: .approval)))
    }

    @Test func retriesStopAfterTheMaximum() async throws {
        let presence = ScriptedPresence(failures: Array(repeating: .userCancelled, count: 10))
        let presenter = FakePresenter(answer: .success(true))
        let coordinator = ApprovalCoordinator(
            identity: try await pairedIdentity(), biometrics: presence, presenter: presenter, now: { fixedNow })
        await #expect(throws: ZoroError.userCancelled) { try await coordinator.decide(approval(level: .biometric)) }
        #expect(presenter.shown.all.count == ApprovalCoordinator.maximumAttempts)
    }

    @Test func unavailableBiometryEndsWithoutRetry() async throws {
        let presence = ScriptedPresence(failures: [.biometryUnavailable("not enrolled")])
        let presenter = FakePresenter(answer: .success(true))
        let coordinator = ApprovalCoordinator(
            identity: try await pairedIdentity(), biometrics: presence, presenter: presenter, now: { fixedNow })
        await #expect(throws: ZoroError.biometryUnavailable("not enrolled")) { try await coordinator.decide(approval(level: .biometric)) }
        #expect(presenter.shown.all.count == 1)
    }

    @Test func dismissalPropagatesCancel() async throws {
        let coordinator = ApprovalCoordinator(
            identity: try await pairedIdentity(), biometrics: FakeBiometrics(fail: nil),
            presenter: FakePresenter(answer: .failure(.userCancelled)), now: { fixedNow })
        await #expect(throws: ZoroError.userCancelled) { try await coordinator.decide(approval(level: .confirm)) }
    }
}

// MARK: - Session manager

private actor FakeAuthAPI: ZoroAuthAPI {
    var challenges = 0
    var lastTokenRequest: TokenRequest?
    let expiresIn: Int
    init(expiresIn: Int = 900) { self.expiresIn = expiresIn }
    func pair(_ request: PairRequest) async throws -> PairResponse { throw ZoroError.busy }
    func challenge(_ request: ChallengeRequest) async throws -> ChallengeResponse {
        challenges += 1
        try await Task.sleep(nanoseconds: 2_000_000)
        return ChallengeResponse(nonce: "nonce-\(challenges)", expiresAt: fixedNow.addingTimeInterval(60))
    }
    func token(_ request: TokenRequest) async throws -> TokenResponse {
        lastTokenRequest = request
        return TokenResponse(accessToken: "jwt-\(request.nonce)", expiresIn: expiresIn)
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ d: Date) { value = d }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ s: TimeInterval) { lock.lock(); value += s; lock.unlock() }
}

@Suite("Session manager")
struct SessionManagerTests {
    @Test func challengeSignTokenAndCache() async throws {
        let api = FakeAuthAPI()
        let keys = InMemoryKeyStore()
        let clock = Clock(fixedNow)
        let session = SessionManager(auth: api, identity: try await pairedIdentity(keys: keys), now: { clock.now })
        #expect(try await session.validAccessToken() == "jwt-nonce-1")
        #expect(try await session.validAccessToken() == "jwt-nonce-1")
        #expect(await api.challenges == 1)
        let sent = try #require(await api.lastTokenRequest)
        #expect(try verify(sent.signatureB64, "zoro-auth-v1|dev_1|nonce-1", publicKey: try await keys.publicKey(for: .auth)))
        #expect(await session.expiresAt == fixedNow.addingTimeInterval(900))

        clock.advance(900 - 29)  // inside the 30 s leeway: re-sign before expiry
        #expect(try await session.validAccessToken() == "jwt-nonce-2")
    }

    @Test func invalidateForcesReauthentication() async throws {
        let api = FakeAuthAPI()
        let session = SessionManager(auth: api, identity: try await pairedIdentity(), now: { fixedNow })
        let first = try await session.validAccessToken()
        await session.invalidate(token: "some-older-token")
        #expect(try await session.validAccessToken() == first)
        await session.invalidate(token: first)
        #expect(try await session.validAccessToken() == "jwt-nonce-2")
    }

    @Test func concurrentCallersShareOneChallenge() async throws {
        let api = FakeAuthAPI()
        let session = SessionManager(auth: api, identity: try await pairedIdentity(), now: { fixedNow })
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await session.validAccessToken() } }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(tokens == ["jwt-nonce-1"])
        #expect(await api.challenges == 1)
    }

    @Test func unpairedDeviceCannotAuthenticate() async {
        let identity = DeviceIdentity(keys: InMemoryKeyStore(), items: InMemorySecureItemStore())
        let session = SessionManager(auth: FakeAuthAPI(), identity: identity)
        await #expect(throws: ZoroError.notPaired) { try await session.validAccessToken() }
    }

    @Test func zeroLifetimeTokenIsRejected() async throws {
        let session = SessionManager(auth: FakeAuthAPI(expiresIn: 0), identity: try await pairedIdentity(), now: { fixedNow })
        await #expect(throws: ZoroError.self) { try await session.validAccessToken() }
        #expect(await !session.isAuthenticated)
    }
}
