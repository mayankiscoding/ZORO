import SwiftUI
import ZoroCore
import ZoroDesign

/// The approval sheet: title and risk, ZORO's sentence over the rekha with the exact facts below,
/// a live expiry countdown, then Approve (with Face ID / Touch ID when required) and Decline.
public struct ApprovalSheetView: View {
    let model: ApprovalSheetModel
    let onApprove: () -> Void
    let onDecline: () -> Void
    let onClose: () -> Void
    /// Fixed time for snapshots (then nothing scrolls, since ImageRenderer draws no scroll views); nil = live clock.
    let fixedNow: Date?

    public init(model: ApprovalSheetModel, now: Date? = nil, onApprove: @escaping () -> Void, onDecline: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.model = model
        self.fixedNow = now
        self.onApprove = onApprove
        self.onDecline = onDecline
        self.onClose = onClose
    }

    public var body: some View {
        SnapshotSafeScroll(scrolls: fixedNow == nil) {
            VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
                header
                if let fixedNow {
                    content(now: fixedNow)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in content(now: context.date) }
                }
            }
            .padding(ZoroSpace.l.value)
        }
        .background(ZoroNeutral.background)
        .zoroHaptic(.attention, trigger: model.id)
        .zoroHaptic(.approved, trigger: model.phase == .approved || model.phase == .authenticating)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.request.title).zoroText(.heading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: ZoroSpace.s.value)
                RiskBadgeView(model: model.risk)
            }
            if let agent = model.request.agent {
                Text("Asked by \(AgentCatalog.name(agent))").zoroText(.caption).foregroundStyle(.secondary)
            }
            if let tainted = model.taintedLine {
                Label(tainted, systemImage: "exclamationmark.triangle")
                    .zoroText(.detail)
                    .foregroundStyle(ZoroRole.attention.style)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.notice {
                Text(notice).zoroText(.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch model.phase {
        case .reviewing:
            ApprovalSummaryBlock(model.summary, now: now, biometricName: model.biometricName, onApprove: onApprove, onDecline: onDecline)
        case .authenticating, .approved:
            ZoroStateView(.loading, message: model.requiresBiometric ? "Approved. Confirm with \(model.biometricName) to send." : "Approved. Sending now.")
        case .declined:
            ZoroStateView(.empty, message: "Declined. Nothing was sent.", action: ZoroStateAction("Close", perform: onClose))
        case .expired:
            ZoroStateView(.error, message: "Expired. Ask again to approve.", action: ZoroStateAction("Close", perform: onClose))
        }
    }
}

/// Confirmation for a device action flagged `requires_user_confirmation`.
public struct DeviceActionConfirmationView: View {
    let content: DeviceActionSheetContent
    let onConfirm: () -> Void
    let onDecline: () -> Void

    public init(content: DeviceActionSheetContent, onConfirm: @escaping () -> Void, onDecline: @escaping () -> Void) {
        self.content = content
        self.onConfirm = onConfirm
        self.onDecline = onDecline
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
            RekhaStage {
                HStack(alignment: .firstTextBaseline) {
                    Text("Run \"\(content.title)\" on this device?").zoroText(.zoroVoice).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: ZoroSpace.s.value)
                    RiskBadgeView(model: content.risk)
                }
            } owner: {
                VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                    ForEach(content.rows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label).zoroText(.detail).foregroundStyle(.secondary)
                            Spacer(minLength: ZoroSpace.m.value)
                            Text(row.value).zoroText(.body).multilineTextAlignment(.trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            VStack(spacing: ZoroSpace.s.value) {
                Button("Run", action: onConfirm).buttonStyle(.zoroPrimary)
                Button("Decline", action: onDecline).buttonStyle(ZoroSecondaryButtonStyle(role: .critical))
            }
        }
        .padding(ZoroSpace.xl.value)
        .background(ZoroNeutral.background)
    }
}
