import SwiftUI
import ZoroCore
import ZoroDesign

public struct SettingsView: View {
    @Bindable var model: SettingsViewModel
    let cost: CostViewModel
    let onPair: (@MainActor () -> Void)?

    /// - Parameter onPair: opens the app's pairing flow (address and pairing code).
    public init(model: SettingsViewModel, cost: CostViewModel, onPair: (@MainActor () -> Void)? = nil) {
        self.model = model
        self.cost = cost
        self.onPair = onPair
    }

    public var body: some View {
        ScreenScroll {
            Text("Settings").zoroText(.title).accessibilityAddTraits(.isHeader)
            NoticeBanner(notice: model.notice, dismiss: model.dismissNotice)
            connection
            voice
            appearance
            routes
            NavigationLink {
                CostView(model: cost)
            } label: {
                ZoroCard {
                    InfoRow("Costs", detail: "What cloud models cost, by provider, model, task and day.", symbol: "chart.bar") {
                        Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Settings")
        .systemInlineTitle()
        .task { if model.connection == .unknown { await model.load() } }
        .refreshable { await model.load() }
        .confirmationDialog("Disconnect this device?", isPresented: Binding(get: { model.pendingUnpair }, set: { if !$0 { model.cancelUnpair() } }), titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await model.confirmUnpair() } }
            Button("Stay connected", role: .cancel) { model.cancelUnpair() }
        } message: {
            Text("This removes the keys on this device. To stop it working on the server too, remove it in Security and privacy first.")
        }
    }

    // MARK: Connection

    private var connection: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroSectionHeader("Your ZORO server")
            ZoroCard {
                VStack(alignment: .leading, spacing: 0) {
                    InfoRow(model.connection.title, detail: model.connection.detail, symbol: model.connection.isConnected ? "checkmark.circle" : "bolt.horizontal.circle") {
                        StatusPill(model.connection.isConnected ? "Connected" : "Not connected", role: model.connection.isConnected ? .positive : .attention)
                    }
                    if let address = model.serverAddress {
                        RowDivider()
                        InfoRow("Server address", detail: address, symbol: "network")
                    }
                    if case .connected(let expires) = model.connection {
                        RowDivider()
                        InfoRow("Session", detail: "Signs in again by itself after \(dateText(expires)).", symbol: "clock")
                    }
                    RowDivider()
                    VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                        if let onPair, model.connection != .unknown, !model.connection.isConnected || model.connection == .deviceRemoved {
                            Button(model.connection == .notPaired ? "Connect to your server" : "Pair again") { onPair() }.buttonStyle(.zoroPrimary)
                        }
                        Button("Check connection") { Task { await model.refreshConnection() } }.buttonStyle(.zoroSecondary)
                        if model.deviceId != nil {
                            Button("Disconnect this device") { model.requestUnpair() }.buttonStyle(ZoroSecondaryButtonStyle(role: .critical))
                        }
                    }
                    .padding(.top, ZoroSpace.m.value)
                }
            }
        }
    }

    // MARK: Voice

    private var voice: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroSectionHeader("Voice and language")
            PhaseView(phase: model.voicePhase, loadingMessage: "Loading voice settings.", emptyMessage: model.voiceEmptyMessage, retry: { await model.loadVoice() }) {
                ZoroCard {
                    VStack(alignment: .leading, spacing: 0) {
                        picker("Language", detail: "Interface text follows this setting. ZORO replies in the language you speak.", selection: model.voice.language, options: VoiceSettings.Language.allCases, label: Self.languageTitle) { v in Task { await model.setLanguage(v) } }
                        RowDivider()
                        picker("Answer length", detail: "Spoken answers are always shorter than written ones.", selection: model.voice.responseLength, options: VoiceSettings.ResponseLength.allCases, label: { SystemFormat.sentenceCase($0.rawValue) }) { v in Task { await model.setResponseLength(v) } }
                        RowDivider()
                        picker("Voice style", detail: nil, selection: model.voice.personality, options: VoiceSettings.Personality.allCases, label: { SystemFormat.sentenceCase($0.rawValue) }) { v in Task { await model.setPersonality(v) } }
                        RowDivider()
                        picker("Voice", detail: nil, selection: model.voice.voiceGender, options: VoiceSettings.Gender.allCases, label: { SystemFormat.sentenceCase($0.rawValue) }) { v in Task { await model.setVoiceGender(v) } }
                        RowDivider()
                        picker("Voice engine", detail: "Cloud voice needs cloud intelligence and a provider key. Otherwise ZORO speaks on this device.", selection: model.voice.engine, options: VoiceSettings.Engine.allCases, label: { $0 == .local ? "On this device" : "Cloud" }) { v in Task { await model.setEngine(v) } }
                        RowDivider()
                        picker("Start talking", detail: "ZORO never listens outside an active session.", selection: model.voice.activation, options: VoiceSettings.Activation.allCases, label: Self.activationTitle) { v in Task { await model.setActivation(v) } }
                        RowDivider()
                        VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                            Text("Speaking speed").zoroText(.body)
                            Slider(value: Binding(get: { model.voice.speakingRate }, set: { v in Task { await model.setSpeakingRate(v) } }), in: 0.5...2.0, step: 0.1)
                                .accessibilityLabel("Speaking speed")
                                .accessibilityValue(String(format: "%.1f times", locale: Locale(identifier: "en_US_POSIX"), model.voice.speakingRate))
                            Text(String(format: "%.1fx", locale: Locale(identifier: "en_US_POSIX"), model.voice.speakingRate)).zoroText(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, ZoroSpace.m.value)
                        if !model.engines.isEmpty {
                            RowDivider()
                            VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                                Text("Voice engines").zoroText(.body)
                                ForEach(model.engines, id: \.id) { engine in
                                    Text("\(engine.id): \(engine.available ? "ready" : (engine.reason.isEmpty ? "not available" : engine.reason))")
                                        .zoroText(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, ZoroSpace.m.value)
                        }
                    }
                }
            }
        }
    }

    private func picker<T: Hashable & Sendable>(
        _ title: String, detail: String?, selection: T, options: [T], label: @escaping (T) -> String, onChange: @escaping @Sendable (T) -> Void
    ) -> some View {
        InfoRow(title, detail: detail) {
            Picker(title, selection: Binding(get: { selection }, set: onChange)) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    static func languageTitle(_ l: VoiceSettings.Language) -> String {
        switch l {
        case .auto: "Match what I speak"
        case .en: "English"
        case .hi: "Hindi"
        case .hinglish: "Hinglish"
        }
    }

    static func activationTitle(_ a: VoiceSettings.Activation) -> String {
        switch a {
        case .button: "Tap the orb"
        case .holdToTalk: "Hold to talk"
        case .wakeWordInSession: "Say \"ZORO\" in a session"
        }
    }

    // MARK: Appearance

    private var appearance: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroSectionHeader("Appearance")
            ZoroCard {
                HStack(spacing: ZoroSpace.s.value) {
                    ForEach(AppearancePreference.allCases, id: \.self) { option in
                        ZoroChip(option.title, isSelected: model.appearance == option) { model.setAppearance(option) }
                    }
                }
            }
        }
    }

    // MARK: Model routes

    private var routes: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroSectionHeader("Model routes", detail: "Which model answers each kind of task, and where it runs. Set in config/models.yaml on your server.")
            PhaseView(phase: model.routesPhase, loadingMessage: "Loading model routes.", emptyMessage: model.routesEmptyMessage, retry: { await model.loadRoutes() }) {
                ZoroCard {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.routes.enumerated()), id: \.element.task) { index, route in
                            if index > 0 { RowDivider() }
                            InfoRow(SystemFormat.sentenceCase(route.task.rawValue.replacingOccurrences(of: "_", with: " ")), detail: routeDetail(route)) {
                                if let locality = route.locality { StatusPill(Self.localityTitle(locality), role: locality == .external ? .attention : .privateMode) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func routeDetail(_ route: ModelRouteInfo) -> String {
        var parts: [String] = []
        if let active = route.activeModel { parts.append("Using \(active)") } else { parts.append("No model available") }
        if route.models.count > 1 { parts.append("Fallbacks: \(route.models.filter { $0 != route.activeModel }.joined(separator: ", "))") }
        if !route.reason.isEmpty { parts.append(route.reason) }
        return parts.joined(separator: ". ") + "."
    }

    static func localityTitle(_ l: Locality) -> String {
        switch l {
        case .onDevice: "On this device"
        case .local: "On your server"
        case .privateNetwork: "Private network"
        case .external: "Cloud"
        }
    }
}
