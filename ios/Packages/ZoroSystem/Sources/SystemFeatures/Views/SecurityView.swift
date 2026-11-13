import SwiftUI
import ZoroCore
import ZoroDesign

/// Security and privacy: privacy mode, kill switch, permissions, devices, session.
public struct SecurityView: View {
    let model: SecurityViewModel
    let auditModel: AuditLogViewModel

    public init(model: SecurityViewModel, audit: AuditLogViewModel) {
        self.model = model
        auditModel = audit
    }

    public var body: some View {
        ScreenScroll {
            Text("Security and privacy").zoroText(.title).accessibilityAddTraits(.isHeader)
            NoticeBanner(notice: model.notice, dismiss: model.dismissNotice)
            PhaseView(
                phase: model.phase, loadingMessage: "Loading your security settings.", emptyMessage: model.emptyMessage,
                retry: { await model.load() }
            ) {
                privacy
                killSwitch
                permissions
                devices
                session
                NavigationLink {
                    AuditLogView(model: auditModel)
                } label: {
                    ZoroCard {
                        InfoRow("Audit log", detail: "Every approval, tool run and settings change, in order.", symbol: "list.bullet.rectangle") {
                            Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Security and privacy")
        .systemInlineTitle()
        .task { if model.phase == .idle { await model.load() } }
        .refreshable { await model.load() }
        .confirmationDialog(
            "Turn on cloud intelligence?",
            isPresented: Binding(get: { model.pendingPrivacyChange != nil }, set: { if !$0 { model.cancelPrivacyChange() } }),
            titleVisibility: .visible
        ) {
            Button("Turn on cloud intelligence") { Task { await model.confirmPrivacyChange() } }
            Button("Stay in private mode", role: .cancel) { model.cancelPrivacyChange() }
        } message: {
            Text(PrivacyCopy.loosenSheet + " Your device will ask you to confirm.")
        }
        .confirmationDialog(
            "Remove \(model.pendingRevoke?.name ?? "this device")?",
            isPresented: Binding(get: { model.pendingRevoke != nil }, set: { if !$0 { model.cancelRevoke() } }),
            titleVisibility: .visible
        ) {
            Button("Remove device", role: .destructive) { Task { await model.confirmRevoke() } }
            Button("Keep it", role: .cancel) { model.cancelRevoke() }
        } message: {
            Text(model.pendingRevoke.map { model.isThisDevice($0) } == true
                ? "This device will be signed out of ZORO and must be paired again."
                : "It stops working with ZORO right away and must be paired again.")
        }
    }

    // MARK: Sections

    @ViewBuilder private var privacy: some View {
        if let mode = model.privacyMode {
            VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                ZoroSectionHeader("Privacy mode")
                PrivacyModeBanner(mode.designMode)
                ForEach(PrivacyMode.allCases, id: \.self) { option in
                    Button {
                        Task { await model.requestPrivacyMode(option) }
                    } label: {
                        ZoroCard {
                            HStack(alignment: .top, spacing: ZoroSpace.m.value) {
                                Image(systemName: option == mode ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(option == mode ? AnyShapeStyle(.neel) : AnyShapeStyle(.secondary))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                                    Text(PrivacyCopy.title(option)).zoroText(.body).fontWeight(.semibold)
                                    Text(PrivacyCopy.line(option)).zoroText(.detail)
                                    Text(PrivacyCopy.explanation(option)).zoroText(.detail).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isChangingPrivacy)
                    .accessibilityAddTraits(option == mode ? .isSelected : [])
                }
                Text("Changing the mode asks you to confirm with Face ID, Touch ID or your passcode.")
                    .zoroText(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var killSwitch: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroSectionHeader("Kill switch")
            ZoroCard {
                Toggle(isOn: Binding(get: { model.killSwitchOn }, set: { v in Task { await model.setKillSwitch(v) } })) {
                    InfoRow(
                        model.killSwitchOn ? "ZORO is paused" : "ZORO is running",
                        detail: model.killSwitchOn
                            ? "No tools run and nothing goes to cloud models. Turn this off to continue."
                            : "Turn this on to stop every tool and all cloud use at once.",
                        symbol: "power")
                }
                .disabled(model.isChangingKillSwitch)
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroSectionHeader("Permissions", detail: "What ZORO may do. Each change asks you to confirm.")
            if model.permissions.isEmpty {
                ZoroCard { ZoroStateView(.empty, message: "No permissions are listed. Check that your ZORO server is up to date.") }
            } else {
                if !model.cloudPermissions.isEmpty {
                    Text("Data that may go to cloud models").zoroText(.detail).foregroundStyle(.secondary)
                    permissionCard(model.cloudPermissions)
                }
                if !model.otherPermissions.isEmpty {
                    permissionCard(model.otherPermissions)
                }
            }
        }
    }

    private func permissionCard(_ grants: [PermissionGrant]) -> some View {
        ZoroCard {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(grants.enumerated()), id: \.element.key) { index, grant in
                    if index > 0 { RowDivider() }
                    Toggle(isOn: Binding(get: { grant.granted }, set: { v in Task { await model.setPermission(grant, granted: v) } })) {
                        InfoRow(grant.title, detail: grant.updatedAt.map { "Changed \(dateText($0))" })
                    }
                    .disabled(model.busyPermissionKeys.contains(grant.key))
                }
            }
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroSectionHeader("Your devices")
            ZoroCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { RowDivider() }
                        VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                            InfoRow(row.info.name + (row.isThisDevice ? " (this device)" : ""), detail: "\(row.platformLabel). \(row.statusText())", symbol: row.symbol)
                            Button(model.revokingDeviceId == row.id ? "Removing" : "Remove device") { model.requestRevoke(row.info) }
                                .buttonStyle(ZoroLinkButtonStyle(role: .critical))
                                .disabled(model.revokingDeviceId != nil)
                                .accessibilityLabel("Remove \(row.info.name)")
                        }
                        .padding(.vertical, ZoroSpace.xs.value)
                    }
                    if model.devices.isEmpty { ZoroStateView(.empty, message: "No devices are paired. Pair this device from Settings.") }
                }
            }
            if !model.removedDevices.isEmpty {
                Text("Removed: \(model.removedDevices.map(\.name).joined(separator: ", ")).").zoroText(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var session: some View {
        if let session = model.session {
            VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                ZoroSectionHeader("This session")
                ZoroCard {
                    VStack(alignment: .leading, spacing: 0) {
                        InfoRow(session.expiryText(), detail: "ZORO signs in again by itself. Nothing to do.", symbol: "clock")
                        RowDivider()
                        InfoRow("Approval key", detail: session.keyProtectionText, symbol: "key")
                        RowDivider()
                        InfoRow("Confirming changes", detail: session.biometryText, symbol: "faceid")
                        if let state = model.state {
                            RowDivider()
                            InfoRow(
                                "Face ID for high-risk actions", detail: state.biometricForHighRisk ? "On. High-risk actions always ask for Face ID." : "Off. High-risk actions ask you to confirm; Face ID is added when a turn came from the web.",
                                symbol: "exclamationmark.shield")
                        }
                    }
                }
            }
        }
    }
}

/// The audit log, newest first, with "Show more".
public struct AuditLogView: View {
    @Bindable var model: AuditLogViewModel

    public init(model: AuditLogViewModel) { self.model = model }

    public var body: some View {
        ScreenScroll {
            Text("Audit log").zoroText(.title).accessibilityAddTraits(.isHeader)
            Text("Append-only. Each entry is chained to the one before it, so changes can't be hidden.")
                .zoroText(.detail).foregroundStyle(.secondary)
            PhaseView(
                phase: model.phase, loadingMessage: "Loading the audit log.", emptyMessage: model.emptyMessage,
                retry: { await model.load() }
            ) {
                filters
                if model.visibleRecords.isEmpty {
                    ZoroCard { ZoroStateView(.empty, message: model.emptyMessage) }
                } else {
                    ZoroCard {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(model.visibleRecords.enumerated()), id: \.element.id) { index, record in
                                if index > 0 { RowDivider() }
                                row(record)
                            }
                        }
                    }
                }
                if let failure = model.loadMoreFailure {
                    NoticeBanner(notice: .failure("Loading more didn't happen. \(failure)"), dismiss: {})
                }
                if model.hasMore {
                    Button(model.isLoadingMore ? "Loading" : "Show more") { Task { await model.loadMore() } }
                        .buttonStyle(.zoroSecondary).disabled(model.isLoadingMore)
                }
            }
        }
        .navigationTitle("Audit log")
        .systemInlineTitle()
        .task { if model.phase == .idle { await model.load() } }
        .refreshable { await model.load() }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ZoroSpace.s.value) {
                ZoroChip("All", isSelected: model.decisionFilter == nil) { model.decisionFilter = nil }
                ForEach(AuditDecision.allCases, id: \.self) { decision in
                    ZoroChip(AuditCopy.decisionLabel(decision), isSelected: model.decisionFilter == decision) { model.decisionFilter = decision }
                }
            }
        }
    }

    private func row(_ record: AuditRecord) -> some View {
        VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
            HStack(alignment: .firstTextBaseline) {
                Text(AuditCopy.actionTitle(record.action)).zoroText(.body)
                Spacer(minLength: ZoroSpace.s.value)
                StatusPill(AuditCopy.decisionLabel(record.decision), role: decisionRole(record.decision))
            }
            Text([dateText(record.ts), record.tool, record.actor].compactMap { $0 }.joined(separator: ", "))
                .zoroText(.caption).foregroundStyle(.secondary)
            if !record.detail.isEmpty { Text(record.detail).zoroText(.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let risk = record.risk { RiskBadge(risk: risk) }
        }
        .padding(.vertical, ZoroSpace.m.value)
        .accessibilityElement(children: .combine)
    }

    private func decisionRole(_ decision: AuditDecision) -> ZoroRole? {
        switch decision {
        case .allowed, .approved: .positive
        case .denied, .blocked, .failed: .critical
        case .info: nil
        }
    }
}
