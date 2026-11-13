import Foundation
import Observation
import ZoroCore

/// Main-actor state for the Live Voice screen and the orb. Business logic stays in `VoiceSession`;
/// this only folds its events into displayable state.
@MainActor
@Observable
public final class VoiceSessionViewModel {
    public private(set) var phase: VoicePhase = .idle
    public private(set) var level: Float = 0
    public private(set) var partialTranscript = ""
    public private(set) var lastUtterance: String?
    public private(set) var utteranceLanguage: SpokenLanguage?
    public private(set) var replyText = ""
    public private(set) var engine: VoiceEngineKind?
    public private(set) var fallbackReason: EngineFallbackReason?
    public private(set) var listeningLocale: String?
    public private(set) var error: VoiceError?
    public private(set) var lastLatency: TurnLatency?
    public private(set) var cards: [UICard] = []

    @ObservationIgnored private let session: VoiceSession
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    public init(session: VoiceSession) {
        self.session = session
    }

    /// Starts observing the session; call once from the view's `.task`.
    public func observe() {
        guard tasks.isEmpty else { return }
        let events = session.events()
        let levels = session.levelUpdates()
        tasks.append(Task { [weak self] in
            for await event in events { self?.apply(event) }
        })
        tasks.append(Task { [weak self] in
            for await value in levels { self?.level = value }
        })
    }

    public func stopObserving() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    public var isActive: Bool { !phase.isResting }

    /// Orb tap: start when resting, stop speech when busy, end the session when listening.
    public func orbTapped(_ options: VoiceSessionOptions) async {
        switch phase {
        case .idle, .privateOffline, .error:
            do {
                try await session.start(options)
            } catch let e as VoiceError {
                error = e
            } catch {
                self.error = VoiceError.from(error)
            }
        case .processing, .delegating, .toolExecution, .speaking:
            await session.interrupt()
        case .listening:
            await session.stop()
        }
    }

    public func stop() async { await session.stop() }
    public func finishSpeaking() async { await session.finishListening() }

    func apply(_ event: VoiceSessionEvent) {
        switch event {
        case .phase(let p):
            phase = p
            if p == .listening { partialTranscript = "" }
            if p.isResting { level = 0 }
        case .engine(let kind, let reason):
            engine = kind
            fallbackReason = reason
        case .listeningLocale(let locale):
            listeningLocale = locale
        case .partialTranscript(let text):
            partialTranscript = text
            error = nil
        case .finalTranscript(let text, let language):
            lastUtterance = text
            utteranceLanguage = language
            partialTranscript = ""
            replyText = ""
            cards = []
        case .replyText(let delta):
            replyText += delta
        case .turn(.card(let card)):
            cards.append(card.card)
        case .turn:
            break
        case .latency(let sample):
            lastLatency = sample
        case .error(let e):
            error = e
        }
    }
}
