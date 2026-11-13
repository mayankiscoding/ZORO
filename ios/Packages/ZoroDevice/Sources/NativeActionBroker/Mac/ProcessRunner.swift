#if os(macOS)
import Foundation

public struct ProcessOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public init(status: Int32, stdout: String, stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs an executable with an argument vector. Never goes through a shell.
public protocol ProcessRunning: Sendable {
    func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessOutput
}

/// `Process`-based runner. Output goes to temporary files (no pipe-buffer deadlock); the process is
/// terminated on timeout or task cancellation.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    private final class Box: @unchecked Sendable {
        let process = Process()
        let lock = NSLock()
        var finished = false
    }

    public func run(_ executable: URL, arguments: [String], timeout: Duration) async throws -> ProcessOutput {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("zoro-proc-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let outURL = dir.appendingPathComponent("out")
        let errURL = dir.appendingPathComponent("err")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let box = Box()
        box.process.executableURL = executable
        box.process.arguments = arguments
        box.process.standardInput = FileHandle.nullDevice
        box.process.standardOutput = outHandle
        box.process.standardError = errHandle

        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            box.lock.withLock { if !box.finished, box.process.isRunning { box.process.terminate() } }
        }
        defer { watchdog.cancel() }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                box.process.terminationHandler = { p in
                    box.lock.withLock { box.finished = true }
                    continuation.resume(returning: p.terminationStatus)
                }
                do { try box.process.run() } catch {
                    box.process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.lock.withLock { if !box.finished, box.process.isRunning { box.process.terminate() } }
        }
        try Task.checkCancellation()
        func read(_ url: URL) -> String {
            guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
            defer { try? h.close() }
            let data = (try? h.read(upToCount: 1_000_000)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        return ProcessOutput(status: status, stdout: read(outURL), stderr: read(errURL))
    }
}

/// Mac: `/usr/bin/shortcuts run <name>`, the name passed as one argument after `--`.
public struct ProcessShortcutRunner: ShortcutRunning {
    let runner: any ProcessRunning
    let timeout: Duration
    public init(runner: any ProcessRunning = SystemProcessRunner(), timeout: Duration = .seconds(120)) {
        self.runner = runner
        self.timeout = timeout
    }

    public static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")

    public func run(name: String, input: String?) async throws {
        var arguments = ["run"]
        var inputFile: URL?
        if let input {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("zoro-shortcut-\(UUID().uuidString).txt")
            try Data(input.utf8).write(to: url, options: .atomic)
            inputFile = url
            arguments += ["--input-path", url.path]
        }
        defer { if let inputFile { try? FileManager.default.removeItem(at: inputFile) } }
        arguments += ["--", name]
        let output = try await runner.run(Self.executable, arguments: arguments, timeout: timeout)
        guard output.status == 0, !output.stderr.contains("Couldn’t find shortcut") else {
            throw DeviceActionError.failed("The shortcut “\(name)” did not run. Check that it exists in Shortcuts.")
        }
    }
}
#endif
