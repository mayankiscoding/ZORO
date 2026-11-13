import SwiftUI
import ZoroDesign

/// First run. One step per screen, left-aligned, one primary button each.
public struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    /// The setup QR scanner (iOS); nil hides the scan button.
    let scanner: ((@escaping (PairingLink) -> Void) -> AnyView)?

    public init(model: OnboardingModel, scanner: ((@escaping (PairingLink) -> Void) -> AnyView)? = nil) {
        self.model = model
        self.scanner = scanner
    }

    @State private var showingScanner = false

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoroSpace.xl.value) {
                step
            }
            .padding(ZoroSpace.xl.value)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ZoroNeutral.background)
        .zoroAnimation(.emphasized, value: model.step)
        .sheet(isPresented: $showingScanner) {
            if let scanner {
                scanner { link in
                    showingScanner = false
                    Task { await model.apply(link) }
                }
            }
        }
    }

    @ViewBuilder
    private var step: some View {
        switch model.step {
        case .welcome: welcome
        case .connect, .creatingKeys, .pairing: connect
        case .language: language
        case .voice: voice
        case .shortcuts: shortcuts
        case .done: ZoroStateView(.loading, message: "Opening ZORO.")
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.xl.value) {
            OrbView(state: .idle).frame(width: 200, height: 200).frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                Text("ZORO").zoroText(.title)
                Text("Your assistant, running on your own server.").zoroText(.zoroBody)
            }
            Button("Get started") { model.begin() }.buttonStyle(.zoroPrimary)
        }
    }

    private var connect: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
            ZoroSectionHeader("Connect to your ZORO server")
            if scanner != nil {
                Button {
                    showingScanner = true
                } label: {
                    Label("Scan the setup QR code", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.zoroSecondary)
                .disabled(model.isConnecting)
            }
            VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                Text("Server address").zoroText(.detail).foregroundStyle(.secondary)
                TextField("zoro.your-tailnet.ts.net", text: $model.serverAddress)
                    .zoroAddressField()
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)
            }
            VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                Text("Pairing code").zoroText(.detail).foregroundStyle(.secondary)
                TextField("8 letters and digits", text: $model.pairingCode)
                    .zoroCodeField()
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.monospaced())
                Text("Make one on the server with python -m app.cli pairing-code. It works once, for 10 minutes.")
                    .zoroText(.caption).foregroundStyle(.secondary)
            }
            if let problem = model.problem {
                ZoroStateView(.error, message: problem.message)
            }
            switch model.step {
            case .creatingKeys:
                ZoroStateView(.loading, message: "Creating this device's keys. Face ID protects approvals; ZORO can't approve anything without you.")
            case .pairing:
                ZoroStateView(.loading, message: "Connecting to your server.")
            default:
                Button(model.problem == nil ? "Connect" : "Try again") { Task { await model.connect() } }
                    .buttonStyle(.zoroPrimary)
                Button("Back") { model.back() }.buttonStyle(.zoroLink)
            }
        }
    }

    private var language: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
            if let name = model.serverName {
                Label("Connected to \(name)", systemImage: "checkmark.circle").foregroundStyle(.mor).zoroText(.body)
            }
            ZoroSectionHeader("Which language should ZORO reply in?")
            ForEach(ZoroLanguage.allCases) { option in
                choiceRow(title: option.title, detail: option.detail, selected: model.language == option) {
                    model.chooseLanguage(option)
                }
            }
        }
    }

    private var voice: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
            ZoroSectionHeader("Choose ZORO's voice")
            ForEach(VoiceStyle.allCases) { option in
                choiceRow(title: option.title, detail: option.detail, selected: model.voice == option) {
                    model.chooseVoice(option)
                }
            }
            Button("Back") { model.back() }.buttonStyle(.zoroLink)
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
            ZoroSectionHeader("Start ZORO with one press")
            ForEach(ShortcutGuide.steps, id: \.self) { line in
                Label(line, systemImage: "circle.fill")
                    .labelStyle(GuideLabelStyle())
                    .zoroText(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(ShortcutGuide.note).zoroText(.caption).foregroundStyle(.secondary)
            Button("Done") { model.finishShortcuts() }.buttonStyle(.zoroPrimary)
            Button("Skip for now") { model.finishShortcuts() }.buttonStyle(.zoroLink)
        }
    }

    private func choiceRow(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                    Text(title).zoroText(.heading)
                    Text(detail).zoroText(.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.neel) }
            }
            .padding(ZoroSpace.l.value)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZoroNeutral.raised, in: ZoroRadius.card.shape)
            .contentShape(ZoroRadius.card.shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The Action Button and Lock Screen control guide (iPhone). Settings paths as of iOS 18.
public enum ShortcutGuide {
    public static let steps = [
        "Action Button: open Settings, then Action Button, swipe to Shortcut, and choose \"Talk to ZORO\".",
        "Lock Screen: touch and hold the Lock Screen, tap Customize, then Lock Screen, tap a control at the bottom and choose ZORO.",
        "Siri: say \"Ask ZORO\" and then your request.",
    ]
    public static let note = "Each of these opens ZORO's live voice screen. ZORO listens only after you press or tap; there is no wake word."
}

private struct GuideLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ZoroSpace.m.value) {
            Circle().fill(.neel).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            configuration.title
        }
    }
}
