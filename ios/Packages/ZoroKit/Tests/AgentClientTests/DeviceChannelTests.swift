import Foundation
import Testing
import ZoroCore
@testable import AgentClient

private func actionFrame(id: String, tool: String = "ios.alarm.create", expires: String = "2099-01-01T00:00:00Z", target: String? = nil) -> String {
    let targetField = target.map { #","target_device_id":"\#($0)""# } ?? ""
    return #"{"type":"device_action","action":{"action_id":"\#(id)","tool":"\#(tool)","args":{"time":"07:00"},"risk":"medium","expires_at":"\#(expires)"\#(targetField)}}"#
}

private func decodeSent(_ frame: String) throws -> JSONValue {
    try ZoroJSON.decoder().decode(JSONValue.self, from: Data(frame.utf8))
}

@Suite("Device channel", .timeLimit(.minutes(1)))
struct DeviceChannelTests {
    @Test func channelURLUsesWebSocketScheme() {
        #expect(DeviceChannel.channelURL(from: URL(string: "https://h:8443/")!).absoluteString == "wss://h:8443/v1/devices/channel")
        #expect(DeviceChannel.channelURL(from: URL(string: "http://h/api")!).absoluteString == "ws://h/api/v1/devices/channel")
    }

    @Test func backoffGrowsAndCaps() {
        let p = BackoffPolicy(initial: 1, multiplier: 2, maximum: 10, jitter: 0.2)
        #expect((0..<6).map { p.delay(attempt: $0, random: 0.5) } == [1, 2, 4, 8, 10, 10])
        #expect(p.delay(attempt: 0, random: 0) == 0.8)
        #expect(p.delay(attempt: 0, random: 1) == 1.2)
    }

    @Test func reconnectsWithBackoffSaysHelloAndReturnsResults() async throws {
        let first = FakeSocket()
        let second = FakeSocket()
        let connector = FakeConnector([.fail(URLError(.cannotConnectToHost)), .fail(URLError(.timedOut)), .socket(first), .socket(second)])
        let sleeper = InstantSleeper()
        let executor = FakeExecutor()
        let channel = DeviceChannel(
            baseURL: URL(string: "https://h/")!, connector: connector, tokens: FakeTokens(), executor: executor,
            configuration: .init(backoff: BackoffPolicy(jitter: 0), pingInterval: nil), sleeper: sleeper, random: { 0.5 })
        await channel.start()

        try await waitUntil { first.sent.get.count == 1 }
        let hello = try decodeSent(first.sent.get[0])
        #expect(hello["type"] == "hello")
        #expect(hello["capabilities"] == ["ios.alarm.create"])
        #expect(await channel.state == .connected)
        #expect(connector.requests.get.last?.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")

        first.push(actionFrame(id: "act_1"))
        try await waitUntil { first.sent.get.count == 2 }
        let result = try decodeSent(first.sent.get[1])
        #expect(result["type"] == "device_action_result")
        #expect(result["result"]?["action_id"] == "act_1")
        #expect(result["result"]?["ok"] == true)
        #expect(result["result"]?["result"]?["alarm_id"] == "A1")

        first.disconnect()
        try await waitUntil { second.sent.get.count == 1 }
        #expect(first.closed.get)
        // Two failed attempts (1 s, 2 s), then a dropped live connection restarts from the initial delay.
        #expect(sleeper.delays.get == [1, 2, 1])

        // A redelivered action after reconnect is answered from the cache, not executed again.
        second.push(actionFrame(id: "act_1"))
        try await waitUntil { second.sent.get.count == 2 }
        #expect(await executor.executed == ["act_1"])

        await channel.stop()
        #expect(await channel.state == .stopped)
    }

    @Test func rejectsExpiredUnsupportedAndMisaddressedActions() async throws {
        let socket = FakeSocket()
        let executor = FakeExecutor()
        let channel = DeviceChannel(
            baseURL: URL(string: "https://h/")!, connector: FakeConnector([.socket(socket)]), tokens: FakeTokens(),
            executor: executor, deviceId: "dev_me", configuration: .init(pingInterval: nil), sleeper: InstantSleeper())
        await channel.start()
        try await waitUntil { socket.sent.get.count == 1 }
        socket.push(actionFrame(id: "old", expires: "2020-01-01T00:00:00Z"))
        socket.push(actionFrame(id: "nope", tool: "ios.bank.transfer"))
        socket.push(actionFrame(id: "other", target: "dev_other"))
        socket.push("not json")
        socket.push(#"{"type":"pong"}"#)
        try await waitUntil { socket.sent.get.count == 4 }
        let codes = try socket.sent.get.dropFirst().map { try decodeSent($0)["result"]?["error_code"]?.stringValue }
        #expect(Set(codes.compactMap { $0 }) == ["expired", "unsupported"])
        #expect(codes.count == 3)
        #expect(await executor.executed.isEmpty)
        await channel.stop()
    }

    @Test func unauthorizedHandshakeInvalidatesToken() async throws {
        let tokens = FakeTokens()
        let socket = FakeSocket()
        let connector = FakeConnector([.fail(ZoroError.unauthorized), .socket(socket)])
        let channel = DeviceChannel(
            baseURL: URL(string: "https://h/")!, connector: connector, tokens: tokens, executor: FakeExecutor(),
            configuration: .init(pingInterval: nil), sleeper: InstantSleeper())
        await channel.start()
        try await waitUntil { socket.sent.get.count == 1 }
        #expect(await tokens.invalidated == ["token-1"])
        #expect(connector.requests.get.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer token-1", "Bearer token-2"])
        await channel.stop()
    }

    @Test func forwardsApprovalRequests() async throws {
        let socket = FakeSocket()
        let received = Locked<[String]>([])
        let channel = DeviceChannel(
            baseURL: URL(string: "https://h/")!, connector: FakeConnector([.socket(socket)]), tokens: FakeTokens(),
            executor: FakeExecutor(), configuration: .init(pingInterval: nil), sleeper: InstantSleeper(),
            onApprovalRequired: { approval in received.withLock { $0.append(approval.approvalId) } })
        await channel.start()
        try await waitUntil { socket.sent.get.count == 1 }
        socket.push(#"{"type":"approval_required","approval":{"approval_id":"ap_1","tool":"comms.send_email","risk":"high","level":"confirm","title":"Send","summary":"s","action_digest":"ab","expires_at":"2099-01-01T00:00:00Z"}}"#)
        try await waitUntil { received.get == ["ap_1"] }
        await channel.stop()
    }

    @Test func helloUsesTheCapabilityProviderAndCanBeResent() async throws {
        let socket = FakeSocket()
        let tools = Locked<[String]>(["device.reminder.create"])
        let channel = DeviceChannel(
            baseURL: URL(string: "https://h/")!, connector: FakeConnector([.socket(socket)]), tokens: FakeTokens(),
            executor: FakeExecutor(), configuration: .init(pingInterval: nil), sleeper: InstantSleeper(),
            capabilities: { tools.get })
        #expect(await channel.refreshCapabilities() == false)  // not connected yet: nothing sent
        await channel.start()
        try await waitUntil { socket.sent.get.count == 1 }
        #expect(try decodeSent(socket.sent.get[0])["capabilities"] == ["device.reminder.create"])

        tools.withLock { $0.append("device.photos.search") }  // e.g. the owner just allowed Photos
        #expect(await channel.refreshCapabilities())
        let again = try decodeSent(socket.sent.get[1])
        #expect(again["type"] == "hello")
        #expect(again["capabilities"] == ["device.reminder.create", "device.photos.search"])
        await channel.stop()
        #expect(await channel.refreshCapabilities() == false)
    }
}

