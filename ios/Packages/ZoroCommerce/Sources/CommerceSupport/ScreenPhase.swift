import Foundation
import ZoroCore

/// Why a screen could not show its content: no server (`disconnected`) or the server said no (`error`).
public struct ScreenFailure: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case error, disconnected }
    public var kind: Kind
    /// One sentence: what happened and what to do next.
    public var message: String
    public var retryable: Bool

    public init(kind: Kind, message: String, retryable: Bool = true) {
        self.kind = kind
        self.message = message
        self.retryable = retryable
    }

    /// Maps any error to a plain sentence. `subject` names the thing that failed ("your basket").
    public static func from(_ error: Error, subject: String) -> ScreenFailure {
        guard let zoro = error as? ZoroError else {
            return ScreenFailure(kind: .error, message: "Could not load \(subject). Try again.")
        }
        switch zoro {
        case .notPaired:
            return ScreenFailure(kind: .disconnected,
                                 message: "This device is not connected to your ZORO server. Pair it in Settings, then try again.")
        case .unauthorized:
            return ScreenFailure(kind: .disconnected,
                                 message: "Your ZORO server did not accept this device. Pair it again in Settings.")
        case .transport, .timeout:
            return ScreenFailure(kind: .disconnected,
                                 message: "Could not reach your ZORO server. Check that it is running and you are on your network, then try again.")
        case .http(let status, let body):
            if let body, body.code.hasPrefix("permission_not_granted:") {
                let key = String(body.code.dropFirst("permission_not_granted:".count))
                return ScreenFailure(kind: .error,
                                     message: "Allow \(key) in Security and privacy, then try again.", retryable: true)
            }
            if let body {
                let sentence = body.message.hasSuffix(".") ? body.message : body.message + "."
                return ScreenFailure(kind: .error, message: "\(sentence) Try again in a moment.", retryable: body.retryable || status >= 500)
            }
            return ScreenFailure(kind: .error, message: "The server could not load \(subject). Try again in a moment.")
        case .decoding:
            return ScreenFailure(kind: .error,
                                 message: "The server sent \(subject) in a form this app does not understand. Update the app, then try again.",
                                 retryable: false)
        case .unavailable(let capability, let reason):
            return ScreenFailure(kind: .error, message: "\(capability) is not available: \(reason).", retryable: false)
        case .cancelled, .userCancelled:
            return ScreenFailure(kind: .error, message: "Cancelled. Try again when you are ready.")
        default:
            return ScreenFailure(kind: .error, message: zoro.errorDescription ?? "Could not load \(subject). Try again.")
        }
    }
}

/// The life of a screen's main content.
public enum ScreenPhase: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case empty
    case failed(ScreenFailure)

    public var failure: ScreenFailure? {
        if case .failed(let f) = self { f } else { nil }
    }

    public var isLoading: Bool { self == .loading }
}
