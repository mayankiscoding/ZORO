import Foundation

// Mirrors backend/app/schemas/auth.py. Public keys: base64 X9.63 (65 bytes). Signatures: DER, base64.

public struct PairRequest: Codable, Sendable, Equatable {
    public var pairingCode: String
    public var deviceName: String
    public var platform: DevicePlatform
    public var authPublicKeyB64: String
    public var approvalPublicKeyB64: String
    public var capabilities: [String]
    public var appVersion: String?

    public init(
        pairingCode: String, deviceName: String, platform: DevicePlatform, authPublicKeyB64: String,
        approvalPublicKeyB64: String, capabilities: [String] = [], appVersion: String? = nil
    ) {
        self.pairingCode = pairingCode
        self.deviceName = deviceName
        self.platform = platform
        self.authPublicKeyB64 = authPublicKeyB64
        self.approvalPublicKeyB64 = approvalPublicKeyB64
        self.capabilities = capabilities
        self.appVersion = appVersion
    }

    enum CodingKeys: String, CodingKey {
        case pairingCode = "pairing_code"
        case deviceName = "device_name"
        case platform
        case authPublicKeyB64 = "auth_public_key_b64"
        case approvalPublicKeyB64 = "approval_public_key_b64"
        case capabilities
        case appVersion = "app_version"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pairingCode = try c.decode(String.self, forKey: .pairingCode)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        platform = try c.decode(DevicePlatform.self, forKey: .platform)
        authPublicKeyB64 = try c.decode(String.self, forKey: .authPublicKeyB64)
        approvalPublicKeyB64 = try c.decode(String.self, forKey: .approvalPublicKeyB64)
        capabilities = try c.value(.capabilities, default: [])
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
    }
}

public struct PairResponse: Codable, Sendable, Equatable {
    public var deviceId: String
    public var serverName: String
    public var serverTime: Date

    public init(deviceId: String, serverName: String, serverTime: Date) {
        self.deviceId = deviceId
        self.serverName = serverName
        self.serverTime = serverTime
    }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case serverName = "server_name"
        case serverTime = "server_time"
    }
}

public struct ChallengeRequest: Codable, Sendable, Equatable {
    public var deviceId: String
    public init(deviceId: String) { self.deviceId = deviceId }
    enum CodingKeys: String, CodingKey { case deviceId = "device_id" }
}

public struct ChallengeResponse: Codable, Sendable, Equatable {
    public var nonce: String
    public var expiresAt: Date
    public init(nonce: String, expiresAt: Date) {
        self.nonce = nonce
        self.expiresAt = expiresAt
    }
    enum CodingKeys: String, CodingKey {
        case nonce
        case expiresAt = "expires_at"
    }
}

/// `signatureB64` signs `zoro-auth-v1|{device_id}|{nonce}` with the auth key.
public struct TokenRequest: Codable, Sendable, Equatable {
    public var deviceId: String
    public var nonce: String
    public var signatureB64: String
    public init(deviceId: String, nonce: String, signatureB64: String) {
        self.deviceId = deviceId
        self.nonce = nonce
        self.signatureB64 = signatureB64
    }
    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case nonce
        case signatureB64 = "signature_b64"
    }
}

public struct TokenResponse: Codable, Sendable, Equatable {
    public var accessToken: String
    public var tokenType: String
    public var expiresIn: Int

    public init(accessToken: String, tokenType: String = "bearer", expiresIn: Int) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        tokenType = try c.value(.tokenType, default: "bearer")
        expiresIn = try c.decode(Int.self, forKey: .expiresIn)
    }
}

public struct DeviceInfo: Codable, Sendable, Equatable {
    public var deviceId: String
    public var name: String
    public var platform: DevicePlatform
    public var capabilities: [String]
    public var lastSeenAt: Date?
    public var online: Bool
    public var revoked: Bool

    public init(
        deviceId: String, name: String, platform: DevicePlatform, capabilities: [String] = [],
        lastSeenAt: Date? = nil, online: Bool = false, revoked: Bool = false
    ) {
        self.deviceId = deviceId
        self.name = name
        self.platform = platform
        self.capabilities = capabilities
        self.lastSeenAt = lastSeenAt
        self.online = online
        self.revoked = revoked
    }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case name, platform, capabilities
        case lastSeenAt = "last_seen_at"
        case online, revoked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        name = try c.decode(String.self, forKey: .name)
        platform = try c.decode(DevicePlatform.self, forKey: .platform)
        capabilities = try c.value(.capabilities, default: [])
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        online = try c.value(.online, default: false)
        revoked = try c.value(.revoked, default: false)
    }
}
