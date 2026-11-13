import Foundation
import ZoroCore

/// One request Siri, Shortcuts, Spotlight or the Action Button hands to ZORO.
public struct IntentTurnRequest: Sendable, Equatable {
    /// The words of the turn, already in the owner's language.
    public var text: String
    /// Sent as the turn's language hint ("en", "hi", "hinglish").
    public var language: ZoroLanguage
    /// Only ever stricter than the server setting (the server enforces that too).
    public var privacyMode: PrivacyMode?

    public init(text: String, language: ZoroLanguage, privacyMode: PrivacyMode? = nil) {
        self.text = text
        self.language = language
        self.privacyMode = privacyMode
    }
}

/// A finished answer.
public struct IntentReply: Sendable, Equatable {
    public var text: String
    public var cards: [UICard]
    /// `TurnCompleted.language` ("en", "hi", "hinglish" …); nil when the server did not say.
    public var language: String?
    public var dataClasses: [DataClass]
    public var conversationId: String?
    public var turnId: String?

    public init(
        text: String, cards: [UICard] = [], language: String? = nil, dataClasses: [DataClass] = [],
        conversationId: String? = nil, turnId: String? = nil
    ) {
        self.text = text
        self.cards = cards
        self.language = language
        self.dataClasses = dataClasses
        self.conversationId = conversationId
        self.turnId = turnId
    }
}

/// Why a turn cannot finish from Siri.
public enum IntentSuspension: String, Sendable, Equatable, CaseIterable {
    /// The turn waits for a signed approval. Approvals are given only in the app, never from Siri.
    case approval
    /// The turn waits for an action on a device (alarm, message composer, Home scene, playback …).
    case deviceAction
}

/// Why a turn failed. Each case has one sentence in `IntentCopy`.
public enum IntentTurnFailure: Sendable, Equatable {
    case timeout
    case offline
    case notPaired
    case unauthorized
    /// The server's kill switch is on.
    case paused
    case cancelled
    /// The turn completed without any words or cards.
    case empty
    /// The intents were run before the app registered their dependencies (`ZoroIntents.register`).
    case notConfigured
    case server(code: String, message: String, retryable: Bool)
}

public enum IntentTurnOutcome: Sendable, Equatable {
    case answer(IntentReply)
    /// The server suspended the turn. The runner has already cancelled it on the server, so nothing waits
    /// in the background; the app asks again in the foreground, where approvals and device actions run.
    case suspended(IntentSuspension, partial: IntentReply)
    case failed(IntentTurnFailure)
}

/// Runs one backend turn for an App Intent: bounded in time, cancellable, never approving anything.
public protocol IntentTurnRunning: Sendable {
    func run(_ request: IntentTurnRequest) async -> IntentTurnOutcome
}

/// The `ZoroAPI`-backed runner the app registers.
public struct ZoroIntentTurnRunner: IntentTurnRunning {
    /// Siri waits only a short while for an answer; past this the turn is stopped on the server.
    public static let defaultTimeout: Duration = .seconds(20)

    private let api: any ZoroAPI
    private let client: ClientContext
    private let timeout: Duration

    /// `client` is the app's client context; the runner marks the turn as coming from Siri in `app_state`.
    public init(api: any ZoroAPI, client: ClientContext, timeout: Duration = ZoroIntentTurnRunner.defaultTimeout) {
        self.api = api
        var client = client
        client.appState["surface"] = "siri"
        self.client = client
        self.timeout = timeout
    }

    /// The request sent to the server (exposed for tests).
    public func turnRequest(for request: IntentTurnRequest) -> TurnRequest {
        let text = String(request.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AskLimits.maxPhraseLength))
        return TurnRequest(
            conversationId: nil,
            input: TurnInput(text: text, modality: .voice, languageHint: request.language.rawValue),
            client: client, privacyMode: request.privacyMode)
    }

    public func run(_ request: IntentTurnRequest) async -> IntentTurnOutcome {
        let turnRequest = turnRequest(for: request)
        guard !turnRequest.input.text.isEmpty else { return .failed(.empty) }
        let progress = TurnProgress()
        let api = self.api
        let timeout = self.timeout

        let outcome: IntentTurnOutcome = await withTaskGroup(of: IntentTurnOutcome?.self) { group in
            group.addTask { await Self.consume(api.startTurn(turnRequest), into: progress) }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .failed(.timeout)
                } catch {
                    return nil
                }
            }
            var first: IntentTurnOutcome?
            for await result in group {
                if let result {
                    first = result
                    break
                }
            }
            group.cancelAll()
            return first ?? .failed(.cancelled)
        }

        let final: IntentTurnOutcome = Task.isCancelled ? .failed(.cancelled) : outcome
        switch final {
        case .suspended, .failed(.timeout):
            // Nothing may keep waiting on the server after Siri has moved on.
            if let turnId = progress.turnId { try? await api.cancelTurn(id: turnId) }
        case .failed(.cancelled):
            if let turnId = progress.turnId {
                // The caller's task is cancelled, so the request runs in its own task.
                Task { try? await api.cancelTurn(id: turnId) }
            }
        default:
            break
        }
        return final
    }

    static func consume(_ stream: AsyncThrowingStream<TurnEvent, Error>, into progress: TurnProgress) async -> IntentTurnOutcome {
        do {
            for try await event in stream {
                switch event {
                case .turnStarted(let started):
                    progress.started(turnId: started.turnId, conversationId: started.conversationId)
                case .textDelta(let delta):
                    progress.append(text: delta.text)
                case .card(let card):
                    progress.append(card: card.card)
                case .turnSuspended(let suspended):
                    progress.started(turnId: suspended.turnId, conversationId: nil)
                    let reason: IntentSuspension = suspended.reason == .approval ? .approval : .deviceAction
                    return .suspended(reason, partial: progress.reply(language: nil, dataClasses: []))
                case .turnCompleted(let done):
                    progress.started(turnId: done.turnId, conversationId: nil)
                    let reply = progress.reply(language: done.language, dataClasses: done.dataClasses)
                    let empty = reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && reply.cards.isEmpty
                    return empty ? .failed(.empty) : .answer(reply)
                case .error(let error):
                    return .failed(failure(code: error.code, message: error.message, retryable: error.retryable))
                default:
                    continue
                }
            }
            if Task.isCancelled { return .failed(.cancelled) }
            return .failed(.server(code: "incomplete", message: "The server ended the answer early.", retryable: true))
        } catch {
            if Task.isCancelled { return .failed(.cancelled) }
            return .failed(failure(for: error))
        }
    }

    /// Maps a thrown error to the failure Siri explains.
    public static func failure(for error: Error) -> IntentTurnFailure {
        switch ZoroError.wrap(error) {
        case .transport: .offline
        case .timeout: .timeout
        case .notPaired, .keyUnavailable: .notPaired
        case .unauthorized: .unauthorized
        case .cancelled, .userCancelled: .cancelled
        case .turnFailed(let e): failure(code: e.code, message: e.message, retryable: e.retryable)
        case .http(let status, let body):
            if let body { failure(code: body.code, message: body.message, retryable: body.retryable) }
            else if status == 401 { .unauthorized }
            else { .server(code: "http_\(status)", message: "The server answered \(status).", retryable: status >= 500) }
        case let other: .server(code: "client", message: other.errorDescription ?? "Unexpected error.", retryable: other.isRetryable)
        }
    }

    static func failure(code: String, message: String, retryable: Bool) -> IntentTurnFailure {
        switch code {
        case "kill_switch_active": .paused
        case "unauthorized", "device_revoked", "invalid_token": .unauthorized
        default: .server(code: code, message: message, retryable: retryable)
        }
    }
}

/// What the stream delivered so far; written by the consuming task, read after it ends or times out.
final class TurnProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _turnId: String?
    private var conversationId: String?
    private var text = ""
    private var cards: [UICard] = []

    var turnId: String? { lock.withLock { _turnId } }

    func started(turnId: String, conversationId: String?) {
        lock.withLock {
            if _turnId == nil { _turnId = turnId }
            if let conversationId { self.conversationId = conversationId }
        }
    }

    func append(text delta: String) { lock.withLock { text += delta } }
    func append(card: UICard) { lock.withLock { cards.append(card) } }

    func reply(language: String?, dataClasses: [DataClass]) -> IntentReply {
        lock.withLock {
            IntentReply(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines), cards: cards, language: language,
                dataClasses: dataClasses, conversationId: conversationId, turnId: _turnId)
        }
    }
}
