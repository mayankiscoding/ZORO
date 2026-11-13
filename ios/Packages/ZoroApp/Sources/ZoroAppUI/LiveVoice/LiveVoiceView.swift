import SwiftUI
import ZoroCore
import ZoroDesign

/// Live Voice as a pure function of what it shows (previews and snapshots use it directly).
public struct LiveVoiceScreen: View {
    let presentation: HomePresentation
    let level: Double
    let userLevels: [Double]
    let assistantLevels: [Double]
    let voiceState: VoiceSessionState
    let onGesture: (VoiceGesture) -> Void
    let onStop: () -> Void
    let onClose: () -> Void

    public init(
        presentation: HomePresentation, level: Double, userLevels: [Double], assistantLevels: [Double],
        voiceState: VoiceSessionState, onGesture: @escaping (VoiceGesture) -> Void, onStop: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.level = level
        self.userLevels = userLevels
        self.assistantLevels = assistantLevels
        self.voiceState = voiceState
        self.onGesture = onGesture
        self.onStop = onStop
        self.onClose = onClose
    }

    @ScaledMetric(relativeTo: .largeTitle) private var orbSize: CGFloat = 280
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHolding = false
    @State private var pressTask: Task<Void, Never>?
    /// A press longer than this is hold-to-talk; shorter is a tap.
    static let holdThresholdMs = 300

    /// "Stop" interrupts ZORO while it thinks, works or speaks.
    var canStop: Bool { [.processing, .delegating, .toolExecution, .speaking].contains(voiceState) || presentation.isBusy }

    public var body: some View {
        let p = presentation
        VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
            HStack(alignment: .center) {
                if let mode = p.privacyMode { PrivacyModeBanner(mode) }
                Spacer(minLength: ZoroSpace.s.value)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(ZoroNeutral.inset))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close live voice")
                .keyboardShortcut(.cancelAction)
            }

            VStack(spacing: ZoroSpace.m.value) {
                OrbControl(state: p.orbState, level: level, satellites: p.satellites, hint: OrbControl.hint(for: p.orbState)) {
                    onGesture(.tap)
                }
                .frame(width: orbSize, height: orbSize)
                Text(p.stateLabel)
                    .zoroText(.heading)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .zoroAnimation(.emphasized, value: p.stateLabel)
                    .accessibilityAddTraits(.updatesFrequently)
                AgentChipsRow(agents: p.agents)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)

            if let issue = p.issue {
                ZoroStateView(issue.kind == .disconnected ? .disconnected : .error, message: issue.message)
            }

            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                if let zoro = p.zoroText {
                    Text(zoro).zoroText(.zoroVoice).lineLimit(6).fixedSize(horizontal: false, vertical: true)
                }
                RekhaWaveform(userLevels: userLevels, assistantLevels: assistantLevels)
                if let owner = p.ownerText {
                    Text(owner).zoroText(.ownerVoice).foregroundStyle(.secondary).lineLimit(4)
                }
            }

            controls
        }
        .padding(ZoroSpace.l.value)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ZoroNeutral.background)
    }

    private var controls: some View {
        HStack(spacing: ZoroSpace.m.value) {
            talkButton
            if canStop {
                Button("Stop", action: onStop)
                    .buttonStyle(ZoroSecondaryButtonStyle(role: .critical))
                    .frame(maxWidth: 140)
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
    }

    /// Tap to talk (toggles), or hold to talk (listens while held).
    private var talkButton: some View {
        let listening = voiceState == .listening
        let hue: ZoroHue = listening ? .mor : .neel
        let label = hue.labelOnFill(scheme: scheme, highContrast: contrast == .increased).color
        return Text(listening ? (isHolding ? "Release to send" : "Tap to finish") : "Hold or tap to talk")
            .zoroText(.body)
            .fontWeight(.semibold)
            .foregroundStyle(label)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: ZoroRadius.control.value, style: .continuous).fill(ZoroColor(hue)))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard pressTask == nil, !isHolding else { return }
                        pressTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(LiveVoiceScreen.holdThresholdMs))
                            guard !Task.isCancelled else { return }
                            isHolding = true
                            onGesture(.holdBegan)
                        }
                    }
                    .onEnded { _ in
                        pressTask?.cancel()
                        pressTask = nil
                        if isHolding {
                            isHolding = false
                            onGesture(.holdEnded)
                        } else {
                            onGesture(.tap)
                        }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(listening ? "Finish speaking" : "Talk to ZORO")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { onGesture(.tap) }
    }
}

/// Live Voice bound to the shared Home view model. Haptics mark each state change.
public struct LiveVoiceView: View {
    let model: HomeViewModel
    let onClose: () -> Void

    public init(model: HomeViewModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        let p = model.presentation
        LiveVoiceScreen(
            presentation: p, level: model.level, userLevels: model.userLevels.padded,
            assistantLevels: model.assistantLevels.padded, voiceState: model.voiceState,
            onGesture: { g in Task { await model.handle(g) } },
            onStop: { Task { await model.interrupt() } },
            onClose: {
                Task { await model.leaveLiveVoice() }
                onClose()
            })
            .onChange(of: p.orbState) { old, new in
                if let haptic = OrbHaptics.haptic(from: old, to: new) { ZoroHaptics.play(haptic) }
            }
            .task(id: p.orbState) { model.orbDidShow(p.orbState) }
    }
}
