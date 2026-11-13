import Foundation
import Testing
import ZoroCore
@testable import SystemFeatures

func dec(_ s: String) -> Decimal { Decimal(string: s)! }

func costRow(_ key: String, _ cost: String, requests: Int = 1, input: Int = 10, output: Int = 5) -> CostRow {
    CostRow(key: key, requests: requests, inputTokens: input, outputTokens: output, avgLatencyMs: 100, errorRate: 0, costUsd: dec(cost))
}

@Suite("Cost aggregation")
struct CostAggregationTests {
    @Test func sumsAreExactDecimalNotFloating() {
        // 0.1 + 0.2 == 0.3 exactly in Decimal.
        let summary = CostSummary(groupBy: .model, totalCostUsd: dec("0.3"), items: [costRow("a", "0.1"), costRow("b", "0.2")])
        let breakdown = CostAggregation.breakdown(summary)
        #expect(breakdown.computedTotal == dec("0.3"))
        #expect(breakdown.totalsMatch)
        #expect(breakdown.requests == 2)
        #expect(breakdown.inputTokens == 20)
        #expect(breakdown.outputTokens == 10)
    }

    @Test func linesAreSortedByCostAndSharesAreDecimalFractions() {
        let summary = CostSummary(groupBy: .provider, totalCostUsd: dec("4"), items: [costRow("small", "1"), costRow("big", "3")])
        let lines = CostAggregation.breakdown(summary).lines
        #expect(lines.map(\.id) == ["big", "small"])
        #expect(lines.map(\.share) == [dec("0.75"), dec("0.25")])
    }

    @Test func tailBeyondTheLimitIsCombinedIntoOtherWithExactSums() {
        let items = (1...5).map { costRow("m\($0)", "0.0\($0)", requests: $0) }
        let summary = CostSummary(groupBy: .model, totalCostUsd: dec("0.15"), items: items)
        let breakdown = CostAggregation.breakdown(summary, limit: 3)
        #expect(breakdown.lines.count == 4)
        let other = breakdown.lines.last!
        #expect(other.isOther)
        #expect(other.label == "Other (2)")
        #expect(other.cost == dec("0.03"))  // m2 + m1 = 0.02 + 0.01
        #expect(other.requests == 3)
        #expect(breakdown.lines.reduce(Decimal(0)) { $0 + $1.cost } == dec("0.15"))
        #expect(breakdown.lines.reduce(Decimal(0)) { $0 + $1.share } == dec("1"))
    }

    @Test func mismatchedTotalsAreReportedNotHidden() {
        let summary = CostSummary(groupBy: .model, totalCostUsd: dec("5"), items: [costRow("a", "1")])
        let breakdown = CostAggregation.breakdown(summary)
        #expect(!breakdown.totalsMatch)
        #expect(breakdown.lines[0].share == dec("0.2"), "shares use the reported total")
    }

    @Test func zeroTotalGivesZeroShares() {
        let summary = CostSummary(groupBy: .task, totalCostUsd: 0, items: [costRow("chat", "0")])
        #expect(CostAggregation.breakdown(summary).lines[0].share == 0)
        #expect(CostAggregation.share(1, of: 0) == 0)
    }

    @Test func dayGroupingKeepsChronologicalOrderAndBuildsATrend() {
        let summary = CostSummary(groupBy: .day, totalCostUsd: dec("0.6"), items: [costRow("2026-11-12", "0.3"), costRow("2026-11-10", "0.1"), costRow("2026-11-11", "0.2"), costRow("garbage", "0")])
        let breakdown = CostAggregation.breakdown(summary)
        #expect(breakdown.lines.map(\.id) == ["2026-11-10", "2026-11-11", "2026-11-12", "garbage"].sorted())
        #expect(breakdown.lines.first { $0.id == "2026-11-10" }?.label == "10 Nov")
        let trend = CostAggregation.dailyTrend(summary)
        #expect(trend.map(\.cost) == [dec("0.1"), dec("0.2"), dec("0.3")])
        #expect(trend.count == 3, "a key that isn't a date stays out of the trend")
    }

    @Test func taskLabelsAreSentenceCase() {
        #expect(CostAggregation.label(for: "routine_chat", groupBy: .task) == "Routine chat")
        #expect(CostAggregation.label(for: "gemini-x", groupBy: .model) == "gemini-x")
    }
}

func costFixture(_ group: CostGroupBy, total: String = "1", items: [CostRow]? = nil) -> CostSummary {
    CostSummary(groupBy: group, totalCostUsd: dec(total), items: items ?? [costRow("x", total)])
}

@MainActor
@Suite("Cost view model")
struct CostViewModelTests {
    @Test func loadsAllFourGroupings() async {
        let api = FakeAPI()
        api.costHandler = { group in costFixture(group, items: group == .day ? [costRow("2026-11-10", "1")] : nil) }
        let vm = CostViewModel(api: api)
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(Set(vm.breakdowns.keys) == Set(CostViewModel.groups))
        #expect(Set(api.calls.get) == Set(CostViewModel.groups.map { "costSummary:\($0.rawValue)" }))
        #expect(vm.totalCost == dec("1"))
        #expect(vm.trend.count == 1)
        #expect(vm.current?.groupBy == .model)
    }

    @Test func noSpendIsEmpty() async {
        let api = FakeAPI()
        api.costHandler = { group in CostSummary(groupBy: group, totalCostUsd: 0, items: []) }
        let vm = CostViewModel(api: api)
        await vm.load()
        #expect(vm.phase == .empty)
        #expect(vm.emptyMessage.contains("No model costs yet"))
    }

    @Test func partialFailureStillShowsWhatLoaded() async {
        let api = FakeAPI()
        api.costHandler = { group in
            if group == .task { throw ZoroError.timeout }
            return costFixture(group)
        }
        let vm = CostViewModel(api: api)
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(vm.failedGroups == [.task])
        #expect(vm.partialNote == "Couldn't load costs by task. Reload to try again.")
    }

    @Test func allFailingIsDisconnectedOrFailed() async {
        let api = FakeAPI()
        api.costHandler = { _ in throw ZoroError.transport("x") }
        let vm = CostViewModel(api: api)
        await vm.load()
        #expect(vm.phase.isDisconnected)
        api.costHandler = { _ in throw ZoroError.http(status: 500, body: nil) }
        await vm.load()
        #expect(vm.phase.failure != nil && !vm.phase.isDisconnected)
    }
}

@MainActor
@Suite("Settings view model")
struct SettingsTests {
    func make(identity: FakeIdentity = FakeIdentity(), prefs: InMemoryPreferences = InMemoryPreferences()) -> (SettingsViewModel, FakeAPI, FakeIdentity) {
        let api = FakeAPI()
        api.securityStateHandler = { securityState() }
        api.on("GET /v1/voice/config") { _ in
            VoiceConfig(settings: VoiceSettings(), engines: [VoiceEngineStatus(id: "on_device", available: true)], voices: [VoiceOption(id: "v1", name: "Asha", engine: "on_device", gender: "female", languages: ["en"])])
        }
        api.on("PUT /v1/voice/settings") { req in try ZoroJSON.decoder().decode(VoiceSettings.self, from: req.body ?? Data()) }
        api.routesHandler = { [ModelRouteInfo(task: .routineChat, models: ["local-a"], activeModel: "local-a", locality: .local)] }
        let vm = SettingsViewModel(api: api, identity: identity, address: StaticServerAddress("zoro.tailnet.ts.net"), preferences: prefs)
        return (vm, api, identity)
    }

    @Test func connectedLoadFillsEverySection() async {
        let (vm, _, _) = make()
        await vm.load()
        #expect(vm.connection == .connected(sessionExpiresAt: t0.addingTimeInterval(900)))
        #expect(vm.serverAddress == "zoro.tailnet.ts.net")
        #expect(vm.voicePhase == .loaded)
        #expect(vm.voices.map(\.id) == ["v1"])
        #expect(vm.routesPhase == .loaded)
        #expect(vm.routes.count == 1)
    }

    @Test func notPairedSaysSoAndLeavesOtherSectionsDisconnected() async {
        let identity = FakeIdentity()
        identity.id = nil
        let (vm, api, _) = make(identity: identity)
        await vm.load()
        #expect(vm.connection == .notPaired)
        #expect(vm.connection.detail.contains("pairing code"))
        #expect(vm.voicePhase.isDisconnected)
        #expect(vm.routesPhase.isDisconnected)
        #expect(api.calls.get.isEmpty)
    }

    @Test func unreachableAndRemovedServersAreTold() async {
        let (vm, api, _) = make()
        api.securityStateHandler = { throw ZoroError.transport("x") }
        await vm.load()
        #expect(vm.connection == .unreachable)
        #expect(vm.voicePhase.failure?.message == SystemCopy.unreachable)
        api.securityStateHandler = { throw ZoroError.unauthorized }
        await vm.refreshConnection()
        #expect(vm.connection == .deviceRemoved)
    }

    @Test func emptyRoutesIsEmpty() async {
        let (vm, api, _) = make()
        api.routesHandler = { [] }
        await vm.load()
        #expect(vm.routesPhase == .empty)
        #expect(vm.routesEmptyMessage.contains("models.yaml"))
    }

    @Test func voiceLoadErrorIsFailedWhileRoutesStillLoad() async {
        let (vm, api, _) = make()
        api.on("GET /v1/voice/config") { _ in throw ZoroError.http(status: 500, body: nil) }
        await vm.load()
        #expect(vm.voicePhase.failure != nil)
        #expect(vm.routesPhase == .loaded)
    }

    @Test func languageAndResponseLengthAreSavedWithTheWholeSettingsObject() async {
        let (vm, api, _) = make()
        await vm.load()
        await vm.setLanguage(.hinglish)
        await vm.setResponseLength(.detailed)
        #expect(vm.voice.language == .hinglish)
        #expect(vm.voice.responseLength == .detailed)
        let bodies = api.sent(.put, "/v1/voice/settings").compactMap { $0.body }.compactMap { String(data: $0, encoding: .utf8) }
        #expect(bodies.count == 2)
        #expect(bodies[1].contains("\"language\":\"hinglish\""))
        #expect(bodies[1].contains("\"response_length\":\"detailed\""))
    }

    @Test func failedSaveGoesBackToTheOldValue() async {
        let (vm, api, _) = make()
        api.on("PUT /v1/voice/settings") { _ in throw ZoroError.http(status: 500, body: nil) }
        await vm.load()
        await vm.setLanguage(.hi)
        #expect(vm.voice.language == .auto)
        #expect(vm.notice?.text.hasPrefix("Changing the language didn't happen.") == true)
    }

    @Test func speakingRateIsClamped() async {
        let (vm, api, _) = make()
        await vm.load()
        await vm.setSpeakingRate(5)
        #expect(vm.voice.speakingRate == 2.0)
        await vm.setSpeakingRate(0.1)
        #expect(vm.voice.speakingRate == 0.5)
        #expect(api.sent(.put, "/v1/voice/settings").count == 2)
    }

    @Test func changingBeforeVoiceSettingsLoadIsRefused() async {
        let (vm, api, _) = make()
        await vm.setLanguage(.hi)
        #expect(api.sent(.put, "/v1/voice/settings").isEmpty)
        #expect(vm.notice?.kind == .failure)
    }

    @Test func appearanceIsRememberedOnThisDevice() {
        let prefs = InMemoryPreferences()
        let (vm, _, _) = make(prefs: prefs)
        #expect(vm.appearance == .system)
        vm.setAppearance(.dark)
        #expect(prefs.string(forKey: "appearance") == "dark")
        let (again, _, _) = make(prefs: prefs)
        #expect(again.appearance == .dark)
        again.setAppearance(.system)
        #expect(prefs.string(forKey: "appearance") == nil)
    }

    @Test func unpairNeedsConfirmationAndEndsNotPaired() async {
        let (vm, _, identity) = make()
        await vm.load()
        await vm.confirmUnpair()
        #expect(identity.unpaired.get == 0)
        vm.requestUnpair()
        await vm.confirmUnpair()
        #expect(identity.unpaired.get == 1)
        #expect(vm.connection == .notPaired)
        #expect(vm.notice == .success("This device is disconnected."))
    }

    @Test func unpairFailureKeepsConnection() async {
        let identity = FakeIdentity()
        identity.unpairError = ZoroError.storage("locked")
        let (vm, _, _) = make(identity: identity)
        await vm.load()
        vm.requestUnpair()
        await vm.confirmUnpair()
        #expect(vm.connection.isConnected)
        #expect(vm.notice?.kind == .failure)
    }
}
