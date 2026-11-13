import Foundation
import Observation
import SecurityManager
import ZoroCore
import ZoroDesign

/// Risk shown as words and a role colour (colour is never the only signal).
public struct RiskBadgeModel: Sendable, Equatable {
    public var label: String
    public var role: ZoroRole?

    public init(_ risk: RiskLevel) {
        switch risk {
        case .low: self.init(label: "Low risk", role: nil)
        case .medium: self.init(label: "Medium risk", role: .accent)
        case .high: self.init(label: "High risk", role: .attention)
        case .critical: self.init(label: "Critical risk", role: .critical)
        }
    }

    init(label: String, role: ZoroRole?) {
        self.label = label
        self.role = role
    }
}

public enum BiometricNames {
    /// "Face ID", "Touch ID", "Optic ID", or "your passcode" when no biometry is enrolled.
    public static func name(for kind: BiometryKind) -> String {
        switch kind {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .none: "your passcode"
        }
    }
}

/// One approval on screen: exactly what the server will execute, its risk, and how long it stays valid.
@MainActor
@Observable
public final class ApprovalSheetModel: Identifiable {
    public enum Phase: Sendable, Equatable {
        case reviewing
        /// Approved; the device is now verifying the owner (biometric level) and signing.
        case authenticating
        case approved
        case declined
        case expired
    }

    public let request: ApprovalRequest
    public let biometricName: String
    /// Why the sheet is back (the biometric step was cancelled or failed); nil on the first showing.
    public let notice: String?
    public private(set) var phase: Phase = .reviewing
    public nonisolated var id: String { request.approvalId }

    public init(request: ApprovalRequest, biometricName: String = "Face ID", notice: String? = nil) {
        self.request = request
        self.biometricName = biometricName
        self.notice = notice
    }

    public static let taintedNotice = "This request came from content ZORO read, such as a web page or an email. Check the details before you approve."

    /// Shown when the turn read external content (`ApprovalRequest.tainted`).
    public var taintedLine: String? { request.tainted ? Self.taintedNotice : nil }

    public var risk: RiskBadgeModel { RiskBadgeModel(request.risk) }
    public var requiresBiometric: Bool { request.level == .biometric }

    /// The approve button's words; the decline button is always "Decline" (one name per action).
    public var approveTitle: String { requiresBiometric ? "Approve with \(biometricName)" : "Approve" }
    public static let declineTitle = "Decline"

    /// The design-system summary: ZORO's sentence above the rekha, the exact facts below.
    public var summary: ApprovalSummary {
        ApprovalSummary(
            action: request.summary,
            details: request.details.map { ApprovalDetail(label: $0.label, value: $0.value) },
            amount: nil,
            level: requiresBiometric ? .biometric : .confirm,
            expiresAt: request.expiresAt,
            handoffNote: nil)
    }

    public func remainingSeconds(now: Date) -> Int {
        max(0, Int(request.expiresAt.timeIntervalSince(now).rounded(.down)))
    }

    public func expiryText(now: Date) -> String {
        summary.expiryText(now: now) ?? ""
    }

    public func isExpired(now: Date) -> Bool { request.expiresAt <= now }

    /// Returns false when the request already expired (and moves to `.expired`).
    func approve(now: Date) -> Bool {
        guard phase == .reviewing else { return false }
        guard !isExpired(now: now) else {
            phase = .expired
            return false
        }
        phase = requiresBiometric ? .authenticating : .approved
        return true
    }

    func decline() -> Bool {
        guard phase == .reviewing else { return false }
        phase = .declined
        return true
    }

    func expireIfDue(now: Date) -> Bool {
        guard phase == .reviewing, isExpired(now: now) else { return false }
        phase = .expired
        return true
    }

    func finishAuthentication() {
        if phase == .authenticating { phase = .approved }
    }
}

/// Presents approvals for `SecurityManager.ApprovalCoordinator`: shows the sheet and answers with the
/// owner's choice. The coordinator then authenticates (biometric level) and signs. An expired
/// request throws `ZoroError.approvalExpired`; dismissing without a choice throws `.userCancelled`.
@MainActor
@Observable
public final class ApprovalSheetPresenter: ApprovalPresenting {
    public private(set) var current: ApprovalSheetModel?

    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Error>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private let biometrics: any BiometricAuthenticating
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(biometrics: any BiometricAuthenticating, now: @escaping @Sendable () -> Date = { Date() }) {
        self.biometrics = biometrics
        self.now = now
    }

    public func present(_ request: ApprovalRequest) async throws -> Bool {
        try await present(request, notice: nil)
    }

    /// Shows the request again after the biometric step was cancelled or failed, with `notice` on top.
    public func present(_ request: ApprovalRequest, notice: String?) async throws -> Bool {
        // A newer request replaces one still on screen; the older one counts as dismissed.
        finish(.failure(ZoroError.userCancelled), close: true)
        guard request.expiresAt > now() else { throw ZoroError.approvalExpired }
        let name = BiometricNames.name(for: await biometrics.availability().kind)
        let model = ApprovalSheetModel(request: request, biometricName: name, notice: notice)
        current = model
        scheduleExpiry(for: model)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(ZoroError.cancelled), close: true) }
        }
    }

    public func approve() {
        guard let model = current else { return }
        if model.approve(now: now()) {
            // Biometric level: the sheet stays, saying it is waiting for Face ID, until the turn moves on.
            finish(.success(true), close: !model.requiresBiometric)
        } else if model.phase == .expired {
            finish(.failure(ZoroError.approvalExpired), close: false)
        }
    }

    public func decline() {
        guard let model = current, model.decline() else { return }
        finish(.success(false), close: true)
    }

    /// The sheet was swiped away or closed.
    public func dismiss() {
        if continuation != nil {
            finish(.failure(ZoroError.userCancelled), close: true)
        } else {
            current = nil
        }
    }

    /// Expires the request on screen when its time has passed. The timer calls it; tests call it directly.
    public func expireIfDue() {
        guard let model = current, model.expireIfDue(now: now()) else { return }
        finish(.failure(ZoroError.approvalExpired), close: false)
    }

    /// Closes a sheet left open for authentication once the turn has moved on.
    public func conversationMoved(awaitingApprovalId: String?) {
        guard let model = current, continuation == nil, model.phase == .authenticating || model.phase == .approved else { return }
        if awaitingApprovalId != model.id {
            model.finishAuthentication()
            current = nil
        }
    }

    private func scheduleExpiry(for model: ApprovalSheetModel) {
        expiryTask?.cancel()
        let delay = model.request.expiresAt.timeIntervalSince(now())
        expiryTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.expireIfDue()
        }
    }

    private func finish(_ result: Result<Bool, Error>, close: Bool) {
        expiryTask?.cancel()
        expiryTask = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        }
        if close { current = nil }
    }
}
