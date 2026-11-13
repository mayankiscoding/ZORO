import Foundation
import ZoroCore

/// Opens URLs (UIApplication on iPhone, NSWorkspace on Mac), behind a protocol.
public protocol URLOpening: Sendable {
    /// false when nothing could open the URL (for example the app is not installed).
    func open(_ url: URL) async -> Bool
}

/// Which URLs `device.open_url` may open: `https` with a host, or an allowlisted app scheme.
public struct URLPolicy: Sendable, Equatable {
    public var allowedAppSchemes: Set<String>

    public init(allowedAppSchemes: Set<String>) {
        self.allowedAppSchemes = Set(allowedAppSchemes.map { $0.lowercased() })
    }

    /// App schemes the owner's assistant may hand off to. Never `file`, `javascript`, `data`, `tel`, `sms`.
    public static let standard = URLPolicy(allowedAppSchemes: ["spotify", "shortcuts", "music", "maps", "whatsapp"])

    public func validate(_ raw: String) throws -> URL {
        let key = "url"
        guard raw.count <= 4096 else { throw DeviceActionError.invalidArgument(key, "is too long") }
        guard !raw.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control }) else {
            throw DeviceActionError.invalidArgument(key, "contains spaces or control characters")
        }
        guard let comps = URLComponents(string: raw), let scheme = comps.scheme?.lowercased(), let url = comps.url else {
            throw DeviceActionError.invalidArgument(key, "is not a valid URL")
        }
        if scheme == "https" {
            guard let host = comps.host, !host.isEmpty else { throw DeviceActionError.invalidArgument(key, "has no host") }
            guard comps.user == nil, comps.password == nil else {
                throw DeviceActionError.invalidArgument(key, "must not carry a user name or password")
            }
            return url
        }
        guard allowedAppSchemes.contains(scheme) else {
            throw DeviceActionError.invalidArgument(key, "uses the scheme “\(scheme)”, which ZORO does not open")
        }
        return url
    }
}

/// Strict RFC 3986 percent-encoding of UTF-8 (only unreserved characters stay literal).
public enum PercentEncoding {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

/// `device.open_url`.
public struct OpenURLHandler: DeviceActionHandler {
    let opener: any URLOpening
    let policy: URLPolicy
    public init(opener: any URLOpening, policy: URLPolicy = .standard) {
        self.opener = opener
        self.policy = policy
    }

    public var tools: [DeviceToolName] { [.openURL] }

    public func prepare(_ tool: DeviceToolName, _ args: ToolArguments) throws -> PreparedDeviceAction {
        let url = try policy.validate(try args.requiredString("url", maxLength: 4096))
        let opener = self.opener
        let status: CapabilityStatus = url.scheme?.lowercased() == "https" ? .workingNative : .workingIntegration
        return PreparedDeviceAction(summary: "Open \(url.host ?? url.scheme ?? "the link").", successStatus: status) {
            guard await opener.open(url) else {
                throw DeviceActionError.failed("Nothing on this device could open that link.")
            }
            return ["opened": true]
        }
    }
}

/// `device.whatsapp.compose`: opens WhatsApp with the text filled in; the owner taps send.
public struct WhatsAppComposeHandler: DeviceActionHandler {
    let opener: any URLOpening
    public init(opener: any URLOpening) { self.opener = opener }

    public var tools: [DeviceToolName] { [.whatsappCompose] }

    /// `https://wa.me/<digits>?text=<utf-8 percent-encoded>` or `https://wa.me/?text=…` (owner picks the chat).
    public static func composeURL(phone: String?, text: String) throws -> URL {
        var path = "/"
        if let phone {
            guard let digits = PhoneNumber.digits(phone) else {
                throw DeviceActionError.invalidArgument("phone", "must be an international number (7 to 15 digits)")
            }
            path += digits
        }
        guard let url = URL(string: "https://wa.me" + path + "?text=" + PercentEncoding.encode(text)) else {
            throw DeviceActionError.failed("Could not build the WhatsApp link.")
        }
        return url
    }

    public func prepare(_ tool: DeviceToolName, _ args: ToolArguments) throws -> PreparedDeviceAction {
        let phone = try args.string("phone", maxLength: 40)
        let text = try args.requiredString("text", maxLength: 4000)
        let url = try Self.composeURL(phone: phone, text: text)
        let opener = self.opener
        let to = phone.flatMap(PhoneNumber.digits).map { "+\($0)" } ?? "a chat you pick"
        return PreparedDeviceAction(
            summary: "Open WhatsApp with a message to \(to). You tap send.", successStatus: .manualUserStep
        ) {
            guard await opener.open(url) else {
                throw DeviceActionError.unsupported("WhatsApp could not be opened on this device.", status: .manualUserStep)
            }
            return ["opened": true]
        }
    }
}

// MARK: - Shortcuts

/// Runs a Shortcuts shortcut by name.
public protocol ShortcutRunning: Sendable {
    func run(name: String, input: String?) async throws
}

/// iPhone: hands off to the Shortcuts app through `shortcuts://run-shortcut`.
public struct URLShortcutRunner: ShortcutRunning {
    let opener: any URLOpening
    public init(opener: any URLOpening) { self.opener = opener }

    public static func url(name: String, input: String?) -> URL? {
        var s = "shortcuts://run-shortcut?name=" + PercentEncoding.encode(name)
        if let input { s += "&input=text&text=" + PercentEncoding.encode(input) }
        return URL(string: s)
    }

    public func run(name: String, input: String?) async throws {
        guard let url = Self.url(name: name, input: input), await opener.open(url) else {
            throw DeviceActionError.unsupported("The Shortcuts app could not be opened.", status: .manualUserStep)
        }
    }
}

/// `device.shortcut.run`.
public struct ShortcutHandler: DeviceActionHandler {
    let runner: any ShortcutRunning
    let successStatus: CapabilityStatus
    public init(runner: any ShortcutRunning, successStatus: CapabilityStatus = .workingNative) {
        self.runner = runner
        self.successStatus = successStatus
    }

    public var tools: [DeviceToolName] { [.shortcutRun] }

    public func prepare(_ tool: DeviceToolName, _ args: ToolArguments) throws -> PreparedDeviceAction {
        let name = try args.requiredString("name", maxLength: 200)
        guard !name.contains("\n") else { throw DeviceActionError.invalidArgument("name", "must be one line") }
        let input = try args.string("input", maxLength: 10_000)
        let runner = self.runner
        return PreparedDeviceAction(summary: "Run your shortcut “\(name)”.", successStatus: successStatus) {
            try await runner.run(name: name, input: input)
            return ["started": true]
        }
    }
}
