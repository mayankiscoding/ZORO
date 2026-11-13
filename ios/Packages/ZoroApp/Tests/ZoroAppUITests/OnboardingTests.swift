import Foundation
import Testing
import ZoroCore
@testable import ZoroAppUI

final class FakePairing: ServerPairing, @unchecked Sendable {
    var keysError: ZoroError?
    var pairResult: Result<PairResponse, ZoroError> = .success(PairResponse(deviceId: "dev_1", serverName: "Home Mac", serverTime: Date(timeIntervalSince1970: 0)))
    let keyCalls = Recorder<Int>()
    let pairs = Recorder<String>()

    func createKeys() async throws {
        keyCalls.append(1)
        if let keysError { throw keysError }
    }

    func pair(serverURL: URL, code: String) async throws -> PairResponse {
        pairs.append("\(serverURL.absoluteString)|\(code)")
        return try pairResult.get()
    }
}

final class MemoryPreferences: PreferencesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value = AppPreferences()
    func load() -> AppPreferences { lock.withLock { value } }
    func save(_ preferences: AppPreferences) { lock.withLock { value = preferences } }
}

@Suite("First run")
@MainActor
struct OnboardingTests {
    func model(_ pairing: FakePairing = FakePairing(), prefs: MemoryPreferences = MemoryPreferences(), guide: Bool = true) -> OnboardingModel {
        OnboardingModel(pairing: pairing, preferences: prefs, showsShortcutGuide: guide)
    }

    @Test func happyPath() async {
        let pairing = FakePairing()
        let prefs = MemoryPreferences()
        let m = model(pairing, prefs: prefs)
        #expect(m.step == .welcome)
        m.begin()
        #expect(m.step == .connect)
        m.serverAddress = "zoro.tailnet.ts.net"
        m.pairingCode = "abcd-1234"
        await m.connect()
        #expect(pairing.keyCalls.all.count == 1)
        #expect(pairing.pairs.all == ["https://zoro.tailnet.ts.net|ABCD1234"])
        #expect(m.step == .language)
        #expect(m.serverName == "Home Mac")
        #expect(m.pairingCode.isEmpty)
        m.chooseLanguage(.hindi)
        #expect(m.step == .voice)
        m.chooseVoice(.masculine)
        #expect(m.step == .shortcuts)
        #expect(!prefs.load().onboardingComplete)
        m.finishShortcuts()
        #expect(m.step == .done)
        let saved = prefs.load()
        #expect(saved.onboardingComplete && saved.language == .hindi && saved.voice == .masculine)
        #expect(saved.serverURL?.absoluteString == "https://zoro.tailnet.ts.net")
    }

    @Test func macSkipsTheActionButtonGuide() async {
        let prefs = MemoryPreferences()
        let m = model(prefs: prefs, guide: false)
        m.begin()
        m.serverAddress = "http://192.168.1.5:8000"
        m.pairingCode = "ABCD1234"
        await m.connect()
        m.chooseLanguage(.english)
        m.chooseVoice(.feminine)
        #expect(m.step == .done)
        #expect(prefs.load().onboardingComplete)
    }

    @Test func formValidation() async {
        let pairing = FakePairing()
        let m = model(pairing)
        m.begin()
        m.serverAddress = "  "
        m.pairingCode = "ABCD1234"
        await m.connect()
        #expect(m.problem == .invalidAddress)
        m.serverAddress = "zoro.local"
        m.pairingCode = " -- "
        await m.connect()
        #expect(m.problem == .missingCode)
        #expect(m.step == .connect)
        #expect(pairing.keyCalls.all.isEmpty)
    }

    @Test func wrongCode() async {
        let pairing = FakePairing()
        pairing.pairResult = .failure(.http(status: 400, body: ErrorBody(code: "pairing_code_invalid", message: "The pairing code is wrong")))
        let m = model(pairing)
        m.begin()
        m.serverAddress = "zoro.local"
        m.pairingCode = "WRONG123"
        await m.connect()
        #expect(m.step == .connect)
        #expect(m.problem == .wrongCode)
        #expect(m.problem?.message.contains("python -m app.cli pairing-code") == true)
        #expect(m.pairingCode == "WRONG123")
        // Fixing the code and trying again works.
        pairing.pairResult = .success(PairResponse(deviceId: "d", serverName: "S", serverTime: Date()))
        await m.connect()
        #expect(m.step == .language)
        #expect(m.problem == nil)
    }

    @Test func unreachableServer() async {
        let pairing = FakePairing()
        pairing.pairResult = .failure(.transport("Could not connect to the server."))
        let m = model(pairing)
        m.begin()
        m.serverAddress = "zoro.tailnet.ts.net"
        m.pairingCode = "ABCD1234"
        await m.connect()
        #expect(m.step == .connect)
        #expect(m.problem == .unreachable(host: "zoro.tailnet.ts.net"))
        #expect(m.problem?.message == "Can't reach a ZORO server at zoro.tailnet.ts.net. Check the address, and that your Mac is awake and on Tailscale.")
    }

    @Test(arguments: [
        (ZoroError.timeout, ConnectProblem.unreachable(host: "h.local")),
        (.http(status: 429, body: nil), .rateLimited),
        (.http(status: 404, body: nil), .notAZoroServer(host: "h.local")),
        (.decoding("bad"), .notAZoroServer(host: "h.local")),
        (.http(status: 502, body: nil), .unreachable(host: "h.local")),
        (.signingFailed("no key"), .keys("no key")),
    ])
    func errorMapping(error: ZoroError, problem: ConnectProblem) {
        #expect(ConnectProblem.from(error, host: "h.local") == problem)
    }

    @Test func keyCreationFailureStopsBeforePairing() async {
        let pairing = FakePairing()
        pairing.keysError = .keyUnavailable("Secure Enclave unavailable")
        let m = model(pairing)
        m.begin()
        m.serverAddress = "zoro.local"
        m.pairingCode = "ABCD1234"
        await m.connect()
        #expect(m.step == .connect)
        #expect(pairing.pairs.all.isEmpty)
        if case .keys = m.problem {} else { Issue.record("expected a key problem, got \(String(describing: m.problem))") }
    }

    @Test func pairLinkFillsAndConnects() async {
        let pairing = FakePairing()
        let m = model(pairing)
        await m.apply(PairingLink(serverURL: URL(string: "https://zoro.local:8443")!, code: "ABCD1234"))
        #expect(pairing.pairs.all == ["https://zoro.local:8443|ABCD1234"])
        #expect(m.step == .language)
        // A second link after pairing is ignored.
        await m.apply(PairingLink(serverURL: URL(string: "https://other")!, code: "ZZZZ9999"))
        #expect(pairing.pairs.all.count == 1)
    }

    @Test func backNavigation() {
        let m = model()
        m.begin()
        m.back()
        #expect(m.step == .welcome)
        m.chooseLanguage(.hindi)
        #expect(m.step == .welcome)
    }

    @Test func setupCodePayload() {
        if case .success(let link) = SetupCodePayload.parse(" zoro://pair?server=zoro.local&code=abcd1234 \n") {
            #expect(link.code == "ABCD1234")
        } else {
            Issue.record("expected a pairing link")
        }
        if case .failure(let e) = SetupCodePayload.parse("zoro://voice") {
            #expect(e == .invalidPairing("This QR code isn't a ZORO setup code."))
        } else {
            Issue.record("expected failure")
        }
        if case .success = SetupCodePayload.parse("https://example.com") { Issue.record("must reject web links") }
    }

    @Test func preferencesRoundTripInUserDefaults() throws {
        let suite = "zoro.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPreferences(defaults: defaults)
        #expect(store.load() == AppPreferences())
        store.save(AppPreferences(language: .hinglish, voice: .masculine, serverURL: URL(string: "https://z.local"), onboardingComplete: true))
        #expect(store.load().language == .hinglish)
        defaults.set(Data("junk".utf8), forKey: "zoro.preferences")
        #expect(store.load() == AppPreferences())
    }
}
