#if os(macOS)
import Foundation
import ZoroCore

/// One parameter of an allowlisted script. Values reach the script only through `argv`.
public struct AppleScriptParameter: Sendable {
    public var name: String
    public var maxLength: Int
    public var isValid: @Sendable (String) -> Bool
    public init(name: String, maxLength: Int = 200, isValid: @escaping @Sendable (String) -> Bool = { _ in true }) {
        self.name = name
        self.maxLength = maxLength
        self.isValid = isValid
    }
}

/// A fixed script the owner's build ships with. Its source is a constant; a model never writes it.
public struct AppleScriptDefinition: Sendable {
    public var id: String
    public var summary: String
    /// Script lines, each passed as its own `-e`. Parameters are read with `item n of argv`.
    public var lines: [String]
    public var parameters: [AppleScriptParameter]
    public init(id: String, summary: String, lines: [String], parameters: [AppleScriptParameter] = []) {
        self.id = id
        self.summary = summary
        self.lines = lines
        self.parameters = parameters
    }
}

/// The allowlist. Unknown ids are refused.
public struct AppleScriptCatalog: Sendable {
    public let definitions: [String: AppleScriptDefinition]

    public init(_ definitions: [AppleScriptDefinition]) {
        self.definitions = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public subscript(id: String) -> AppleScriptDefinition? { definitions[id] }

    public static func isSpotifyURI(_ s: String) -> Bool {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        let kinds: Set<Substring> = ["track", "album", "playlist", "artist", "episode", "show"]
        return parts.count == 3 && parts[0] == "spotify" && kinds.contains(parts[1]) && parts[2].count == 22
            && parts[2].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func simple(_ id: String, _ app: String, _ verb: String, _ summary: String) -> AppleScriptDefinition {
        AppleScriptDefinition(
            id: id, summary: summary, lines: ["on run argv", "tell application \"\(app)\" to \(verb)", "end run"])
    }

    private static func nowPlaying(_ id: String, _ app: String) -> AppleScriptDefinition {
        AppleScriptDefinition(
            id: id, summary: "Read what \(app) is playing.",
            lines: [
                "on run argv",
                "if application \"\(app)\" is not running then return \"\"",
                "tell application \"\(app)\"",
                "if player state is not playing then return \"\"",
                "return (name of current track) & tab & (artist of current track)",
                "end tell",
                "end run",
            ])
    }

    /// Music control for Music and Spotify.
    public static let standard = AppleScriptCatalog([
        simple("music.apple.play", "Music", "play", "Play Music."),
        simple("music.apple.pause", "Music", "pause", "Pause Music."),
        simple("music.apple.next", "Music", "next track", "Skip to the next song in Music."),
        simple("music.apple.previous", "Music", "previous track", "Go back a song in Music."),
        nowPlaying("music.apple.now_playing", "Music"),
        AppleScriptDefinition(
            id: "music.apple.search_play", summary: "Play a song from your Music library.",
            lines: [
                "on run argv",
                "tell application \"Music\"",
                "set hits to (search library playlist 1 for (item 1 of argv))",
                "if hits is {} then return \"\"",
                "play item 1 of hits",
                "return (name of item 1 of hits) & tab & (artist of item 1 of hits)",
                "end tell",
                "end run",
            ],
            parameters: [AppleScriptParameter(name: "query", maxLength: 200)]),
        simple("music.spotify.play", "Spotify", "play", "Play Spotify."),
        simple("music.spotify.pause", "Spotify", "pause", "Pause Spotify."),
        simple("music.spotify.next", "Spotify", "next track", "Skip to the next song in Spotify."),
        simple("music.spotify.previous", "Spotify", "previous track", "Go back a song in Spotify."),
        nowPlaying("music.spotify.now_playing", "Spotify"),
        AppleScriptDefinition(
            id: "music.spotify.play_uri", summary: "Play a Spotify item.",
            lines: ["on run argv", "tell application \"Spotify\" to play track (item 1 of argv)", "end run"],
            parameters: [AppleScriptParameter(name: "uri", maxLength: 80, isValid: { AppleScriptCatalog.isSpotifyURI($0) })]),
    ])
}

/// Runs allowlisted scripts.
public protocol AppleScriptRunning: Sendable {
    /// Returns the script's output, trimmed; nil when empty.
    func run(scriptId: String, params: [String: String]) async throws -> String?
    func summary(scriptId: String) -> String?
}

/// Runs catalog scripts with `/usr/bin/osascript -e <line>… -- <param>…`. The source is the catalog
/// constant; parameters are separate arguments after `--`, so they can never become script text or options.
public struct OSAScriptRunner: AppleScriptRunning {
    let catalog: AppleScriptCatalog
    let runner: any ProcessRunning
    public init(catalog: AppleScriptCatalog = .standard, runner: any ProcessRunning = SystemProcessRunner()) {
        self.catalog = catalog
        self.runner = runner
    }

    public static let executable = URL(fileURLWithPath: "/usr/bin/osascript")

    public func summary(scriptId: String) -> String? { catalog[scriptId]?.summary }

    /// Validates and builds the argument vector (exposed for tests).
    public func arguments(scriptId: String, params: [String: String]) throws -> [String] {
        guard let def = catalog[scriptId] else {
            throw DeviceActionError.invalidArgument("script_id", "is not an allowlisted script")
        }
        let known = Set(def.parameters.map(\.name))
        if let extra = params.keys.sorted().first(where: { !known.contains($0) }) {
            throw DeviceActionError.invalidArgument("params.\(extra)", "is not a parameter of \(scriptId)")
        }
        var values: [String] = []
        for p in def.parameters {
            guard let v = params[p.name], !v.isEmpty else {
                throw DeviceActionError.invalidArgument("params.\(p.name)", "is required")
            }
            guard v.count <= p.maxLength, !v.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                  p.isValid(v)
            else { throw DeviceActionError.invalidArgument("params.\(p.name)", "is not valid for \(scriptId)") }
            values.append(v)
        }
        return def.lines.flatMap { ["-e", $0] } + ["--"] + values
    }

    public func run(scriptId: String, params: [String: String]) async throws -> String? {
        let args = try arguments(scriptId: scriptId, params: params)
        let output = try await runner.run(Self.executable, arguments: args, timeout: .seconds(30))
        guard output.status == 0 else {
            // -1743: the owner has not allowed ZORO to control that app (Privacy & Security > Automation).
            if output.stderr.contains("-1743") || output.stderr.contains("Not authorized") {
                throw DeviceActionError.permissionDenied("control that app (Automation)")
            }
            if output.stderr.contains("-600") || output.stderr.contains("-1728") {
                throw DeviceActionError.unsupported("That app is not installed or not running.", status: .manualUserStep)
            }
            throw DeviceActionError.failed("The script \(scriptId) did not finish.")
        }
        let text = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// `mac.applescript.run`.
public struct AppleScriptHandler: DeviceActionHandler {
    let runner: any AppleScriptRunning
    public init(runner: any AppleScriptRunning) { self.runner = runner }

    public var tools: [DeviceToolName] { [.appleScriptRun] }

    public func prepare(_ tool: DeviceToolName, _ args: ToolArguments) throws -> PreparedDeviceAction {
        let id = try args.requiredString("script_id", maxLength: 100)
        guard let summary = runner.summary(scriptId: id) else {
            throw DeviceActionError.invalidArgument("script_id", "is not an allowlisted script")
        }
        let params = try args.stringMap("params") ?? [:]
        let runner = self.runner
        return PreparedDeviceAction(summary: summary) {
            let output = try await runner.run(scriptId: id, params: params)
            return output.map { ["output": .string($0)] } ?? [:]
        }
    }
}
#endif
