import Foundation

/// Every error ZoroKit surfaces. Messages never contain secrets or raw sensitive payloads.
public enum ZoroError: Error, Sendable, Equatable, LocalizedError {
    /// The device has no pairing yet.
    case notPaired
    /// The server rejected the session even after one re-authentication.
    case unauthorized
    /// Non-2xx HTTP response with the server's `ErrorBody` when it sent one.
    case http(status: Int, body: ErrorBody?)
    case transport(String)
    case decoding(String)
    case invalidResponse(String)
    case keyUnavailable(String)
    case signingFailed(String)
    case authenticationFailed(String)
    case userCancelled
    case biometryUnavailable(String)
    case approvalExpired
    /// A capability is not available here (missing permission, unsupported platform, no credentials).
    case unavailable(capability: String, reason: String)
    case storage(String)
    case cancelled
    case timeout
    /// The server ended a turn with an `error` event.
    case turnFailed(TurnError)
    /// An operation is already in progress (for example a second turn while one is running).
    case busy

    public var errorDescription: String? {
        switch self {
        case .notPaired: "This device is not connected to a ZORO server yet. Pair it in Settings."
        case .unauthorized: "The server did not accept this device. Pair it again."
        case .http(let status, let body): body.map { "\($0.message) (\($0.code))" } ?? "The server answered \(status)."
        case .transport(let m): "Could not reach your ZORO server: \(m)"
        case .decoding(let m): "The server sent something this app does not understand: \(m)"
        case .invalidResponse(let m): "Unexpected server response: \(m)"
        case .keyUnavailable(let m): "The device key is not available: \(m)"
        case .signingFailed(let m): "Could not sign: \(m)"
        case .authenticationFailed(let m): "Authentication failed: \(m)"
        case .userCancelled: "Cancelled."
        case .biometryUnavailable(let m): "Face ID or Touch ID is not available: \(m)"
        case .approvalExpired: "This approval has expired. Ask again."
        case .unavailable(let cap, let reason): "\(cap) is not available: \(reason)"
        case .storage(let m): "Local storage error: \(m)"
        case .cancelled: "Cancelled."
        case .timeout: "The server took too long to answer."
        case .turnFailed(let e): e.message
        case .busy: "Still working on the previous request."
        }
    }

    /// Whether retrying the same operation may succeed.
    public var isRetryable: Bool {
        switch self {
        case .transport, .timeout: true
        case .http(let status, let body): body?.retryable ?? (status >= 500 || status == 429)
        case .turnFailed(let e): e.retryable
        default: false
        }
    }

    /// Maps any error into a `ZoroError`.
    public static func wrap(_ error: Error) -> ZoroError {
        if let z = error as? ZoroError { return z }
        if error is CancellationError { return .cancelled }
        if let u = error as? URLError {
            switch u.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            default: return .transport(u.localizedDescription)
            }
        }
        if error is DecodingError { return .decoding(String(describing: error)) }
        return .transport(String(describing: type(of: error)))
    }
}
