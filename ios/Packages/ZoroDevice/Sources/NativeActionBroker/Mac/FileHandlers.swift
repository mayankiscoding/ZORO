#if os(macOS)
import AppKit
import Foundation
import ZoroCore

/// A folder the owner approved for search (the app shell picks it with an open panel and keeps the
/// security-scoped bookmark; it must keep access started while the folder is listed).
public struct ApprovedFolder: Sendable, Equatable {
    /// Stable, opaque reference sent to the backend (letters, digits, `-`, `_`).
    public var ref: String
    public var url: URL
    public var name: String
    public init(ref: String, url: URL, name: String) {
        self.ref = ref
        self.url = url
        self.name = name
    }
}

public protocol ApprovedFoldersProviding: Sendable {
    func approvedFolders() async -> [ApprovedFolder]
}

/// In-memory list the app shell fills from its stored bookmarks.
public actor ApprovedFolderList: ApprovedFoldersProviding {
    private var folders: [ApprovedFolder]
    public init(_ folders: [ApprovedFolder] = []) { self.folders = folders }
    public func approvedFolders() async -> [ApprovedFolder] { folders }
    public func set(_ folders: [ApprovedFolder]) { self.folders = folders }
}

/// Spotlight search inside one folder.
public protocol FileSearching: Sendable {
    func search(_ query: String, in folder: URL, limit: Int) async throws -> [URL]
}

/// `mdfind -onlyin <folder> <query>` through `ProcessRunning` (no shell).
public struct SpotlightFileSearcher: FileSearching {
    let runner: any ProcessRunning
    public init(runner: any ProcessRunning = SystemProcessRunner()) { self.runner = runner }

    public func search(_ query: String, in folder: URL, limit: Int) async throws -> [URL] {
        let out = try await runner.run(
            URL(fileURLWithPath: "/usr/bin/mdfind"), arguments: ["-onlyin", folder.path, query], timeout: .seconds(20))
        guard out.status == 0 else { throw DeviceActionError.failed("Spotlight search did not finish.") }
        return out.stdout.split(separator: "\n").prefix(limit * 4).map { URL(fileURLWithPath: String($0)) }
    }
}

/// Opens Mac files and URLs through NSWorkspace.
public struct WorkspaceURLOpener: URLOpening {
    public init() {}
    public func open(_ url: URL) async -> Bool {
        await MainActor.run { NSWorkspace.shared.open(url) }
    }
}

/// `mac.file.search` and `mac.file.open`, limited to approved folders.
public struct FileHandler: DeviceActionHandler {
    let folders: any ApprovedFoldersProviding
    let searcher: any FileSearching
    let opener: any URLOpening
    let timeZone: TimeZone

    public init(folders: any ApprovedFoldersProviding, searcher: any FileSearching, opener: any URLOpening, timeZone: TimeZone = .current) {
        self.folders = folders
        self.searcher = searcher
        self.opener = opener
        self.timeZone = timeZone
    }

    public var tools: [DeviceToolName] { [.fileSearch, .fileOpen] }

    static let noFolders = DeviceActionError.unsupported(
        "No folders are approved for search. Add one in Settings > Device control.", status: .manualUserStep)

    /// The path of `url` relative to `folder`, or nil when it is outside (symlinks resolved).
    public static func relativePath(of url: URL, in folder: URL) -> String? {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// `<folder_ref>:<relative path>` back to a file URL inside an approved folder.
    public static func resolve(_ pathRef: String, folders: [ApprovedFolder]) throws -> URL {
        let bad = DeviceActionError.invalidArgument("path_ref", "is not a file in an approved folder")
        guard let colon = pathRef.firstIndex(of: ":") else { throw bad }
        let ref = String(pathRef[..<colon])
        let relative = String(pathRef[pathRef.index(after: colon)...])
        guard let folder = folders.first(where: { $0.ref == ref }), !relative.isEmpty, !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
        else { throw bad }
        let url = folder.url.appendingPathComponent(relative)
        guard relativePath(of: url, in: folder.url) != nil else { throw bad }
        return url
    }

    public func prepare(_ tool: DeviceToolName, _ args: ToolArguments) throws -> PreparedDeviceAction {
        let folders = self.folders
        switch tool {
        case .fileSearch:
            let query = try args.requiredString("query", maxLength: 200)
            guard !query.hasPrefix("-") else { throw DeviceActionError.invalidArgument("query", "must not start with “-”") }
            let folderRef = try args.string("folder_ref", maxLength: 100)
            let searcher = self.searcher
            let tz = timeZone
            return PreparedDeviceAction(summary: "Search your approved folders for “\(query)”.") {
                var scope = await folders.approvedFolders()
                if let folderRef {
                    scope = scope.filter { $0.ref == folderRef }
                    if scope.isEmpty { throw DeviceActionError.invalidArgument("folder_ref", "is not an approved folder") }
                }
                guard !scope.isEmpty else { throw Self.noFolders }
                var files: [JSONValue] = []
                let limit = 25
                for folder in scope where files.count < limit {
                    try Task.checkCancellation()
                    for url in try await searcher.search(query, in: folder.url, limit: limit) where files.count < limit {
                        guard let rel = Self.relativePath(of: url, in: folder.url) else { continue }
                        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                        guard values?.isRegularFile == true else { continue }
                        var item: JSONObject = ["path_ref": .string("\(folder.ref):\(rel)"), "name": .string(url.lastPathComponent)]
                        item["modified_at"] = values?.contentModificationDate.map { .string(DeviceTime.iso($0, timeZone: tz)) } ?? .null
                        files.append(.object(item))
                    }
                }
                return ["files": .array(files)]
            }
        case .fileOpen:
            let pathRef = try args.requiredString("path_ref", maxLength: 2000)
            let opener = self.opener
            return PreparedDeviceAction(summary: "Open a file from your approved folders.") {
                let approved = await folders.approvedFolders()
                guard !approved.isEmpty else { throw Self.noFolders }
                let url = try Self.resolve(pathRef, folders: approved)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw DeviceActionError.failed("That file is no longer there.")
                }
                guard await opener.open(url) else { throw DeviceActionError.failed("No app could open that file.") }
                return ["opened": true]
            }
        default:
            throw DeviceActionError.unsupported("\(tool.rawValue) is not a file tool.")
        }
    }
}
#endif
