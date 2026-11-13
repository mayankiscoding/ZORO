import Foundation
import ZoroCore

/// A validated action, ready to confirm and run.
public struct PreparedDeviceAction: Sendable {
    /// One plain sentence of what will happen, shown on the confirmation sheet.
    public var summary: String
    /// The capability status reported when the action succeeds.
    public var successStatus: CapabilityStatus
    private let body: @Sendable () async throws -> DeviceActionOutput

    public init(summary: String, successStatus: CapabilityStatus = .workingNative, run: @escaping @Sendable () async throws -> JSONObject) {
        self.summary = summary
        self.successStatus = successStatus
        self.body = { DeviceActionOutput(result: try await run()) }
    }

    /// For actions whose capability status is only known after running (for example which provider played).
    public init(summary: String, successStatus: CapabilityStatus = .workingNative, runReportingStatus: @escaping @Sendable () async throws -> DeviceActionOutput) {
        self.summary = summary
        self.successStatus = successStatus
        self.body = runReportingStatus
    }

    public func run() async throws -> DeviceActionOutput { try await body() }
}

public struct DeviceActionOutput: Sendable, Equatable {
    public var result: JSONObject
    /// Overrides `PreparedDeviceAction.successStatus` when set.
    public var status: CapabilityStatus?
    public init(result: JSONObject, status: CapabilityStatus? = nil) {
        self.result = result
        self.status = status
    }
}

/// Handles one or more contract tools. `prepare` only decodes and validates (no side effects, no
/// permission prompts); everything with an effect happens inside `run`.
public protocol DeviceActionHandler: Sendable {
    var tools: [DeviceToolName] { get }
    func prepare(_ tool: DeviceToolName, _ args: ToolArguments) throws -> PreparedDeviceAction
}

/// What the owner is asked before a request with `requires_user_confirmation` runs.
public struct DeviceActionConfirmation: Sendable, Equatable {
    public var actionId: String
    public var tool: String
    public var summary: String
    public var risk: RiskLevel
    public init(actionId: String, tool: String, summary: String, risk: RiskLevel) {
        self.actionId = actionId
        self.tool = tool
        self.summary = summary
        self.risk = risk
    }
}

/// The app shell shows a confirmation sheet; `false` means the owner declined.
public protocol DeviceActionConfirming: Sendable {
    func confirm(_ confirmation: DeviceActionConfirmation) async -> Bool
}
