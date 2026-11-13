import Foundation
import Observation
import ZoroCore
import ZoroDesign

public enum DeviceActionConfirmation: Sendable, Equatable {
    case confirmed, declined, expired
}

/// Asks the owner before a device action the server flagged `requires_user_confirmation`.
public protocol DeviceActionConfirming: Sendable {
    @MainActor func confirm(_ request: DeviceActionRequest) async -> DeviceActionConfirmation
}

/// Wraps the real device-action executor: actions flagged `requiresUserConfirmation` run only after the
/// owner confirms them; expired actions never run.
public struct ConfirmingDeviceActionExecutor: DeviceActionExecuting {
    private let base: any DeviceActionExecuting
    private let confirmer: any DeviceActionConfirming
    private let now: @Sendable () -> Date

    public init(base: any DeviceActionExecuting, confirmer: any DeviceActionConfirming, now: @escaping @Sendable () -> Date = { Date() }) {
        self.base = base
        self.confirmer = confirmer
        self.now = now
    }

    public var supportedTools: [String] { get async { await base.supportedTools } }

    public func execute(_ request: DeviceActionRequest) async -> DeviceActionResult {
        guard request.expiresAt > now() else {
            return .failure(request, code: .expired, message: "This action expired before it ran.", at: now())
        }
        guard request.requiresUserConfirmation else { return await base.execute(request) }
        switch await confirmer.confirm(request) {
        case .confirmed:
            guard request.expiresAt > now() else {
                return .failure(request, code: .expired, message: "This action expired before it ran.", at: now())
            }
            return await base.execute(request)
        case .declined:
            return .failure(request, code: .userCancelled, message: "The owner declined this action.", at: now())
        case .expired:
            return .failure(request, code: .expired, message: "This action expired before it ran.", at: now())
        }
    }
}

/// The confirmation sheet's content: the tool in plain words and its exact arguments.
public struct DeviceActionSheetContent: Sendable, Equatable {
    public var title: String
    public var rows: [GenericCardModel.Row]
    public var risk: RiskBadgeModel

    public init(_ request: DeviceActionRequest) {
        let name = request.tool.split(separator: ".").last.map(String.init) ?? request.tool
        title = GenericCardModel.humanise(name)
        rows = request.args.keys.sorted().compactMap { key in
            GenericCardModel.display(request.args[key]!).map { GenericCardModel.Row(label: GenericCardModel.humanise(key), value: $0) }
        }
        risk = RiskBadgeModel(request.risk)
    }
}

/// Presents device-action confirmations as a sheet.
@MainActor
@Observable
public final class DeviceActionConfirmationPresenter: DeviceActionConfirming {
    public private(set) var current: DeviceActionRequest?
    @ObservationIgnored private var continuation: CheckedContinuation<DeviceActionConfirmation, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public var content: DeviceActionSheetContent? { current.map(DeviceActionSheetContent.init) }

    public func confirm(_ request: DeviceActionRequest) async -> DeviceActionConfirmation {
        resolve(.declined)
        guard request.expiresAt > now() else { return .expired }
        current = request
        let delay = request.expiresAt.timeIntervalSince(now())
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.expireIfDue()
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    public func confirmCurrent() {
        guard let request = current else { return }
        resolve(request.expiresAt > now() ? .confirmed : .expired)
    }

    public func declineCurrent() { resolve(.declined) }

    public func expireIfDue() {
        guard let request = current, request.expiresAt <= now() else { return }
        resolve(.expired)
    }

    private func resolve(_ answer: DeviceActionConfirmation) {
        expiryTask?.cancel()
        expiryTask = nil
        current = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: answer)
        }
    }
}
