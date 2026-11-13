import Foundation
import ZoroCore

/// Routes `DeviceActionRequest`s to handlers by tool name. Never throws: every failure is a
/// `DeviceActionResult` with a contract error code and a `CapabilityStatus`.
///
/// Duplicate deliveries of the same `action_id` (channel reconnects, resumed turns) run once: a second
/// caller waits for the first run or gets its remembered result.
public actor NativeActionBroker: DeviceActionExecuting {
    private let platform: DevicePlatform
    private var handlers: [DeviceToolName: any DeviceActionHandler] = [:]
    private let confirmer: (any DeviceActionConfirming)?
    private let now: @Sendable () -> Date
    private let log = ZoroLog("device.broker")

    private var inFlight: [String: Task<DeviceActionResult, Never>] = [:]
    private var completed: [String: DeviceActionResult] = [:]
    private var completedOrder: [String] = []
    private let rememberLimit = 128

    public init(
        platform: DevicePlatform = .running, handlers: [any DeviceActionHandler],
        confirmer: (any DeviceActionConfirming)?, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.platform = platform
        self.confirmer = confirmer
        self.now = now
        for handler in handlers {
            for tool in handler.tools where tool.platforms.contains(platform) {
                self.handlers[tool] = handler
            }
        }
    }

    /// Adds a handler from another package (for example `device.photos.search` from ZoroPhotos).
    public func register(_ handler: any DeviceActionHandler) {
        for tool in handler.tools where tool.platforms.contains(platform) {
            handlers[tool] = handler
        }
    }

    public var supportedTools: [String] {
        handlers.keys.map(\.rawValue).sorted()
    }

    public func execute(_ request: DeviceActionRequest) async -> DeviceActionResult {
        if let done = completed[request.actionId] { return done }
        let task: Task<DeviceActionResult, Never>
        if let running = inFlight[request.actionId] {
            task = running
        } else {
            task = Task { await self.perform(request) }
            inFlight[request.actionId] = task
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if inFlight[request.actionId] != nil {
            inFlight[request.actionId] = nil
            remember(result)
        }
        return result
    }

    private func remember(_ result: DeviceActionResult) {
        completed[result.actionId] = result
        completedOrder.append(result.actionId)
        if completedOrder.count > rememberLimit {
            completed[completedOrder.removeFirst()] = nil
        }
    }

    private func perform(_ request: DeviceActionRequest) async -> DeviceActionResult {
        func fail(_ e: DeviceActionError) -> DeviceActionResult {
            log.info("device action \(request.tool) failed: \(e.code.rawValue)")
            return .failure(request, code: e.code, message: e.message, capabilityStatus: e.capabilityStatus, at: now())
        }
        if request.expiresAt <= now() {
            return fail(DeviceActionError(.expired, "This request expired before it reached the device."))
        }
        guard let tool = DeviceToolName(rawValue: request.tool) else {
            return fail(.unsupported("This device does not know the tool \(request.tool)."))
        }
        guard tool.platforms.contains(platform) else {
            let status: CapabilityStatus = platform == .ios ? .restrictedByIos : .unavailable
            return fail(.unsupported("\(tool.rawValue) does not run on \(platform == .ios ? "iPhone" : "Mac").", status: status))
        }
        guard let handler = handlers[tool] else {
            return fail(.unsupported("\(tool.rawValue) is not available on this device."))
        }
        do {
            let prepared = try handler.prepare(tool, ToolArguments(request.args))
            if request.requiresUserConfirmation {
                guard let confirmer else {
                    throw DeviceActionError.unsupported("This device cannot ask for confirmation.", status: .manualUserStep)
                }
                let confirmation = DeviceActionConfirmation(
                    actionId: request.actionId, tool: tool.rawValue, summary: prepared.summary, risk: request.risk)
                guard await confirmer.confirm(confirmation) else { throw DeviceActionError.userCancelled }
                if request.expiresAt <= now() {
                    throw DeviceActionError(.expired, "This request expired while waiting for confirmation.")
                }
            }
            try Task.checkCancellation()
            let output = try await prepared.run()
            return DeviceActionResult(
                actionId: request.actionId, ok: true, result: output.result,
                capabilityStatus: output.status ?? prepared.successStatus,
                executedAt: now())
        } catch {
            return fail(Self.map(error))
        }
    }

    static func map(_ error: Error) -> DeviceActionError {
        switch error {
        case let e as DeviceActionError: return e
        case is CancellationError: return .failed("The action was cancelled.")
        case let z as ZoroError:
            switch z {
            case .userCancelled: return .userCancelled
            case .cancelled: return .failed("The action was cancelled.")
            case .unavailable(let capability, let reason): return .unsupported("\(capability) is not available: \(reason)")
            default: return .failed(z.errorDescription ?? "The action failed.")
            }
        default:
            // Never echo raw system error text: it can carry personal data.
            return .failed("The action failed (\(String(describing: type(of: error)))).")
        }
    }
}
