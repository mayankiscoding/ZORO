import Foundation
import AppKit
import SwiftUI
import Testing
import ZoroCore
@testable import FitnessFeature

/// Renders each screen state off screen. This proves the views build and lay out on the macOS host; it is not a visual review.
/// Set ZORO_LIFE_SNAPSHOT_DIR to also write the PNGs.
@MainActor
func render<V: View>(_ view: V, name: String, width: CGFloat = 720, height: CGFloat = 1400, dark: Bool = false) -> Bool {
    let content = view.frame(width: width, height: height).environment(\.colorScheme, dark ? .dark : .light)
    let host = NSHostingView(rootView: content)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
    host.cacheDisplay(in: host.bounds, to: rep)
    if let dir = ProcessInfo.processInfo.environment["ZORO_LIFE_SNAPSHOT_DIR"] {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
    return rep.pixelsWide > 0
}

@Suite("Fitness screens render")
@MainActor
struct FitnessViewSmokeTests {
    @Test func loadedScreen() async throws {
        let model = makeModel(api: try serverWithData(), health: {
            let h = FakeHealth()
            h.weekly = HealthWeeklySummary(
                weekStart: fixedNow, days: (0..<7).map { HealthDailySummary(date: fixedNow.addingTimeInterval(Double($0) * 86400), steps: 4000 + $0 * 900, source: "iPhone", fetchedAt: fixedNow) },
                workouts: 3, source: "Apple Health", fetchedAt: fixedNow)
            return h
        }())
        await model.load()
        #expect(render(FitnessHomeContent(model: model, services: .unavailable), name: "fitness-loaded", height: 2600))
        #expect(render(FitnessHomeContent(model: model, services: .unavailable), name: "fitness-loaded-dark", height: 2600, dark: true))
    }

    @Test func emptyFailedAndLoadingScreens() async throws {
        let api = FakeAPI()
        try api.reply(.get, "/v1/fitness/freshness", fixture: "freshness_never")
        let empty = makeModel(api: api)
        await empty.load()
        #expect(render(FitnessHomeContent(model: empty, services: .unavailable), name: "fitness-empty", height: 700))

        let down = FakeAPI()
        down.fail(.get, "/v1/fitness/freshness", with: ZoroError.transport("offline"))
        let failed = makeModel(api: down)
        await failed.load()
        #expect(render(FitnessHomeContent(model: failed, services: .unavailable), name: "fitness-disconnected", height: 700))

        #expect(render(FitnessHomeContent(model: makeModel(api: down), services: .unavailable), name: "fitness-loading", height: 600))
    }

    @Test func partialFailureStillRenders() async throws {
        let api = try serverWithData()
        api.fail(.get, "/v1/fitness/records", with: ZoroError.http(status: 403, body: ErrorBody(code: "permission_not_granted:health.read", message: "no")))
        try api.reply(.get, "/v1/fitness/running", fixture: "running_none")
        try api.reply(.get, "/v1/fitness/summary", fixture: "summary_unavailable")
        let model = makeModel(api: api)
        await model.load()
        #expect(render(FitnessHomeContent(model: model, services: .unavailable), name: "fitness-partial", height: 2200))
    }

    @Test func planBuilder() async throws {
        let model = RunningPlanViewModel(server: FitnessAPIClient(api: try serverWithData()), timeZone: kolkata, clock: { fixedNow })
        #expect(render(RunningPlanView(model: model), name: "plan-idle", height: 900))
        await model.build()
        #expect(render(RunningPlanView(model: model), name: "plan-loaded", height: 3200))
        model.currentKmText = "abc"
        #expect(render(RunningPlanView(model: model), name: "plan-invalid", height: 3200))
    }

    @Test func cards() throws {
        for name in ["card_daily", "card_weekly", "card_records", "card_running", "card_plan", "card_stale"] {
            #expect(render(FitnessSummaryCardView(card: try Fixtures.card(name), now: fixedNow), name: "fitness-\(name)", height: 520))
        }
        #expect(render(FitnessSummaryCardView(card: UICard(kind: "music")), name: "fitness-card-bad", height: 200))
    }
}
