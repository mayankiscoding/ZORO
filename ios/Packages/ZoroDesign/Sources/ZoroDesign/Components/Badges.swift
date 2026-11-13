import SwiftUI

/// Small capsule label with a role tint. Sentence case, never all caps. Colour is never the only
/// signal: the text says what the tint means.
public struct ZoroCapsuleLabel: View {
    let text: String
    let symbol: String?
    let role: ZoroRole?

    /// `role` nil = neutral (secondary text on the inset fill).
    public init(text: String, symbol: String? = nil, role: ZoroRole? = nil) {
        self.text = text
        self.symbol = symbol
        self.role = role
    }

    @Environment(\.colorScheme) private var scheme

    public var body: some View {
        let tint: Color = role.map { $0.hue.color(scheme: scheme, contrast: .increased) } ?? .secondary
        HStack(spacing: ZoroSpace.xs.value) {
            if let symbol { Image(systemName: symbol).imageScale(.small).accessibilityHidden(true) }
            Text(text)
        }
        .zoroText(.caption)
        .foregroundStyle(tint)
        .padding(.vertical, 3)
        .padding(.horizontal, ZoroSpace.s.value)
        .background(Capsule().fill(role.map { AnyShapeStyle($0.style.opacity(0.14)) } ?? AnyShapeStyle(ZoroNeutral.inset)))
    }
}

/// How sure ZORO is about a product match or an answer.
public struct ConfidenceBadge: View {
    let level: ConfidenceLevel
    public init(_ level: ConfidenceLevel) { self.level = level }
    public init(score: Double) { level = ConfidenceLevel(score: score) }

    public var body: some View {
        ZoroCapsuleLabel(text: level.label, symbol: nil, role: level.role)
    }
}

/// Agent name and status in a capsule, for cards and the live voice screen.
public struct AgentBadge: View {
    let name: String
    let symbol: String
    let status: AgentActivityStatus

    public init(name: String, symbol: String, status: AgentActivityStatus) {
        self.name = name
        self.symbol = symbol
        self.status = status
    }

    public var body: some View {
        ZoroCapsuleLabel(text: name, symbol: symbol, role: status.role)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), \(status.label)")
    }
}

/// One agent in the Activity list or the live voice screen.
public struct AgentActivityRow: View {
    let activity: AgentActivity
    public init(_ activity: AgentActivity) { self.activity = activity }

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 32

    public var body: some View {
        HStack(alignment: .top, spacing: ZoroSpace.m.value) {
            Image(systemName: activity.symbol)
                .font(.body)
                .foregroundStyle(.neel)
                .frame(width: iconSize, height: iconSize)
                .background(Circle().fill(ZoroNeutral.inset))
                .overlay {
                    if activity.status == .working {
                        Circle().stroke(.mor, lineWidth: 1.5)
                    }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
                HStack(alignment: .firstTextBaseline) {
                    Text(activity.agentName).font(.body.weight(.semibold))
                    Spacer(minLength: ZoroSpace.s.value)
                    ZoroCapsuleLabel(text: activity.status.label, symbol: nil, role: activity.status.role)
                }
                if let detail = activity.detail {
                    Text(detail).zoroText(.detail).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, ZoroSpace.s.value)
        .accessibilityElement(children: .combine)
    }
}

/// A rupee amount: SF Pro Expanded, monospaced digits, Indian grouping, exact `Decimal`.
public struct MoneyText: View {
    let amount: Decimal
    let style: ZoroMoney.Style
    let textStyle: ZoroTextStyle

    public init(_ amount: Decimal, style: ZoroMoney.Style = .exact, textStyle: ZoroTextStyle = .amount) {
        self.amount = amount
        self.style = style
        self.textStyle = textStyle
    }

    public var body: some View {
        Text(ZoroMoney.format(amount, style: style))
            .zoroText(textStyle)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
