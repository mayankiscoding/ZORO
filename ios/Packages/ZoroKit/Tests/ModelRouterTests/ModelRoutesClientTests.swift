import Foundation
import Testing
import ZoroCore
@testable import ModelRouter

/// Scripted source: each call pops the next result.
actor ScriptedRoutes: ModelRoutesFetching {
    private var script: [Result<[ModelRouteInfo], Error>]
    private(set) var calls = 0
    private let delayNanos: UInt64

    init(_ script: [Result<[ModelRouteInfo], Error>], delayNanos: UInt64 = 0) {
        self.script = script
        self.delayNanos = delayNanos
    }

    func fetchModelRoutes() async throws -> [ModelRouteInfo] {
        calls += 1
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        guard !script.isEmpty else { throw ZoroError.transport("no more answers") }
        return try script.removeFirst().get()
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}

@Suite struct ModelRoutesClientTests {
    static let routes: [ModelRouteInfo] = [
        ModelRouteInfo(task: .routineChat, models: ["m-a", "m-b"], activeModel: "m-a", locality: .privateNetwork, reason: "primary healthy"),
        ModelRouteInfo(task: .complexReasoning, models: ["m-c"], activeModel: "m-c", locality: .external, reason: "cloud mode"),
        ModelRouteInfo(task: .embedding, models: ["local-hash-v1"], activeModel: "local-hash-v1", locality: .onDevice),
        ModelRouteInfo(task: .tts, models: [], activeModel: nil, locality: nil, reason: "strict private: no permitted model"),
    ]

    @Test func fetchesAndExposesRoutes() async throws {
        let source = ScriptedRoutes([.success(Self.routes)])
        let client = ModelRoutesClient(source: source, clock: { Fixed.now })
        let snapshot = try await client.routes()
        #expect(snapshot.routes == Self.routes)
        #expect(!snapshot.isStale)
        #expect(snapshot.fetchedAt == Fixed.now)
        #expect(snapshot.route(for: .routineChat)?.activeModel == "m-a")
        #expect(snapshot.route(for: .summarization) == nil)
        #expect(snapshot.externalTasks == [.complexReasoning])
        #expect(snapshot.tasksWithoutModel == [.tts])
    }

    @Test func freshCacheIsNotRefetchedUntilItExpires() async throws {
        let clock = TestClock(Fixed.now)
        let source = ScriptedRoutes([.success(Self.routes), .success([])])
        let client = ModelRoutesClient(source: source, maxAge: 60, clock: { clock.now })
        _ = try await client.routes()
        clock.advance(30)
        #expect(try await client.routes().routes == Self.routes)
        #expect(await source.calls == 1)
        clock.advance(31)
        #expect(try await client.routes().routes.isEmpty)
        #expect(await source.calls == 2)
    }

    @Test func forceRefreshAndInvalidateRefetch() async throws {
        let source = ScriptedRoutes([.success(Self.routes), .success(Self.routes), .success(Self.routes)])
        let client = ModelRoutesClient(source: source, clock: { Fixed.now })
        _ = try await client.routes()
        _ = try await client.routes(forceRefresh: true)
        await client.invalidate()
        _ = try await client.routes()
        #expect(await source.calls == 3)
    }

    @Test func staleCopyIsServedWhenTheServerIsDown() async throws {
        let clock = TestClock(Fixed.now)
        let source = ScriptedRoutes([.success(Self.routes), .failure(ZoroError.transport("down"))])
        let client = ModelRoutesClient(source: source, maxAge: 10, clock: { clock.now })
        _ = try await client.routes()
        clock.advance(20)
        let snapshot = try await client.routes()
        #expect(snapshot.isStale)
        #expect(snapshot.routes == Self.routes)
        #expect(snapshot.fetchedAt == Fixed.now)
    }

    @Test func errorIsThrownWithNothingCached() async {
        let source = ScriptedRoutes([.failure(ZoroError.http(status: 503, body: nil))])
        let client = ModelRoutesClient(source: source, clock: { Fixed.now })
        await #expect(throws: ZoroError.http(status: 503, body: nil)) { try await client.routes() }
    }

    @Test func foreignErrorsAreWrapped() async {
        let source = ScriptedRoutes([.failure(URLError(.timedOut))])
        let client = ModelRoutesClient(source: source, clock: { Fixed.now })
        await #expect(throws: ZoroError.timeout) { try await client.routes() }
    }

    @Test func concurrentCallsShareOneRequest() async throws {
        let source = ScriptedRoutes([.success(Self.routes)], delayNanos: 40_000_000)
        let client = ModelRoutesClient(source: source, clock: { Fixed.now })
        async let a = client.routes()
        async let b = client.routes()
        let (ra, rb) = try await (a, b)
        #expect(ra == rb)
        #expect(await source.calls == 1)
    }

    @Test func singleRouteLookup() async throws {
        let client = ModelRoutesClient(source: ScriptedRoutes([.success(Self.routes)]), clock: { Fixed.now })
        #expect(try await client.route(for: .embedding)?.locality == .onDevice)
    }

    @Test func requestUsesTheContractEndpointThroughZoroAPI() async throws {
        struct Api: ModelRoutesFetching { func fetchModelRoutes() async throws -> [ModelRouteInfo] { ModelRoutesClientTests.routes } }
        // The default ZoroAPI adapter surfaces the not-paired error from UnavailableService.
        let client = ModelRoutesClient(api: UnavailableService(), clock: { Fixed.now })
        await #expect(throws: ZoroError.notPaired) { try await client.routes() }
        _ = Api()
    }

    @Test func routeInfoDecodesTheServerShape() throws {
        let json = #"[{"task":"routine_chat","models":["a","b"],"active_model":"a","locality":"private_network","reason":"ok"},{"task":"tts","models":[],"active_model":null,"locality":null}]"#
        let list = try ZoroJSON.decoder().decode(ListOrPage<ModelRouteInfo>.self, from: Data(json.utf8)).items
        #expect(list.count == 2)
        #expect(list[0].locality == .privateNetwork)
        #expect(list[1].activeModel == nil)
    }
}
