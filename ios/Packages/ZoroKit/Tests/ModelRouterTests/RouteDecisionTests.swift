import Testing
import ZoroCore
@testable import ModelRouter

@Suite struct RouteDecisionTests {
    static func intent(_ name: String, confidence: Double = 0.92) -> LocalIntent {
        LocalIntent(name: name, tool: LocalIntentTools.tool(for: name), confidence: confidence, language: "en")
    }

    struct Row: Sendable, CustomTestStringConvertible {
        var intent: String?
        var confidence = 0.92
        var privacy: PrivacyMode
        var reach: BackendReachability
        var target: RouteTarget
        var reason: RouteReason
        var external: Bool
        var testDescription: String { "\(intent ?? "none") \(confidence) \(privacy.rawValue) \(reach.rawValue)" }
    }

    static let rows: [Row] = [
        // device-only commands stay on the device in every mode, online or not
        Row(intent: "alarm.create", privacy: .strictPrivate, reach: .online, target: .onDevice, reason: .deviceOnlyIntent, external: false),
        Row(intent: "alarm.create", privacy: .cloudIntelligence, reach: .online, target: .onDevice, reason: .deviceOnlyIntent, external: false),
        Row(intent: "timer.start", privacy: .strictPrivate, reach: .offline, target: .onDevice, reason: .deviceOnlyIntent, external: false),
        Row(intent: "music.control", privacy: .cloudIntelligence, reach: .offline, target: .onDevice, reason: .deviceOnlyIntent, external: false),
        Row(intent: "photos.search", privacy: .cloudIntelligence, reach: .online, target: .onDevice, reason: .deviceOnlyIntent, external: false),
        Row(intent: "app.open_section", privacy: .strictPrivate, reach: .offline, target: .onDevice, reason: .deviceOnlyIntent, external: false),
        // other local commands run locally too
        Row(intent: "reminder.create", privacy: .strictPrivate, reach: .online, target: .onDevice, reason: .localIntent, external: false),
        Row(intent: "calendar.upcoming", privacy: .cloudIntelligence, reach: .offline, target: .onDevice, reason: .localIntent, external: false),
        // not understood: backend when reachable, carrying the privacy mode
        Row(intent: nil, privacy: .strictPrivate, reach: .online, target: .backend, reason: .needsBackend, external: false),
        Row(intent: nil, privacy: .cloudIntelligence, reach: .online, target: .backend, reason: .needsBackend, external: true),
        Row(intent: nil, privacy: .strictPrivate, reach: .offline, target: .unavailable, reason: .backendUnreachable, external: false),
        Row(intent: nil, privacy: .cloudIntelligence, reach: .offline, target: .unavailable, reason: .backendUnreachable, external: false),
        // recognised but a detail is missing
        Row(intent: "alarm.create", confidence: 0.5, privacy: .strictPrivate, reach: .online, target: .backend, reason: .incompleteLocalIntent, external: false),
        Row(intent: "alarm.create", confidence: 0.5, privacy: .cloudIntelligence, reach: .online, target: .backend, reason: .incompleteLocalIntent, external: true),
        Row(intent: "reminder.create", confidence: 0.5, privacy: .strictPrivate, reach: .offline, target: .unavailable, reason: .incompleteOffline, external: false),
    ]

    @Test(arguments: RouteDecisionTests.rows) func decides(_ row: Row) {
        let intent = row.intent.map { Self.intent($0, confidence: row.confidence) }
        let decision = IntentRouter.decide(intent: intent, privacyMode: row.privacy, reachability: row.reach)
        #expect(decision.target == row.target)
        #expect(decision.reason == row.reason)
        #expect(decision.allowsExternalInference == row.external)
        #expect(decision.privacyMode == row.privacy)
        #expect(decision.runsOnDevice == (row.target == .onDevice))
        #expect(decision.intent == intent)
    }

    @Test func confidenceThresholdIsInclusiveAndConfigurable() {
        let borderline = Self.intent("reminder.create", confidence: 0.75)
        #expect(IntentRouter.decide(intent: borderline, privacyMode: .strictPrivate, reachability: .online).target == .onDevice)
        let below = Self.intent("reminder.create", confidence: 0.74)
        #expect(IntentRouter.decide(intent: below, privacyMode: .strictPrivate, reachability: .online).target == .backend)
        #expect(IntentRouter.decide(intent: below, privacyMode: .strictPrivate, reachability: .online, minimumConfidence: 0.7).target == .onDevice)
    }

    @Test func strictPrivateNeverAllowsExternalInference() {
        for reach in BackendReachability.allCases {
            for name in [nil] + LocalIntentName.all.map(Optional.some) {
                let decision = IntentRouter.decide(intent: name.map { Self.intent($0) }, privacyMode: .strictPrivate, reachability: reach)
                #expect(!decision.allowsExternalInference)
            }
        }
    }

    @Test func everyLocalIntentHasADeclaredTool() {
        for name in LocalIntentName.all {
            if name == LocalIntentName.openSection {
                #expect(LocalIntentTools.tool(for: name) == nil)
            } else {
                #expect(LocalIntentTools.tool(for: name) != nil, "\(name)")
            }
        }
        #expect(LocalIntentTools.isDeviceOnly("photos.search"))
        #expect(!LocalIntentTools.isDeviceOnly("reminder.create"))
        #expect(!LocalIntentTools.isDeviceOnly("something.else"))
    }

    @Test func routeClassifiesAndDecidesInOneCall() async {
        let classifier = Fixed.classifier()
        let alarm = await IntentRouter.route("kal subah 6 baje alarm laga do", classifier: classifier, privacyMode: .strictPrivate, reachability: .offline)
        #expect(alarm.target == .onDevice)
        #expect(alarm.intent?.name == "alarm.create")
        let weather = await IntentRouter.route("what's the weather today", classifier: classifier, privacyMode: .cloudIntelligence, reachability: .online)
        #expect(weather.target == .backend)
        #expect(weather.allowsExternalInference)
        let offline = await IntentRouter.route("what's the weather today", classifier: classifier, privacyMode: .strictPrivate, reachability: .offline)
        #expect(offline.target == .unavailable)
        let partial = await IntentRouter.route("set an alarm", classifier: classifier, privacyMode: .strictPrivate, reachability: .online)
        #expect(partial.target == .backend && partial.reason == .incompleteLocalIntent)
    }

    @Test func unavailableServicesClassifierRoutesEverythingToTheBackend() async {
        let decision = await IntentRouter.route("set an alarm for 6 am", classifier: UnavailableService(), privacyMode: .strictPrivate, reachability: .online)
        #expect(decision.target == .backend)
    }
}
