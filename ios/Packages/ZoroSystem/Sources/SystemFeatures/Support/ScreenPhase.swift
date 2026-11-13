import Foundation
import ZoroCore

/// What a screen shows. Every screen in this package is in exactly one of these phases, and every
/// non-loaded phase carries one sentence that says what to do next.
public enum ScreenPhase: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case empty
    /// The server answered with a problem (or something else went wrong). Retry may help.
    case failed(ScreenFailure)
    /// This device can't talk to the server (not paired, session refused, server unreachable).
    case disconnected(ScreenFailure)

    public var isLoading: Bool { self == .loading }
    public var failure: ScreenFailure? {
        switch self {
        case .failed(let f), .disconnected(let f): f
        default: nil
        }
    }
    public var isDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }
}

public struct ScreenFailure: Equatable, Sendable {
    /// One sentence: what happened and what to do.
    public var message: String
    public var retryable: Bool
    public init(message: String, retryable: Bool = true) {
        self.message = message
        self.retryable = retryable
    }
}

/// Turns errors into screen phases and notices with plain sentences (see docs/design/voice-and-copy.md).
public enum SystemFailure {
    /// nil means the error is a cancellation and the screen should stay as it is.
    public static func phase(for error: Error) -> ScreenPhase? {
        let z = ZoroError.wrap(error)
        switch z {
        case .cancelled, .userCancelled:
            return nil
        case .notPaired:
            return .disconnected(ScreenFailure(message: SystemCopy.notPaired, retryable: false))
        case .unauthorized:
            return .disconnected(ScreenFailure(message: SystemCopy.deviceRemoved, retryable: false))
        case .transport, .timeout:
            return .disconnected(ScreenFailure(message: SystemCopy.unreachable))
        default:
            return .failed(ScreenFailure(message: plainMessage(for: z), retryable: z.isRetryable || isGenericRetryable(z)))
        }
    }

    /// A sentence for a failed action (a notice, not a whole-screen state). nil for cancellations.
    public static func message(for error: Error) -> String? {
        let z = ZoroError.wrap(error)
        if z == .cancelled || z == .userCancelled { return nil }
        return plainMessage(for: z)
    }

    static func plainMessage(for z: ZoroError) -> String {
        switch z {
        case .notPaired: return SystemCopy.notPaired
        case .unauthorized: return SystemCopy.deviceRemoved
        case .transport, .timeout: return SystemCopy.unreachable
        case .http(_, let body):
            if body?.code == "kill_switch_active" { return SystemCopy.killSwitchOn }
            if let body, !body.message.isEmpty { return sentence(body.message) }
            return "The server couldn't finish that. Try again in a moment."
        case .decoding, .invalidResponse:
            return "The server sent something this app doesn't understand. Update the app or the server, then try again."
        case .unavailable(let capability, let reason):
            return "\(capability) isn't available: \(reason). Check Integrations for what it needs."
        case .biometryUnavailable:
            return "Face ID or Touch ID isn't available. Set up a passcode on this device, then try again."
        case .authenticationFailed:
            return "Face ID didn't match. Try again or use your passcode."
        case .signingFailed, .keyUnavailable:
            return "This device couldn't sign that change, so nothing was changed. Try again."
        case .busy:
            return "ZORO is still working on the last request. Try again when it finishes."
        default:
            return z.errorDescription ?? "Something went wrong. Try again."
        }
    }

    private static func isGenericRetryable(_ z: ZoroError) -> Bool {
        switch z {
        case .http, .decoding, .invalidResponse, .unavailable, .biometryUnavailable: false
        default: true
        }
    }

    private static func sentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return t }
        return ".!?".contains(last) ? t : t + "."
    }
}

/// A short result of an action, shown inline. It never replaces loaded content.
public struct SystemNotice: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case success, failure }
    public var kind: Kind
    public var text: String
    public var id: String { "\(kind)-\(text)" }
    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
    public static func success(_ text: String) -> SystemNotice { SystemNotice(.success, text) }
    public static func failure(_ text: String) -> SystemNotice { SystemNotice(.failure, text) }

    /// A failure notice for an action that did not happen. nil for a cancellation (the owner chose to stop).
    static func failed(_ error: Error, action: String) -> SystemNotice? {
        guard let message = SystemFailure.message(for: error) else { return nil }
        return .failure("\(action) didn't happen. \(message)")
    }
}
