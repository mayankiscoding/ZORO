import SwiftUI
import ZoroCore
import ZoroDesign

/// The orb as a control: tap to talk, with the button trait VoiceOver needs.
struct OrbControl: View {
    let state: OrbState
    let level: Double
    let satellites: [OrbSatellite]
    let hint: String
    let action: () -> Void

    var body: some View {
        OrbView(state: state, level: level, satellites: satellites)
            .contentShape(Circle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(hint)
            .accessibilityAction(.default, action)
    }

    static func hint(for state: OrbState) -> String {
        switch state {
        case .listening: "Stops listening."
        case .processing, .delegating, .toolExecution, .speaking: "Stops ZORO."
        default: "Starts listening."
        }
    }
}

/// The current exchange on the rekha: ZORO's words stand on it in New York, the owner's hang below.
struct ExchangeStage: View {
    let zoroText: String?
    let ownerText: String?
    let isStreaming: Bool

    var body: some View {
        RekhaStage {
            if let zoroText {
                Text(zoroText + (isStreaming ? " …" : ""))
                    .zoroText(.zoroVoice)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityLabel("ZORO: \(zoroText)")
            }
        } owner: {
            if let ownerText {
                Text(ownerText)
                    .zoroText(.ownerVoice)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("You: \(ownerText)")
            }
        }
    }
}

/// Who is working, one capsule per agent.
struct AgentChipsRow: View {
    let agents: [ZoroDesign.AgentActivity]

    var body: some View {
        if !agents.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ZoroSpace.s.value) {
                    ForEach(agents) { agent in
                        AgentBadge(name: agent.agentName, symbol: agent.symbol, status: agent.status)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Agents")
        }
    }
}

/// Risk in words with a role tint (ZoroDesign's capsule label).
struct RiskBadgeView: View {
    let model: RiskBadgeModel

    var body: some View {
        ZoroCapsuleLabel(text: model.label, role: model.role)
    }
}

/// A Home problem as a design-system state view.
struct IssueView: View {
    let issue: HomeIssue
    let perform: (HomeIssue.Action) -> Void

    var body: some View {
        ZoroStateView(
            issue.kind == .disconnected ? .disconnected : .error,
            message: issue.message,
            action: zip(issue.actionTitle, issue.action).map { title, action in ZoroStateAction(title) { perform(action) } })
            .background(ZoroNeutral.raised, in: ZoroRadius.card.shape)
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

/// The purpose sentence shown before a system permission prompt.
struct PermissionPrimingCard: View {
    let permission: AppPermission
    let onContinue: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZoroCard {
            VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                Label(permission.title, systemImage: permission.symbol).zoroText(.heading)
                Text(permission.purpose).zoroText(.body).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: ZoroSpace.l.value) {
                    Button("Continue", action: onContinue).buttonStyle(.zoroPrimary).frame(maxWidth: 220)
                    Button("Not now", action: onDismiss).buttonStyle(.zoroLink)
                }
            }
        }
    }
}

/// Wraps content in a scroll view, except in offscreen snapshots (ImageRenderer draws no scroll views).
struct SnapshotSafeScroll<Content: View>: View {
    let scrolls: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if scrolls {
            ScrollView { content }
        } else {
            VStack(spacing: 0) {
                content
                Spacer(minLength: 0)
            }
        }
    }
}

/// The text composer for silent use.
struct Composer: View {
    @Binding var text: String
    let canSend: Bool
    var isSnapshot = false
    let onSend: () -> Void
    let onVoice: () -> Void

    var body: some View {
        HStack(spacing: ZoroSpace.s.value) {
            Group {
                if isSnapshot {
                    // ImageRenderer cannot draw text fields; the placeholder stands in.
                    Text("Type to ZORO").foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Type to ZORO", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                        .onSubmit { if canSend { onSend() } }
                }
            }
                .zoroText(.body)
                .padding(.vertical, ZoroSpace.m.value)
                .padding(.leading, ZoroSpace.l.value)
            let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button(action: empty ? onVoice : onSend) {
                Image(systemName: empty ? "waveform" : "arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .foregroundStyle(Color.white)
                    .background(Circle().fill(.neel))
            }
            .buttonStyle(.plain)
            .disabled(!empty && !canSend)
            .opacity(!empty && !canSend ? 0.4 : 1)
            .accessibilityLabel(empty ? "Live voice" : "Send")
            .padding(.trailing, ZoroSpace.s.value)
        }
        .background(ZoroNeutral.raised, in: ZoroRadius.sheet.shape)
    }
}
