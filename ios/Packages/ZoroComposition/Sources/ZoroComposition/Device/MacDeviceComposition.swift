#if os(macOS)
import AppKit
import Foundation
import MusicIntegration
import NativeActionBroker
import ZoroCore

/// The Mac's device handlers: the system set (calendar, contacts, notifications, location, open URL,
/// Shortcuts, WhatsApp compose, allowlisted AppleScript, file search and open in approved folders) and
/// music control for the Music and Spotify apps through allowlisted AppleScript ids. No health handler:
/// the Mac has no Health data.
enum PlatformDeviceHandlers {
    @MainActor
    static func make(folders: any ApprovedFoldersProviding) -> [any DeviceActionHandler] {
        let runner = OSAScriptRunner()
        let opener = WorkspaceURLOpener()
        var handlers = SystemDeviceHandlers.make(folders: folders, appleScript: runner)
        let probe = MusicAvailabilityProbe(appleMusic: nil, spotifyInstalled: { await SpotifyAppPresence.isInstalled() })
        handlers.append(MusicControlHandler(
            controls: [
                ScriptedMusicControl(provider: .appleMusic, runner: runner, opener: opener),
                ScriptedMusicControl(provider: .spotifyApp, runner: runner, opener: opener),
            ],
            availability: { await probe.current() }))
        return handlers
    }
}

/// Where the owner-approved folder bookmarks are kept. `UserDefaults` in the app; a dictionary in tests.
public protocol BookmarkStoring: Sendable {
    func load() -> Data?
    func save(_ data: Data)
}

public struct UserDefaultsBookmarkStorage: BookmarkStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "zoro.mac.approved-folders") {
        self.defaults = defaults
        self.key = key
    }
    public func load() -> Data? { defaults.data(forKey: key) }
    public func save(_ data: Data) { defaults.set(data, forKey: key) }
}

/// The folders the owner approved for `mac.file.search` and `mac.file.open`, kept as security-scoped
/// bookmarks so the sandboxed app can reach them again after a relaunch. A bookmark that no longer
/// resolves is dropped (the folder was moved or deleted); a stale one is refreshed.
public actor SecurityScopedFolderStore: ApprovedFoldersProviding {
    struct Record: Codable, Equatable {
        var ref: String
        var name: String
        var bookmark: Data
    }

    private let storage: any BookmarkStoring
    private let bookmarkOptions: URL.BookmarkCreationOptions
    private let resolveOptions: URL.BookmarkResolutionOptions
    private var records: [Record]
    private var accessing: [String: URL] = [:]

    /// - Parameter securityScoped: false only in tests that run outside the sandbox.
    public init(storage: any BookmarkStoring = UserDefaultsBookmarkStorage(), securityScoped: Bool = true) {
        self.storage = storage
        self.bookmarkOptions = securityScoped ? [.withSecurityScope] : []
        self.resolveOptions = securityScoped ? [.withSecurityScope] : []
        self.records = storage.load().flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
    }

    /// Adds a folder the owner picked in an open panel (which grants access for this launch).
    @discardableResult
    public func add(_ url: URL) throws -> ApprovedFolder {
        let data = try url.bookmarkData(options: bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        let ref = Self.ref(for: url, existing: Set(records.map(\.ref)))
        records.removeAll { $0.name == url.lastPathComponent && $0.bookmark == data }
        records.append(Record(ref: ref, name: url.lastPathComponent, bookmark: data))
        persist()
        return ApprovedFolder(ref: ref, url: url, name: url.lastPathComponent)
    }

    public func remove(ref: String) {
        records.removeAll { $0.ref == ref }
        if let url = accessing.removeValue(forKey: ref) { url.stopAccessingSecurityScopedResource() }
        persist()
    }

    public func approvedFolders() async -> [ApprovedFolder] {
        var out: [ApprovedFolder] = []
        var changed = false
        for (index, record) in records.enumerated().reversed() {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: record.bookmark, options: resolveOptions, relativeTo: nil, bookmarkDataIsStale: &stale) else {
                records.remove(at: index)
                changed = true
                continue
            }
            if accessing[record.ref] == nil, url.startAccessingSecurityScopedResource() {
                accessing[record.ref] = url
            }
            if stale, let fresh = try? url.bookmarkData(options: bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
                records[index].bookmark = fresh
                changed = true
            }
            out.append(ApprovedFolder(ref: record.ref, url: url, name: record.name))
        }
        if changed { persist() }
        return out.reversed()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) { storage.save(data) }
    }

    /// Letters, digits, `-` and `_` only (the device contract's folder_ref), unique among the stored refs.
    static func ref(for url: URL, existing: Set<String>) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        var base = String(url.lastPathComponent.lowercased().map { allowed.contains($0) ? $0 : "-" })
        if base.isEmpty || base.allSatisfy({ $0 == "-" }) { base = "folder" }
        base = String(base.prefix(40))
        var candidate = base
        var n = 2
        while existing.contains(candidate) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }
}
#endif
