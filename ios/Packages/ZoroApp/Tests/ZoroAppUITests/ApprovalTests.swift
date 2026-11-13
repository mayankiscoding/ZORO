import Foundation
import SecurityManager
import Testing
import ZoroCore
import ZoroDesign
@testable import ZoroAppUI

/// Signs approvals without keys (records what it signed).
struct FakeIdentity: DeviceIdentityProviding {
    let signed = Recorder<Bool>()
    func deviceId() async -> String? { "dev_1" }
    func pairRequest(pairingCode: String, deviceName: String, platform: DevicePlatform, capabilities: [String], appVersion: String?) async throws -> PairRequest {
        PairRequest(pairingCode: pairingCode, deviceName: deviceName, platform: platform, authPublicKeyB64: "a", approvalPublicKeyB64: "b", capabilities: capabilities, appVersion: appVersion)
    }
    func completePairing(_ response: PairResponse) async throws {}
    func signChallenge(nonce: String) async throws -> TokenRequest { TokenRequest(deviceId: "dev_1", nonce: nonce, signatureB64: "s") }
    func signApproval(_ request: ApprovalRequest, approved: Bool, at date: Date) async throws -> ApprovalDecision {
        signed.append(approved)
        return ApprovalDecision(approvalId: request.approvalId, approved: approved, actionDigest: request.actionDigest, deviceId: "dev_1", signedAt: date, signatureB64: "sig")
    }
    func signProof(action: String, subject: String, key: ProofKey, at date: Date) async throws -> SignedProof {
        SignedProof(deviceId: "dev_1", signedAt: date, signatureB64: "p")
    }
    func unpair() async throws {}
}

@Suite("Approval sheet")
@MainActor
struct ApprovalTests {
    @Test func riskBadges() {
        #expect(RiskBadgeModel(.low) == RiskBadgeModel(label: "Low risk", role: nil))
        #expect(RiskBadgeModel(.medium).role == .accent)
        #expect(RiskBadgeModel(.high) == RiskBadgeModel(label: "High risk", role: .attention))
        #expect(RiskBadgeModel(.critical) == RiskBadgeModel(label: "Critical risk", role: .critical))
    }

    @Test func modelShowsExactContent() {
        let clock = TestClock()
        let request = approvalRequest(level: .biometric, risk: .critical, now: clock.now)
        let model = ApprovalSheetModel(request: request, biometricName: "Face ID")
        #expect(model.approveTitle == "Approve with Face ID")
        #expect(ApprovalSheetModel.declineTitle == "Decline")
        #expect(model.summary.action == "Send this message on WhatsApp.")
        #expect(model.summary.details.map(\.label) == ["To", "Message"])
        #expect(model.summary.level == .biometric)
        #expect(model.summary.amount == nil)
        #expect(model.remainingSeconds(now: clock.now) == 120)
        #expect(model.expiryText(now: clock.now) == "Expires in 2:00")
        clock.advance(75)
        #expect(model.expiryText(now: clock.now) == "Expires in 0:45")
        clock.advance(60)
        #expect(model.remainingSeconds(now: clock.now) == 0)
        #expect(model.expiryText(now: clock.now) == "Expired. Ask again to approve.")
        #expect(ApprovalSheetModel(request: approvalRequest(level: .confirm, now: clock.now)).approveTitle == "Approve")
    }

    @Test func biometricNames() {
        #expect(BiometricNames.name(for: .faceID) == "Face ID")
        #expect(BiometricNames.name(for: .touchID) == "Touch ID")
        #expect(BiometricNames.name(for: .none) == "your passcode")
    }

    private func presented(_ presenter: ApprovalSheetPresenter, _ request: ApprovalRequest) async -> Task<Bool, Error> {
        let task = Task { try await presenter.present(request) }
        await waitUntil { presenter.current != nil }
        return task
    }

    @Test func confirmApprovalAnswersTrueAndCloses() async throws {
        let clock = TestClock()
        let presenter = ApprovalSheetPresenter(biometrics: FakeBiometrics(kind: .touchID), now: clock.function)
        let task = await presented(presenter, approvalRequest(level: .confirm, now: clock.now))
        #expect(presenter.current?.biometricName == "Touch ID")
        presenter.approve()
        #expect(try await task.value == true)
        #expect(presenter.current == nil)
    }

    @Test func biometricApprovalStaysUntilTheTurnMovesOn() async throws {
        let clock = TestClock()
        let presenter = ApprovalSheetPresenter(biometrics: FakeBiometrics(), now: clock.function)
        let request = approvalRequest(level: .biometric, now: clock.now)
        let task = await presented(presenter, request)
        presenter.approve()
        #expect(try await task.value == true)
        #expect(presenter.current?.phase == .authenticating)
        presenter.conversationMoved(awaitingApprovalId: request.approvalId)
        #expect(presenter.current != nil)
        presenter.conversationMoved(awaitingApprovalId: nil)
        #expect(presenter.current == nil)
    }

    @Test func declineAnswersFalse() async throws {
        let clock = TestClock()
        let presenter = ApprovalSheetPresenter(biometrics: FakeBiometrics(), now: clock.function)
        let task = await presented(presenter, approvalRequest(now: clock.now))
        presenter.decline()
        #expect(try await task.value == false)
        #expect(presenter.current == nil)
    }

    @Test func dismissingCancels() async {
        let clock = TestClock()
        let presenter = ApprovalSheetPresenter(biometrics: FakeBiometrics(), now: clock.function)
        let task = await presented(presenter, approvalRequest(now: clock.now))
        presenter.dismiss()
        await #expect(throws: ZoroError.userCancelled) { try await task.value }
    }

    @Test func expiryEndsTheRequest() async {
        let clock = TestClock()
        let presenter = ApprovalSheetPresenter(biometrics: FakeBiometrics(), now: clock.function)
        let task = await presented(presenter, approvalRequest(expiresIn: 120, now: clock.now))
        clock.advance(60)
        presenter.expireIfDue()
        #expect(presenter.current?.phase == .reviewing)
        clock.advance(61)
        presenter.expireIfDue()
        await #expect(throws: ZoroError.approvalExpired) { try await task.value }
        #expect(presenter.current?.phase == .expired)
        presenter.approve()
        #expect(presenter.current?.phase == .expired)
        presenter.dismiss()
        #expect(presenter.current == nil)
    }

    @Test func approvingAfterExpiryIsRefused() async {
        let clock = TestClock()
        let presenter = ApprovalSheetPresenter(biometrics: FakeBiometrics(), now: clock.function)
        let task = await presented(presenter, approvalRequest(expiresIn: 30, now: clock.now))
        clock.advance(31)
        presenter.approve()
        await #expect(throws: ZoroError.approvalExpired) { try await task.value }
    }

    @Test func alreadyExpiredIsNeverShown() async {
        let clock = TestClock()
        let presenter = ApprovalSheetPresenter(biometrics: FakeBiometrics(), now: clock.function)
        await #expect(throws: ZoroError.approvalExpired) { try await presenter.present(approvalRequest(expiresIn: -1, now: clock.now)) }
        #expect(presenter.current == nil)
    }

    @Test func newerRequestReplacesOlder() async throws {
        let clock = TestClock()
        let presenter = ApprovalSheetPresenter(biometrics: FakeBiometrics(), now: clock.function)
        let first = await presented(presenter, approvalRequest(now: clock.now))
        var second = approvalRequest(now: clock.now)
        second.approvalId = "apr_2"
        let secondTask = Task { try await presenter.present(second) }
        await #expect(throws: ZoroError.userCancelled) { try await first.value }
        await waitUntil { presenter.current?.id == "apr_2" }
        presenter.approve()
        #expect(try await secondTask.value == true)
    }

    @Test func worksWithTheApprovalCoordinator() async throws {
        let clock = TestClock()
        let biometrics = FakeBiometrics()
        let identity = FakeIdentity()
        let presenter = ApprovalSheetPresenter(biometrics: biometrics, now: clock.function)
        let coordinator = ApprovalCoordinator(identity: identity, biometrics: biometrics, presenter: presenter, now: clock.function)
        let request = approvalRequest(level: .biometric, now: clock.now)
        let decision = Task { try await coordinator.decide(request) }
        await waitUntil { presenter.current != nil }
        presenter.approve()
        let signed = try await decision.value
        #expect(signed.approved)
        #expect(biometrics.calls.all == ["Send a message"])
        #expect(identity.signed.all == [true])
    }
}

@Suite("Device action confirmation")
@MainActor
struct DeviceActionConfirmationTests {
    final class CountingExecutor: DeviceActionExecuting, @unchecked Sendable {
        let runs = Recorder<String>()
        var supportedTools: [String] { ["ios.set_alarm"] }
        func execute(_ request: DeviceActionRequest) async -> DeviceActionResult {
            runs.append(request.actionId)
            return DeviceActionResult(actionId: request.actionId, ok: true, executedAt: Date(timeIntervalSince1970: 0))
        }
    }

    struct Answer: DeviceActionConfirming {
        let answer: DeviceActionConfirmation
        let asked = Recorder<String>()
        func confirm(_ request: DeviceActionRequest) async -> DeviceActionConfirmation {
            asked.append(request.actionId)
            return answer
        }
    }

    func action(confirm: Bool, expiresIn: TimeInterval = 60, now: Date) -> DeviceActionRequest {
        DeviceActionRequest(
            actionId: "act_1", tool: "ios.set_alarm", args: ["time": "06:00", "label": "Gym", "repeat": false], risk: .medium,
            requiresUserConfirmation: confirm, expiresAt: now.addingTimeInterval(expiresIn))
    }

    @Test func unflaggedActionsRunWithoutAsking() async {
        let clock = TestClock()
        let base = CountingExecutor()
        let confirmer = Answer(answer: .declined)
        let executor = ConfirmingDeviceActionExecutor(base: base, confirmer: confirmer, now: clock.function)
        let result = await executor.execute(action(confirm: false, now: clock.now))
        #expect(result.ok)
        #expect(confirmer.asked.all.isEmpty)
        #expect(await executor.supportedTools == ["ios.set_alarm"])
    }

    @Test func flaggedActionsRunOnlyWhenConfirmed() async {
        let clock = TestClock()
        let base = CountingExecutor()
        let yes = ConfirmingDeviceActionExecutor(base: base, confirmer: Answer(answer: .confirmed), now: clock.function)
        #expect(await yes.execute(action(confirm: true, now: clock.now)).ok)
        let no = ConfirmingDeviceActionExecutor(base: base, confirmer: Answer(answer: .declined), now: clock.function)
        let declined = await no.execute(action(confirm: true, now: clock.now))
        #expect(!declined.ok && declined.errorCode == "user_cancelled")
        let late = ConfirmingDeviceActionExecutor(base: base, confirmer: Answer(answer: .expired), now: clock.function)
        #expect(await late.execute(action(confirm: true, now: clock.now)).errorCode == "expired")
        #expect(base.runs.all == ["act_1"])
    }

    @Test func expiredActionsNeverRunOrAsk() async {
        let clock = TestClock()
        let base = CountingExecutor()
        let confirmer = Answer(answer: .confirmed)
        let executor = ConfirmingDeviceActionExecutor(base: base, confirmer: confirmer, now: clock.function)
        let result = await executor.execute(action(confirm: true, expiresIn: -5, now: clock.now))
        #expect(result.errorCode == "expired")
        #expect(confirmer.asked.all.isEmpty && base.runs.all.isEmpty)
    }

    @Test func sheetContentShowsExactArguments() {
        let content = DeviceActionSheetContent(action(confirm: true, now: Date()))
        #expect(content.title == "Set alarm")
        #expect(content.rows.map(\.label) == ["Label", "Repeat", "Time"])
        #expect(content.rows.map(\.value) == ["Gym", "No", "06:00"])
        #expect(content.risk.label == "Medium risk")
    }

    @Test func presenterFlows() async {
        let clock = TestClock()
        let presenter = DeviceActionConfirmationPresenter(now: clock.function)
        let a = action(confirm: true, now: clock.now)
        let confirmed = Task { await presenter.confirm(a) }
        await waitUntil { presenter.current != nil }
        #expect(presenter.content?.title == "Set alarm")
        presenter.confirmCurrent()
        #expect(await confirmed.value == .confirmed)
        #expect(presenter.current == nil)

        let declined = Task { await presenter.confirm(a) }
        await waitUntil { presenter.current != nil }
        presenter.declineCurrent()
        #expect(await declined.value == .declined)

        let expired = Task { await presenter.confirm(a) }
        await waitUntil { presenter.current != nil }
        clock.advance(61)
        presenter.expireIfDue()
        #expect(await expired.value == .expired)

        #expect(await presenter.confirm(action(confirm: true, expiresIn: -1, now: clock.now)) == .expired)
    }
}

/// Cancels the first biometric check, then passes.
final class CancelOnceBiometrics: BiometricAuthenticating, @unchecked Sendable {
    let calls = Recorder<String>()
    func availability() async -> BiometricAvailability { BiometricAvailability(kind: .faceID, canAuthenticate: true) }
    func authenticate(reason: String) async throws {
        calls.append(reason)
        if calls.all.count == 1 { throw ZoroError.userCancelled }
    }
}

@Suite("Approval sheet: tainted requests and retries")
@MainActor
struct ApprovalTaintAndRetryTests {
    @Test func taintedRequestShowsOneCheckLine() {
        let clock = TestClock()
        var request = approvalRequest(level: .confirm, now: clock.now)
        #expect(ApprovalSheetModel(request: request).taintedLine == nil)
        request.tainted = true
        let line = ApprovalSheetModel(request: request).taintedLine
        #expect(line == ApprovalSheetModel.taintedNotice)
        #expect(line?.contains("content ZORO read") == true && line?.contains("Check the details") == true)
    }

    @Test func cancelledFaceIDBringsTheSheetBackWithANotice() async throws {
        let clock = TestClock()
        let biometrics = CancelOnceBiometrics()
        let identity = FakeIdentity()
        let presenter = ApprovalSheetPresenter(biometrics: biometrics, now: clock.function)
        let coordinator = ApprovalCoordinator(identity: identity, biometrics: biometrics, presenter: presenter, now: clock.function)
        let decision = Task { try await coordinator.decide(approvalRequest(level: .biometric, now: clock.now)) }
        await waitUntil { presenter.current != nil }
        #expect(presenter.current?.notice == nil)
        presenter.approve()
        await waitUntil { presenter.current?.notice != nil }
        #expect(presenter.current?.notice == ApprovalCoordinator.cancelledNotice)
        #expect(presenter.current?.phase == .reviewing)
        presenter.approve()
        #expect(try await decision.value.approved)
        #expect(biometrics.calls.all.count == 2)
        #expect(identity.signed.all == [true])
    }
}
