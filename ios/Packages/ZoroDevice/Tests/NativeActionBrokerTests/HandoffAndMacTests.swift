import Foundation
import Testing
@testable import NativeActionBroker
import ZoroCore

@Suite struct URLPolicyTests {
    @Test func allowsHttpsAndAllowlistedSchemes() throws {
        let p = URLPolicy.standard
        #expect(try p.validate("https://www.example.com/a?b=c").host == "www.example.com")
        #expect(try p.validate("spotify:track:4uLU6hMCjMI75M1A2tKUQC").scheme == "spotify")
        #expect(try p.validate("SHORTCUTS://run-shortcut?name=x").scheme?.lowercased() == "shortcuts")
    }

    @Test(arguments: [
        "http://example.com", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "tel:+911234567890",
        "sms:123", "https://user:pass@example.com", "https:///nohost", "ftp://example.com", "https://exa mple.com",
        "notaurl", "intent://x",
    ])
    func refusesEverythingElse(_ raw: String) {
        #expect(throws: DeviceActionError.self) { try URLPolicy.standard.validate(raw) }
    }

    @Test func customAllowlist() throws {
        let p = URLPolicy(allowedAppSchemes: ["Zoro"])
        #expect(try p.validate("zoro://open").scheme == "zoro")
        #expect(throws: DeviceActionError.self) { try p.validate("spotify:track:x") }
    }

    @Test func openFailureIsReported() async {
        let opener = RecordingOpener()
        await opener.setSucceeds(false)
        let broker = NativeActionBroker(platform: .ios, handlers: [OpenURLHandler(opener: opener)], confirmer: nil, now: { fixedNow })
        let r = await broker.execute(request("device.open_url", ["url": "spotify:track:4uLU6hMCjMI75M1A2tKUQC"]))
        #expect(r.errorCode == "failed")
    }
}

@Suite struct WhatsAppTests {
    @Test func hindiTextIsPercentEncodedUTF8() throws {
        let url = try WhatsAppComposeHandler.composeURL(phone: "+91 98765-43210", text: "नमस्ते")
        #expect(url.absoluteString == "https://wa.me/919876543210?text=%E0%A4%A8%E0%A4%AE%E0%A4%B8%E0%A5%8D%E0%A4%A4%E0%A5%87")
    }

    @Test func reservedCharactersAndHinglishAreEncoded() throws {
        let url = try WhatsAppComposeHandler.composeURL(phone: nil, text: "Chai @ 5? Haan & ok = 100% 👍\nbye")
        #expect(url.absoluteString == "https://wa.me/?text=Chai%20%40%205%3F%20Haan%20%26%20ok%20%3D%20100%25%20%F0%9F%91%8D%0Abye")
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.queryItems?.first?.value == "Chai @ 5? Haan & ok = 100% 👍\nbye")
    }

    @Test func phoneNormalisation() {
        #expect(PhoneNumber.digits("+91 (98765) 43210") == "919876543210")
        #expect(PhoneNumber.digits("0091 98765 43210") == "919876543210")
        #expect(PhoneNumber.digits("98765-x3210") == nil)
        #expect(PhoneNumber.digits("123") == nil)
        #expect(PhoneNumber.digits("1234567890123456") == nil)
    }
}

@Suite struct ShortcutTests {
    @Test func phoneHandoffURL() throws {
        let url = try #require(URLShortcutRunner.url(name: "Log water", input: "250 ml & ice"))
        #expect(url.absoluteString == "shortcuts://run-shortcut?name=Log%20water&input=text&text=250%20ml%20%26%20ice")
        #expect(URLShortcutRunner.url(name: "Focus", input: nil)?.absoluteString == "shortcuts://run-shortcut?name=Focus")
    }

    @Test func phoneRunnerOpensShortcuts() async throws {
        let opener = RecordingOpener()
        try await URLShortcutRunner(opener: opener).run(name: "Focus", input: nil)
        #expect(await opener.opened.first?.scheme == "shortcuts")
    }

    @Test func macRunsShortcutsBinaryWithArgumentVector() async throws {
        let process = FakeProcessRunner()
        try await ProcessShortcutRunner(runner: process).run(name: "-i; rm -rf ~", input: "hello")
        let call = try #require(await process.calls.first)
        #expect(call.0.path == "/usr/bin/shortcuts")
        #expect(call.1.first == "run")
        #expect(call.1.suffix(2) == ["--", "-i; rm -rf ~"])
        #expect(call.1[1] == "--input-path")
    }

    @Test func macFailureIsReported() async {
        let process = FakeProcessRunner()
        await process.setOutput(ProcessOutput(status: 1, stdout: "", stderr: "Error: Couldn’t find shortcut"))
        await #expect(throws: DeviceActionError.self) { try await ProcessShortcutRunner(runner: process).run(name: "Nope", input: nil) }
    }
}

@Suite struct AppleScriptTests {
    @Test func unknownScriptIdIsRefusedWithoutRunning() async {
        let process = FakeProcessRunner()
        let broker = NativeActionBroker(
            platform: .macos, handlers: [AppleScriptHandler(runner: OSAScriptRunner(runner: process))], confirmer: nil, now: { fixedNow })
        for id in ["do shell script", "music.apple.play; rm", "tell application \"Finder\" to delete", ""] {
            let r = await broker.execute(request("mac.applescript.run", ["script_id": .string(id)]))
            #expect(r.errorCode == "invalid_arguments", "\(id)")
        }
        #expect(await process.calls.isEmpty)
    }

    @Test func parametersAreArgumentsNeverSource() throws {
        let runner = OSAScriptRunner(runner: FakeProcessRunner())
        let hostile = "\" & (do shell script \"rm -rf ~\") & \""
        let args = try runner.arguments(scriptId: "music.apple.search_play", params: ["query": hostile])
        let def = try #require(AppleScriptCatalog.standard["music.apple.search_play"])
        #expect(args == def.lines.flatMap { ["-e", $0] } + ["--", hostile])
        // The only place the value appears is the final argv slot, after "--".
        #expect(args.filter { $0.contains("rm -rf") } == [hostile])
        #expect(args.last == hostile)
    }

    @Test func parameterRules() {
        let runner = OSAScriptRunner(runner: FakeProcessRunner())
        #expect(throws: DeviceActionError.self) { try runner.arguments(scriptId: "music.apple.play", params: ["extra": "x"]) }
        #expect(throws: DeviceActionError.self) { try runner.arguments(scriptId: "music.apple.search_play", params: [:]) }
        #expect(throws: DeviceActionError.self) { try runner.arguments(scriptId: "music.spotify.play_uri", params: ["uri": "spotify:track:abc\"; quit"]) }
        #expect((try? runner.arguments(scriptId: "music.spotify.play_uri", params: ["uri": "spotify:track:4uLU6hMCjMI75M1A2tKUQC"]))?.last
            == "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
    }

    @Test func catalogScriptsReadOnlyArgv() {
        for def in AppleScriptCatalog.standard.definitions.values {
            #expect(def.lines.first == "on run argv", "\(def.id)")
            #expect(def.parameters.count == def.lines.joined().components(separatedBy: "argv)").count - 1, "\(def.id)")
        }
    }

    @Test func outputAndAutomationDenial() async throws {
        let process = FakeProcessRunner()
        let runner = OSAScriptRunner(runner: process)
        await process.setOutput(ProcessOutput(status: 0, stdout: "Song\tArtist\n"))
        #expect(try await runner.run(scriptId: "music.apple.now_playing", params: [:]) == "Song\tArtist")
        #expect(await process.calls.first?.0.path == "/usr/bin/osascript")

        await process.setOutput(ProcessOutput(status: 1, stdout: "", stderr: "execution error: Not authorized to send Apple events to Music. (-1743)"))
        let broker = NativeActionBroker(platform: .macos, handlers: [AppleScriptHandler(runner: runner)], confirmer: nil, now: { fixedNow })
        let r = await broker.execute(request("mac.applescript.run", ["script_id": "music.apple.play"]))
        #expect(r.errorCode == "permission_denied")
    }
}

@Suite struct FileAccessTests {
    let base = URL(fileURLWithPath: "/Users/owner/Documents")

    @Test func relativePathStaysInside() {
        #expect(FileHandler.relativePath(of: base.appendingPathComponent("a/b.txt"), in: base) == "a/b.txt")
        #expect(FileHandler.relativePath(of: URL(fileURLWithPath: "/Users/owner/Documents2/x"), in: base) == nil)
        #expect(FileHandler.relativePath(of: URL(fileURLWithPath: "/Users/owner/Documents/../.ssh/id"), in: base) == nil)
        #expect(FileHandler.relativePath(of: base, in: base) == nil)
    }

    @Test func pathRefsCannotEscape() throws {
        let folders = [ApprovedFolder(ref: "docs", url: base, name: "Documents")]
        #expect(try FileHandler.resolve("docs:a/b.txt", folders: folders).path == "/Users/owner/Documents/a/b.txt")
        for bad in ["docs:../.ssh/id_rsa", "docs:/etc/passwd", "other:a.txt", "docs:", "nocolon", "docs:a/./b"] {
            #expect(throws: DeviceActionError.self, "\(bad)") { try FileHandler.resolve(bad, folders: folders) }
        }
    }

    @Test func searchNeedsApprovedFolderAndDropsOutsideHits() async throws {
        let process = FakeProcessRunner()
        let opener = RecordingOpener()
        let empty = NativeActionBroker(
            platform: .macos,
            handlers: [FileHandler(folders: ApprovedFolderList(), searcher: SpotlightFileSearcher(runner: process), opener: opener)],
            confirmer: nil, now: { fixedNow })
        let none = await empty.execute(request("mac.file.search", ["query": "tax"]))
        #expect(none.errorCode == "unsupported" && none.capabilityStatus == .manualUserStep)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zoro-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inside = dir.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: inside)
        await process.setOutput(ProcessOutput(status: 0, stdout: "/etc/hosts\n\(inside.path)\n\(dir.path)\n"))
        let broker = NativeActionBroker(
            platform: .macos,
            handlers: [FileHandler(folders: ApprovedFolderList([ApprovedFolder(ref: "f1", url: dir, name: "Test")]),
                                   searcher: SpotlightFileSearcher(runner: process), opener: opener)],
            confirmer: nil, now: { fixedNow })
        let r = await broker.execute(request("mac.file.search", ["query": "notes"]))
        let files = try #require(r.result?["files"]?.arrayValue)
        #expect(files.count == 1)
        #expect(files.first?["path_ref"] == "f1:notes.txt")
        #expect(files.first?["modified_at"]?.stringValue != nil)
        let args = try #require(await process.calls.last?.1)
        #expect(args == ["-onlyin", dir.path, "notes"])

        let dash = await broker.execute(request("mac.file.search", ["query": "-live"]))
        #expect(dash.errorMessage?.hasPrefix("`query`") == true)
        let wrongFolder = await broker.execute(request("mac.file.search", ["query": "a", "folder_ref": "elsewhere"]))
        #expect(wrongFolder.errorMessage?.hasPrefix("`folder_ref`") == true)
        let missing = await broker.execute(request("mac.file.open", ["path_ref": "f1:gone.txt"]))
        #expect(missing.errorCode == "failed")
    }
}
