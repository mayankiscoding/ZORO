import SwiftUI

/// Shows the current privacy mode, at the top of the ZORO tab and in You > Security and privacy.
public struct PrivacyModeBanner: View {
    let mode: ZoroPrivacyMode
    let actionTitle: String?
    let action: (() -> Void)?

    public init(_ mode: ZoroPrivacyMode, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.mode = mode
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        let isPrivate = mode == .strictPrivate
        HStack(alignment: .center, spacing: ZoroSpace.m.value) {
            ZStack {
                Circle().stroke(isPrivate ? AnyShapeStyle(.moonstone) : AnyShapeStyle(.mor), lineWidth: 1.5)
                Image(systemName: isPrivate ? "lock.fill" : "cloud")
                    .imageScale(.small)
                    .foregroundStyle(isPrivate ? AnyShapeStyle(.moonstone) : AnyShapeStyle(.mor))
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(mode.title).font(.subheadline.weight(.semibold))
                Text(mode.explanation).zoroText(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: ZoroSpace.s.value)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.zoroLink)
            }
        }
        .padding(.vertical, ZoroSpace.s.value)
        .padding(.horizontal, ZoroSpace.m.value)
        .background(ZoroNeutral.raised, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Exactly what will happen, before the owner approves. ZORO's sentence stands on the rekha; the
/// facts hang below it. Approve and Decline keep these names through the whole flow.
public struct ApprovalSummaryBlock: View {
    let summary: ApprovalSummary
    let now: Date
    let biometricName: String
    let onApprove: () -> Void
    let onDecline: () -> Void

    /// - Parameter biometricName: "Face ID" on iPhone, "Touch ID" on Mac (from the LAContext the app uses).
    public init(
        _ summary: ApprovalSummary, now: Date = Date(), biometricName: String = "Face ID",
        onApprove: @escaping () -> Void, onDecline: @escaping () -> Void
    ) {
        self.summary = summary
        self.now = now
        self.biometricName = biometricName
        self.onApprove = onApprove
        self.onDecline = onDecline
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
            RekhaStage {
                VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                    ZoroVoiceText(summary.action).fixedSize(horizontal: false, vertical: true)
                    if let amount = summary.amount {
                        MoneyText(amount, style: .exact, textStyle: .amountHero)
                    }
                }
            } owner: {
                VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                    ForEach(summary.details) { detail in
                        HStack(alignment: .firstTextBaseline) {
                            Text(detail.label).zoroText(.detail).foregroundStyle(.secondary)
                            Spacer(minLength: ZoroSpace.m.value)
                            Text(detail.value).zoroText(.body).multilineTextAlignment(.trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let note = summary.handoffNote {
                        Label(note, systemImage: "arrow.up.forward.app")
                            .zoroText(.detail).foregroundStyle(.secondary)
                    }
                    if let expiry = summary.expiryText(now: now) {
                        Label(expiry, systemImage: "timer").zoroText(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(spacing: ZoroSpace.s.value) {
                Button(action: onApprove) {
                    if summary.level == .biometric {
                        Label("Approve with \(biometricName)", systemImage: biometricName == "Touch ID" ? "touchid" : "faceid")
                    } else {
                        Text("Approve")
                    }
                }
                .buttonStyle(.zoroPrimary)
                Button("Decline", action: onDecline).buttonStyle(ZoroSecondaryButtonStyle(role: .critical))
            }
        }
        .padding(ZoroSpace.xl.value)
        .background(ZoroNeutral.raised, in: ZoroRadius.sheet.shape)
    }
}
