import Foundation

/// Server address and one-time code carried by a `zoro://pair` link or the setup QR code.
public struct PairingLink: Sendable, Equatable {
    public var serverURL: URL
    /// Normalised: upper-case letters and digits only (the server normalises the same way).
    public var code: String

    public init(serverURL: URL, code: String) {
        self.serverURL = serverURL
        self.code = code
    }

    /// Upper-cases and strips everything that is not a letter or digit ("abcd-1234" → "ABCD1234").
    public static func normaliseCode(_ raw: String) -> String {
        String(raw.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init))
    }

    /// Parses a typed or scanned server address. Adds `https://` when no scheme is given; accepts only
    /// http and https with a host.
    public static func serverURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: withScheme),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host, !host.isEmpty
        else { return nil }
        return components.url
    }
}

/// Every link the app opens.
///
/// - `zoro://section/<name>` opens a section (`zoro://section/shopping`)
/// - `zoro://voice` opens Live Voice
/// - `zoro://ask?text=<phrase>` opens ZORO and sends the phrase as a turn
/// - `zoro://pair?server=<address>&code=<code>` fills the pairing form (the setup QR code carries this)
public enum DeepLink: Sendable, Equatable {
    case section(AppSection)
    case voice
    case ask(String)
    case pair(PairingLink)

    public static let scheme = "zoro"

    public static func parse(_ url: URL) throws(DeepLinkError) -> DeepLink {
        guard url.scheme?.lowercased() == scheme else { throw .unsupportedScheme(url.scheme ?? "") }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // zoro://section/x has host "section" and path "/x"; zoro:section/x has no host.
        var parts = [url.host].compactMap { $0 } + url.path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { throw .unknownRoute("") }
        let route = parts.removeFirst().lowercased()
        let query = components?.queryItems ?? []
        func value(_ names: String...) -> String? {
            for name in names {
                if let v = query.first(where: { $0.name.lowercased() == name })?.value, !v.isEmpty { return v }
            }
            return nil
        }
        switch route {
        case "section":
            guard let name = parts.first ?? value("name") else { throw .unknownSection("") }
            guard let section = AppSection(name: name) else { throw .unknownSection(name) }
            return section == .liveVoice ? .voice : .section(section)
        case "voice", "live-voice", "listen":
            return .voice
        case "ask":
            let text = (value("text", "q") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw .missingText }
            return .ask(String(text.prefix(AskLimits.maxPhraseLength)))
        case "pair":
            guard let rawServer = value("server", "address", "url"), let server = PairingLink.serverURL(from: rawServer) else {
                throw .invalidPairing("The link has no valid server address.")
            }
            let code = PairingLink.normaliseCode(value("code") ?? "")
            guard !code.isEmpty else { throw .invalidPairing("The link has no pairing code.") }
            return .pair(PairingLink(serverURL: server, code: code))
        default:
            throw .unknownRoute(route)
        }
    }

    /// The canonical URL for this link (used by intents, Handoff and tests).
    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .section(let s):
            c.host = "section"
            c.path = "/\(s.rawValue)"
        case .voice:
            c.host = "voice"
        case .ask(let text):
            c.host = "ask"
            c.queryItems = [URLQueryItem(name: "text", value: text)]
        case .pair(let link):
            c.host = "pair"
            c.queryItems = [URLQueryItem(name: "server", value: link.serverURL.absoluteString), URLQueryItem(name: "code", value: link.code)]
        }
        return c.url!
    }
}

public enum AskLimits {
    /// Longer phrases are cut; a turn is a request, not a document.
    public static let maxPhraseLength = 2_000
}

public enum DeepLinkError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedScheme(String)
    case unknownRoute(String)
    case unknownSection(String)
    case missingText
    case invalidPairing(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme: "ZORO can't open this kind of link."
        case .unknownRoute(let r): "ZORO doesn't know the link \"\(r)\"."
        case .unknownSection(let s): s.isEmpty ? "The link doesn't name a section." : "ZORO has no section called \"\(s)\"."
        case .missingText: "The link has nothing to ask."
        case .invalidPairing(let m): m
        }
    }
}
