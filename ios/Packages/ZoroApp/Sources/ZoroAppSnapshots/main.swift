#if canImport(AppKit) && !targetEnvironment(macCatalyst) && DEBUG
import AppKit
import ConversationManager
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import ZoroAppUI
import ZoroCore
import ZoroDesign

/// Renders Home, Live Voice and the approval sheet to PNG with ImageRenderer (macOS host tool).
///
///     scripts/swiftpm.sh ZoroApp run ZoroAppSnapshots "<repo>/docs/design/snapshots"
///
/// Only interface copy appears: no names, prices or other personal data.
@MainActor
enum Snapshots {
    static let phone = CGSize(width: 390, height: 780)

    static func home(_ input: HomePresentation.Input, level: Double = 0) -> AnyView {
        AnyView(HomeScreen(
            presentation: HomePresentation.make(input), level: level, cards: CardRendererRegistry(),
            draft: .constant(""), actions: HomeActions(), isSnapshot: true))
    }

    static func levels(_ seed: Double, count: Int = 48, active: ClosedRange<Int>) -> [Double] {
        (0..<count).map { i in
            guard active.contains(i) else { return 0 }
            let x = Double(i) * seed
            return max(0.08, min(1, 0.45 + 0.35 * sin(x) + 0.2 * sin(x * 2.7)))
        }
    }

    static func run(out: URL) throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let owner = "Switch to private mode"
        let reply = "Private mode is on."
        let exchange = [
            TranscriptEntry(id: "1", role: .user, text: owner, createdAt: Date()),
            TranscriptEntry(id: "2", role: .assistant, text: reply, createdAt: Date()),
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let approval = ApprovalRequest(
            approvalId: "specimen", tool: "communication.send_message", agent: .communication, risk: .high, level: .biometric,
            title: "Send a message", summary: "Send this message on WhatsApp.",
            details: [LabelValue(label: "To", value: "The contact you named"), LabelValue(label: "Message", value: "The text you dictated")],
            actionDigest: "specimen", expiresAt: now.addingTimeInterval(105))
        let sheet = ApprovalSheetModel(request: approval, biometricName: "Face ID")

        let jobs: [(String, ColorScheme, CGSize, AnyView)] = [
            ("app-home-idle-light", .light, phone, home(.init(privacyMode: .cloudIntelligence))),
            ("app-home-listening-dark", .dark, phone, home(.init(voice: .listening, transcript: [exchange[0]], privacyMode: .cloudIntelligence), level: 0.5)),
            ("app-home-speaking-light", .light, phone, home(.init(voice: .speaking, transcript: exchange, privacyMode: .strictPrivate), level: 0.4)),
            ("app-home-private-dark", .dark, phone, home(.init(transcript: exchange, privacyMode: .strictPrivate))),
            ("app-home-disconnected-light", .light, phone, home(.init(privacyMode: .strictPrivate, connection: .unreachable))),
            ("app-live-voice-dark", .dark, CGSize(width: 390, height: 844), AnyView(LiveVoiceScreen(
                presentation: HomePresentation.make(.init(voice: .listening, transcript: [exchange[0]], privacyMode: .strictPrivate)),
                level: 0.6, userLevels: levels(0.7, active: 18...47), assistantLevels: levels(0.5, active: 0...14),
                voiceState: .listening, onGesture: { _ in }, onStop: {}, onClose: {}))),
            ("app-approval-dark", .dark, CGSize(width: 390, height: 640), AnyView(ApprovalSheetView(
                model: sheet, now: now, onApprove: {}, onDecline: {}, onClose: {}))),
        ]
        for (name, scheme, size, view) in jobs {
            let url = out.appendingPathComponent("\(name).png")
            let px = try render(view, size: size, scheme: scheme, to: url)
            print("wrote \(url.path) (\(Int(px.width))x\(Int(px.height)) px)")
        }
    }

    enum SnapshotError: Error { case noImage(String), writeFailed(String) }

    static func render(_ view: AnyView, size: CGSize, scheme: ColorScheme, to url: URL) throws -> CGSize {
        let content = view
            .frame(width: size.width, height: size.height)
            .background(ZoroNeutral.background)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        var image: CGImage?
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        guard let cg = image else { throw SnapshotError.noImage(url.lastPathComponent) }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SnapshotError.writeFailed(url.path)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw SnapshotError.writeFailed(url.path) }
        return CGSize(width: cg.width, height: cg.height)
    }
}

let arguments = CommandLine.arguments.dropFirst()
let output = URL(fileURLWithPath: arguments.first ?? "docs/design/snapshots", isDirectory: true)
MainActor.assumeIsolated {
    do {
        try Snapshots.run(out: output)
    } catch {
        FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
        exit(1)
    }
}
#else
print("ZoroAppSnapshots runs only in macOS debug builds.")
#endif
