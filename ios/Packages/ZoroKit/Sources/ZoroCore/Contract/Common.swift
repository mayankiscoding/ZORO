import Foundation

// Mirrors backend/app/schemas/common.py.

extension KeyedDecodingContainer {
    /// Pydantic default semantics: a missing (or null) key takes the model default.
    @inlinable
    public func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback()
    }
}

/// Exact money. `amount` is a decimal string on the wire, `Decimal` here. Never a floating-point number.
public struct Money: Codable, Sendable, Equatable, Hashable {
    public var amount: Decimal
    public var currency: String

    public init(amount: Decimal, currency: String = "INR") {
        self.amount = amount
        self.currency = currency
    }

    enum CodingKeys: String, CodingKey { case amount, currency }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeDecimalString(forKey: .amount)
        currency = try c.value(.currency, default: "INR")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeDecimalString(amount, forKey: .amount)
        try c.encode(currency, forKey: .currency)
    }
}

public struct LabelValue: Codable, Sendable, Equatable, Hashable {
    public var label: String
    public var value: String
    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// Cursor-paginated list.
public struct Page<T: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var items: [T]
    public var nextCursor: String?

    public init(items: [T], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

/// Which device key signed a `SignedProof`.
public enum ProofKey: String, Codable, Sendable, CaseIterable {
    case approval, auth
}

/// Signed bytes: `zoro-action-v1|{action}|{subject}|{signed_at}` (see SecurityManager.SignedStrings).
public struct SignedProof: Codable, Sendable, Equatable {
    public var deviceId: String
    public var signedAt: Date
    public var signatureB64: String
    public var key: ProofKey

    public init(deviceId: String, signedAt: Date, signatureB64: String, key: ProofKey = .approval) {
        self.deviceId = deviceId
        self.signedAt = signedAt
        self.signatureB64 = signatureB64
        self.key = key
    }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case signedAt = "signed_at"
        case signatureB64 = "signature_b64"
        case key
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        signedAt = try c.decode(Date.self, forKey: .signedAt)
        signatureB64 = try c.decode(String.self, forKey: .signatureB64)
        key = try c.value(.key, default: .approval)
    }
}

/// A structured result the app renders natively. `payload` is the domain DTO for `kind`.
public struct UICard: Codable, Sendable, Equatable, Hashable {
    public var kind: String
    public var title: String?
    public var payload: JSONObject

    public init(kind: String, title: String? = nil, payload: JSONObject = [:]) {
        self.kind = kind
        self.title = title
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey { case kind, title, payload }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        payload = try c.value(.payload, default: [:])
    }

    /// Decodes the payload into a typed DTO.
    public func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONValue.object(payload).decode(T.self)
    }
}

public struct ErrorBody: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var retryable: Bool
    public var detail: JSONObject?

    public init(code: String, message: String, retryable: Bool = false, detail: JSONObject? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey { case code, message, retryable, detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        message = try c.decode(String.self, forKey: .message)
        retryable = try c.value(.retryable, default: false)
        detail = try c.decodeIfPresent(JSONObject.self, forKey: .detail)
    }
}
