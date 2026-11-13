import Foundation
import ZoroCore

public enum DeviceChannelState: Sendable, Equatable {
    case idle
    case connecting(attempt: Int)
    case connected
    case waiting(attempt: Int, delay: Double)
    case stopped
}

/// Supplies the tool names a device announces in its channel hello (for example
/// `DeviceCapabilityRegistry.supportedTools(permissions:)` with the current permissions).
public typealias DeviceCapabilitiesProvider = @Sendable () async -> [String]

/// The device's live channel to `/v1/devices/channel`: says hello with its capabilities, runs device
/// actions the backend pushes through a `DeviceActionExecuting`, returns the results, and reconnects
/// with backoff. Expired, unsupported or mis-addressed actions are answered without running anything.
public actor DeviceChannel {
    public struct Configuration: Sendable {
        public var backoff: BackoffPolicy
        /// Seconds between `ping` frames; nil disables pings.
        public var pingInterval: Double?
        public init(backoff: BackoffPolicy = BackoffPolicy(), pingInterval: Double? = 25) {
            self.backoff = backoff
            self.pingInterval = pingInterval
        }
    }

    public private(set) var state: DeviceChannelState = .idle
    public nonisolated let states: AsyncStream<DeviceChannelState>

    private let stateContinuation: AsyncStream<DeviceChannelState>.Continuation
    private let channelURL: URL
    private let connector: any WebSocketConnecting
    private let tokens: any AccessTokenProviding
    private let executor: any DeviceActionExecuting
    private let configuration: Configuration
    private let sleeper: any Sleeping
    private let random: @Sendable () -> Double
    private let now: @Sendable () -> Date
    private let deviceId: String?
    private let onApprovalRequired: (@Sendable (ApprovalRequest) async -> Void)?
    private let capabilities: DeviceCapabilitiesProvider?
    private let log = ZoroLog("device-channel")
    /// The open connection while `state == .connected`.
    private var connection: (any WebSocketConnection)?

    private var runTask: Task<Void, Never>?
    private var completed: [String: DeviceActionResult] = [:]
    private var completedOrder: [String] = []
    private var inFlight: Set<String> = []

    public init(
        baseURL: URL, connector: any WebSocketConnecting = URLSessionWebSocketConnector(), tokens: any AccessTokenProviding,
        executor: any DeviceActionExecuting, deviceId: String? = nil, configuration: Configuration = Configuration(),
        sleeper: any Sleeping = TaskSleeper(), random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        now: @escaping @Sendable () -> Date = { Date() },
        onApprovalRequired: (@Sendable (ApprovalRequest) async -> Void)? = nil,
        capabilities: DeviceCapabilitiesProvider? = nil
    ) {
        self.channelURL = Self.channelURL(from: baseURL)
        self.connector = connector
        self.tokens = tokens
        self.executor = executor
        self.deviceId = deviceId
        self.configuration = configuration
        self.sleeper = sleeper
        self.random = random
        self.now = now
        self.onApprovalRequired = onApprovalRequired
        self.capabilities = capabilities
        (states, stateContinuation) = AsyncStream.makeStream(of: DeviceChannelState.self, bufferingPolicy: .bufferingNewest(32))
    }

    /// `https://host/base` → `wss://host/base/v1/devices/channel`.
    public static func channelURL(from baseURL: URL) -> URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.scheme = (c.scheme == "http" || c.scheme == "ws") ? "ws" : "wss"
        let base = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
        c.path = base + "/v1/devices/channel"
        return c.url ?? baseURL
    }

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.run() }
    }

    public func stop() async {
        let task = runTask
        runTask = nil
        task?.cancel()
        await task?.value
        set(.stopped)
    }

    /// Sends `hello` again with fresh capabilities (for example after a permission change). Does
    /// nothing while disconnected: the next connection says hello with the fresh list anyway.
    /// Returns whether a hello was sent.
    @discardableResult
    public func refreshCapabilities() async -> Bool {
        guard let connection, state == .connected else { return false }
        do {
            try await connection.send(Self.frame(Hello(capabilities: await currentCapabilities())))
            return true
        } catch {
            log.error("could not re-send the channel hello", error: error)
            return false
        }
    }

    /// The provider's list when there is one, otherwise the executor's.
    func currentCapabilities() async -> [String] {
        if let capabilities { return await capabilities() }
        return await executor.supportedTools
    }

    private func set(_ new: DeviceChannelState) {
        guard new != state else { return }
        state = new
        stateContinuation.yield(new)
    }

    // MARK: - Connection loop

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            set(.connecting(attempt: attempt))
            var token: String?
            do {
                let t = try await tokens.validAccessToken()
                token = t
                var request = URLRequest(url: channelURL)
                request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
                let connection = try await connector.connect(request)
                do {
                    try await connection.send(Self.frame(Hello(capabilities: await currentCapabilities())))
                    attempt = 0
                    self.connection = connection
                    set(.connected)
                    log.info("device channel connected")
                    try await session(connection)
                } catch {
                    self.connection = nil
                    await connection.close()
                    throw error
                }
            } catch {
                if Task.isCancelled { break }
                if ZoroError.wrap(error) == .unauthorized, let token { await tokens.invalidate(token: token) }
                log.error("device channel dropped", error: error)
            }
            if Task.isCancelled { break }
            let delay = configuration.backoff.delay(attempt: attempt, random: random())
            attempt += 1
            set(.waiting(attempt: attempt, delay: delay))
            do { try await sleeper.sleep(seconds: delay) } catch { break }
        }
    }

    private func session(_ connection: any WebSocketConnection) async throws {
        let pinger: Task<Void, Never>? = configuration.pingInterval.map { interval in
            Task { [sleeper] in
                while !Task.isCancelled {
                    do {
                        try await sleeper.sleep(seconds: interval)
                        try await connection.send(#"{"type":"ping"}"#)
                    } catch { return }
                }
            }
        }
        defer { pinger?.cancel() }
        while !Task.isCancelled {
            let text = try await connection.receive()
            await handle(frame: text, on: connection)
        }
        throw CancellationError()
    }

    private func handle(frame text: String, on connection: any WebSocketConnection) async {
        guard let value = try? ZoroJSON.decoder().decode(JSONValue.self, from: Data(text.utf8)),
              let type = value["type"]?.stringValue
        else {
            log.info("ignored a malformed channel frame")
            return
        }
        switch type {
        case "device_action":
            guard let event = try? value.decode(DeviceActionEvent.self) else {
                log.info("ignored an undecodable device action")
                return
            }
            Task { await self.run(event.action, on: connection) }
        case "approval_required":
            guard let event = try? value.decode(ApprovalRequired.self), let handler = onApprovalRequired else { return }
            Task { await handler(event.approval) }
        default:
            break  // pong and future frame types
        }
    }

    // MARK: - Device actions

    private func run(_ action: DeviceActionRequest, on connection: any WebSocketConnection) async {
        let result: DeviceActionResult
        if let cached = completed[action.actionId] {
            result = cached  // redelivery after a reconnect: answer again, never run twice
        } else {
            guard inFlight.insert(action.actionId).inserted else { return }
            result = await execute(action)
            inFlight.remove(action.actionId)
            remember(result)
        }
        do {
            try await connection.send(Self.frame(ResultFrame(result: result)))
        } catch {
            log.error("could not return device action result", error: error)
        }
    }

    /// Validates, then runs the action. Never throws.
    public func execute(_ action: DeviceActionRequest) async -> DeviceActionResult {
        if action.expiresAt <= now() {
            return .failure(action, code: .expired, message: "The request expired before it reached this device.", at: now())
        }
        if let target = action.targetDeviceId, let deviceId, target != deviceId {
            return .failure(action, code: .unsupported, message: "This request was addressed to another device.", at: now())
        }
        guard await executor.supportedTools.contains(action.tool) else {
            return .failure(action, code: .unsupported, message: "This device cannot run \(action.tool).", capabilityStatus: .unavailable, at: now())
        }
        return await executor.execute(action)
    }

    private func remember(_ result: DeviceActionResult) {
        completed[result.actionId] = result
        completedOrder.append(result.actionId)
        if completedOrder.count > 200 {
            completed.removeValue(forKey: completedOrder.removeFirst())
        }
    }

    // MARK: - Frames

    struct Hello: Encodable {
        let type = "hello"
        let capabilities: [String]
    }

    struct ResultFrame: Encodable {
        let type = "device_action_result"
        let result: DeviceActionResult
    }

    static func frame<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try ZoroJSON.encoder().encode(value), as: UTF8.self)
    }
}
