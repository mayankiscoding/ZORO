import Foundation
import NativeActionBroker
import ZoroCore

/// One `DeviceActionExecuting` for the app: the native action broker (system, health and music
/// handlers) plus executors from other packages that are not broker handlers, such as
/// `PhotoSearchActionHandler`. A tool goes to the first part that lists it; a tool nobody lists is
/// answered `unsupported` without running anything.
public struct CompositeDeviceActionExecutor: DeviceActionExecuting {
    private let parts: [any DeviceActionExecuting]

    public init(_ parts: [any DeviceActionExecuting]) {
        self.parts = parts
    }

    public var supportedTools: [String] {
        get async {
            var all = Set<String>()
            for part in parts { all.formUnion(await part.supportedTools) }
            return all.sorted()
        }
    }

    public func execute(_ request: DeviceActionRequest) async -> DeviceActionResult {
        for part in parts where await part.supportedTools.contains(request.tool) {
            return await part.execute(request)
        }
        return .failure(
            request, code: .unsupported, message: "This device can't run \(request.tool).", capabilityStatus: .unavailable)
    }
}

/// The quick actions shown in Device control, built from the device-contract tool names the broker
/// actually registers on this platform (the screen hides any the device does not report).
public enum DeviceQuickActions {
    public struct Spec: Sendable, Equatable {
        public var id: String
        public var title: String
        public var detail: String
        public var symbol: String
        public var tool: String
        public var args: JSONObject
        public var risk: RiskLevel
    }

    public static func specs(for platform: DevicePlatform) -> [Spec] {
        var out: [Spec] = []
        if platform == .ios {
            out.append(Spec(
                id: "timer-10", title: "Set a 10 minute timer", detail: "Starts on this iPhone.", symbol: "timer",
                tool: DeviceToolName.timerStart.rawValue, args: ["seconds": 600, "label": "Timer"], risk: .medium))
            out.append(Spec(
                id: "timer-25", title: "Start a 25 minute focus timer", detail: "Starts on this iPhone.", symbol: "timer.circle",
                tool: DeviceToolName.timerStart.rawValue, args: ["seconds": 1500, "label": "Focus"], risk: .medium))
        }
        out.append(Spec(
            id: "music-pause", title: "Pause music", detail: "Pauses what's playing on this device.", symbol: "pause.circle",
            tool: DeviceToolName.musicControl.rawValue, args: ["action": "pause"], risk: .low))
        out.append(Spec(
            id: "music-next", title: "Next song", detail: "Skips to the next song on this device.", symbol: "forward.end",
            tool: DeviceToolName.musicControl.rawValue, args: ["action": "next"], risk: .low))
        return out
    }
}
