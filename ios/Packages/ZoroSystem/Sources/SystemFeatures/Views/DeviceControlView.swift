import SwiftUI
import ZoroCore
import ZoroDesign

/// Devices, quick actions that run on this device, and what iOS doesn't allow.
public struct DeviceControlView: View {
    @Bindable var model: DeviceControlViewModel

    public init(model: DeviceControlViewModel) { self.model = model }

    public var body: some View {
        ScreenScroll {
            Text("Device control").zoroText(.title).accessibilityAddTraits(.isHeader)
            Text("Your paired devices and a few things ZORO can do on this one with a tap.")
                .zoroText(.detail).foregroundStyle(.secondary)
            NoticeBanner(notice: model.notice, dismiss: model.dismissNotice)
            if model.killSwitchOn {
                NoticeBanner(notice: .failure(SystemCopy.killSwitchOn), dismiss: {})
            }
            PhaseView(
                phase: model.phase, loadingMessage: "Loading your devices.", emptyMessage: model.emptyMessage,
                retry: { await model.load() }
            ) {
                devices
            }
            if !model.quickActions.isEmpty { quickActions }
            restricted
        }
        .navigationTitle("Device control")
        .systemInlineTitle()
        .task { if model.phase == .idle { await model.load() } }
        .refreshable { await model.load() }
        .confirmationDialog(
            model.pendingConfirmation?.title ?? "Run this action?",
            isPresented: Binding(get: { model.pendingConfirmation != nil }, set: { if !$0 { model.cancelPending() } }),
            titleVisibility: .visible
        ) {
            Button(model.pendingConfirmation?.title ?? "Run") { Task { await model.confirmPending() } }
            Button("Cancel", role: .cancel) { model.cancelPending() }
        } message: {
            Text("This changes something on this device. Run it now?")
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroSectionHeader("Devices")
            ZoroCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { RowDivider() }
                        InfoRow(row.info.name + (row.isThisDevice ? " (this device)" : ""), detail: "\(row.platformLabel). \(row.statusText())", symbol: row.symbol) {
                            StatusPill(row.info.online ? "Online" : "Offline", role: row.info.online ? .positive : nil)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroSectionHeader("Quick actions", detail: "These run on this device only. Anything riskier goes through ZORO so it can ask for your approval.")
            ZoroCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.quickActions.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { RowDivider() }
                        VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                            InfoRow(row.action.title, detail: row.unavailableReason ?? row.action.detail, symbol: row.action.symbol) {
                                RiskBadge(risk: row.action.risk)
                            }
                            Button(model.runningActionId == row.id ? "Running" : "Run") { Task { await model.run(row.action) } }
                                .buttonStyle(.zoroSecondary)
                                .disabled(!row.isAvailable || model.runningActionId != nil)
                                .accessibilityLabel("Run \(row.action.title)")
                        }
                        .padding(.vertical, ZoroSpace.xs.value)
                    }
                }
            }
        }
    }

    private var restricted: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroSectionHeader("What ZORO won't do", detail: "iOS and ZORO's own rules. These aren't hidden or faked.")
            ZoroCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.restricted.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { RowDivider() }
                        InfoRow(item.title, detail: item.explanation, symbol: "nosign")
                            .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}
