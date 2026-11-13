import Foundation
import Observation
import ZoroCore

/// A one-tap action that runs a device tool on this device (a timer, a shortcut). Only low and
/// medium risk tools can be quick actions: anything riskier must go through ZORO so the backend's
/// policy engine can ask for an approval.
public struct DeviceQuickAction: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var symbol: String
    public var tool: String
    public var args: JSONObject
    public var risk: RiskLevel

    public init(id: String, title: String, detail: String = "", symbol: String, tool: String, args: JSONObject = [:], risk: RiskLevel = .low) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.tool = tool
        self.args = args
        self.risk = risk
    }

    /// Shown only when the device reports it supports the tool. The app shell may replace these with
    /// the tool names its native action broker registers.
    public static let suggested: [DeviceQuickAction] = [
        DeviceQuickAction(
            id: "timer-10", title: "Set a 10 minute timer", detail: "Starts on this device.", symbol: "timer",
            tool: "device.set_timer", args: ["seconds": 600], risk: .low),
        DeviceQuickAction(
            id: "timer-25", title: "Set a 25 minute focus timer", detail: "Starts on this device.", symbol: "timer.circle",
            tool: "device.set_timer", args: ["seconds": 1500, "label": "Focus"], risk: .low),
    ]
}

public struct DeviceRow: Identifiable, Equatable, Sendable {
    public var info: DeviceInfo
    public var isThisDevice: Bool
    public var id: String { info.deviceId }

    public var platformLabel: String { info.platform == .ios ? "iPhone" : "Mac" }
    public var symbol: String { info.platform == .ios ? "iphone" : "laptopcomputer" }

    public func statusText(now: Date = Date()) -> String {
        if info.revoked { return "Removed" }
        if info.online { return "Online" }
        if let seen = info.lastSeenAt { return "Offline, last seen \(SystemFormat.relative(seen, to: now))" }
        return "Offline"
    }
}

public struct QuickActionRow: Identifiable, Equatable, Sendable {
    public var action: DeviceQuickAction
    /// nil when the action can run; otherwise one sentence on why not.
    public var unavailableReason: String?
    public var id: String { action.id }
    public var isAvailable: Bool { unavailableReason == nil }
}

/// Things iOS (and ZORO's own rules) do not allow, stated plainly so nobody expects them.
public struct RestrictedItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var explanation: String
}

public enum RestrictedActions {
    /// Product rules from CLAUDE.md and the voice and copy guide: what ZORO will not do and why.
    public static let standard: [RestrictedItem] = [
        RestrictedItem(
            id: "read-messages", title: "Read your messages",
            explanation: "iOS doesn't let apps read your messages. ZORO can open WhatsApp with the text ready for you to send."),
        RestrictedItem(
            id: "pay", title: "Pay or place an order for you",
            explanation: "Payments and orders finish in the provider's own app. ZORO never pays for you."),
        RestrictedItem(
            id: "other-apps", title: "Tap or type inside other apps",
            explanation: "iOS keeps apps apart, and ZORO doesn't use accessibility tricks to get around that."),
        RestrictedItem(
            id: "always-listening", title: "Listen all the time",
            explanation: "ZORO listens only while the orb is listening, after you press or tap."),
    ]
}

/// Devices with online state, quick actions that run device tools through `DeviceActionExecuting`,
/// and the restricted list.
@MainActor
@Observable
public final class DeviceControlViewModel {
    public private(set) var phase: ScreenPhase = .idle
    public private(set) var devices: [DeviceRow] = []
    public private(set) var quickActions: [QuickActionRow] = []
    public private(set) var restricted: [RestrictedItem] = RestrictedActions.standard
    public private(set) var killSwitchOn = false
    public private(set) var runningActionId: String?
    public private(set) var notice: SystemNotice?
    /// A medium-risk quick action waiting for the owner to confirm.
    public private(set) var pendingConfirmation: DeviceQuickAction?

    @ObservationIgnored private let api: any ZoroAPI
    @ObservationIgnored private let identity: any DeviceIdentityProviding
    @ObservationIgnored private let executor: any DeviceActionExecuting
    @ObservationIgnored private let actions: [DeviceQuickAction]
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var thisDeviceId: String?

    public init(
        api: any ZoroAPI, identity: any DeviceIdentityProviding, executor: any DeviceActionExecuting,
        quickActions: [DeviceQuickAction] = DeviceQuickAction.suggested, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.identity = identity
        self.executor = executor
        actions = quickActions
        self.now = now
    }

    public var emptyMessage: String {
        "No devices are paired. Pair this device from Settings."
    }

    public func load() async {
        phase = .loading
        thisDeviceId = await identity.deviceId()
        do {
            let state = try await api.securityState()
            killSwitchOn = state.killSwitch
            let me = thisDeviceId
            devices = state.devices.filter { !$0.revoked }
                .map { DeviceRow(info: $0, isThisDevice: $0.deviceId == me) }
                .sorted { ($0.isThisDevice ? 0 : 1, $0.info.name) < ($1.isThisDevice ? 0 : 1, $1.info.name) }
            await refreshQuickActions()
            // Restricted list: the standard list plus anything the server registry marks "not allowed by iOS".
            if let caps = try? await api.capabilities() {
                let extra = caps.filter { $0.status == .restrictedByIos }.map {
                    RestrictedItem(id: "cap-\($0.id)", title: $0.title, explanation: $0.note.isEmpty ? "iOS doesn't allow this." : $0.note)
                }
                restricted = RestrictedActions.standard + extra
            }
            phase = devices.isEmpty ? .empty : .loaded
        } catch {
            guard let next = SystemFailure.phase(for: error) else { return }
            await refreshQuickActions()
            phase = next
        }
    }

    private func refreshQuickActions() async {
        let supported = Set(await executor.supportedTools)
        quickActions = actions.map { action in
            var reason: String?
            if action.risk > .medium {
                reason = "This needs your approval, so ask ZORO instead."
            } else if killSwitchOn {
                reason = SystemCopy.killSwitchOn
            } else if !supported.contains(action.tool) {
                reason = "This device can't do that yet."
            }
            return QuickActionRow(action: action, unavailableReason: reason)
        }
    }

    /// Runs a quick action. Low risk runs at once; medium risk waits for `confirmPending()`.
    public func run(_ action: DeviceQuickAction) async {
        guard runningActionId == nil else { return }
        guard let row = quickActions.first(where: { $0.id == action.id }) else {
            notice = .failure("That action isn't available. Reload and try again.")
            return
        }
        if let reason = row.unavailableReason {
            notice = .failure(reason)
            return
        }
        if row.action.risk >= .medium {
            pendingConfirmation = row.action
            return
        }
        await execute(row.action)
    }

    public func confirmPending() async {
        guard let action = pendingConfirmation, runningActionId == nil else { return }
        pendingConfirmation = nil
        guard quickActions.first(where: { $0.id == action.id })?.isAvailable == true else {
            notice = .failure("That action isn't available. Reload and try again.")
            return
        }
        await execute(action)
    }

    public func cancelPending() { pendingConfirmation = nil }
    public func dismissNotice() { notice = nil }

    private func execute(_ action: DeviceQuickAction) async {
        runningActionId = action.id
        defer { runningActionId = nil }
        let request = DeviceActionRequest(
            actionId: "quick-\(UUID().uuidString)", turnId: nil, targetDeviceId: thisDeviceId, tool: action.tool,
            args: action.args, risk: action.risk, requiresUserConfirmation: action.risk >= .medium,
            expiresAt: now().addingTimeInterval(60))
        let result = await executor.execute(request)
        if Task.isCancelled { return }
        if result.ok {
            notice = .success("Done. \(action.title).")
        } else {
            notice = .failure(Self.failureText(result))
        }
    }

    static func failureText(_ result: DeviceActionResult) -> String {
        switch DeviceActionErrorCode(rawValue: result.errorCode ?? "") {
        case .permissionDenied: "ZORO needs permission for this. Allow it in Settings, then try again."
        case .unsupported: "This device can't do that."
        case .userCancelled: "Cancelled. Nothing was changed."
        case .expired: "That took too long, so it was stopped. Try again."
        case .invalidArguments: "ZORO sent this device something it could not use. Nothing was changed."
        case .failed, .none:
            result.errorMessage.map { $0.hasSuffix(".") ? $0 : $0 + "." } ?? "That didn't work. Try again."
        }
    }
}
