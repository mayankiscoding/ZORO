import SwiftUI

/// A raised surface for grouped content. System fill, continuous corners, no shadow.
public struct ZoroCard<Content: View>: View {
    let content: Content
    @ScaledMetric(relativeTo: .body) private var padding: CGFloat = ZoroSpace.l.value

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ZoroNeutral.raised, in: ZoroRadius.card.shape)
    }
}

/// Section header. The title hangs from a hairline, the rekha's quiet echo on every screen.
public struct ZoroSectionHeader: View {
    let title: String
    let detail: String?
    let actionTitle: String?
    let action: (() -> Void)?

    public init(_ title: String, detail: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
            Rectangle().fill(ZoroNeutral.hairline).frame(height: ZoroStroke.hairline).accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                Text(title).zoroText(.heading).accessibilityAddTraits(.isHeader)
                Spacer(minLength: ZoroSpace.s.value)
                if let actionTitle, let action {
                    Button(actionTitle, action: action).buttonStyle(.zoroLink)
                }
            }
            if let detail {
                Text(detail).zoroText(.detail).foregroundStyle(.secondary)
            }
        }
    }
}

/// A compact filter or suggestion. Capsule; filled with neel when selected.
public struct ZoroChip: View {
    let title: String
    let symbol: String?
    let isSelected: Bool
    let action: () -> Void

    public init(_ title: String, symbol: String? = nil, isSelected: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.isSelected = isSelected
        self.action = action
    }

    @ScaledMetric(relativeTo: .subheadline) private var vPad: CGFloat = 7
    @ScaledMetric(relativeTo: .subheadline) private var hPad: CGFloat = 12

    public var body: some View {
        Button(action: action) {
            HStack(spacing: ZoroSpace.xs.value) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(title)
            }
            .zoroText(.detail)
            .padding(.vertical, vPad)
            .padding(.horizontal, hPad)
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .background {
                if isSelected { Capsule().fill(.neel) } else { Capsule().fill(ZoroNeutral.inset) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .zoroAnimation(.quick, value: isSelected)
    }
}

/// Filled button for the one main action on a screen: white on neel (tested ≥ 4.5:1 in both schemes).
/// Other roles pick white or black labels by measured contrast.
public struct ZoroPrimaryButtonStyle: ButtonStyle {
    let role: ZoroRole
    public init(role: ZoroRole = .accent) { self.role = role }

    public func makeBody(configuration: Configuration) -> some View {
        ZoroButtonBody(configuration: configuration, filled: true, role: role)
    }
}

/// Quiet button: system fill with a role-coloured label.
public struct ZoroSecondaryButtonStyle: ButtonStyle {
    let role: ZoroRole
    public init(role: ZoroRole = .accent) { self.role = role }

    public func makeBody(configuration: Configuration) -> some View {
        ZoroButtonBody(configuration: configuration, filled: false, role: role)
    }
}

/// Inline text action ("Change", "See all"). Uses the text-safe variant of the role's hue.
public struct ZoroLinkButtonStyle: ButtonStyle {
    let role: ZoroRole
    public init(role: ZoroRole = .accent) { self.role = role }

    public func makeBody(configuration: Configuration) -> some View {
        ZoroLinkBody(configuration: configuration, role: role)
    }
}

private struct ZoroLinkBody: View {
    let configuration: ButtonStyleConfiguration
    let role: ZoroRole
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(role.hue.color(scheme: scheme, contrast: role.hue.isTextSafeAtStandardContrast ? .standard : .increased))
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == ZoroLinkButtonStyle {
    public static var zoroLink: ZoroLinkButtonStyle { ZoroLinkButtonStyle() }
}

extension ButtonStyle where Self == ZoroPrimaryButtonStyle {
    public static var zoroPrimary: ZoroPrimaryButtonStyle { ZoroPrimaryButtonStyle() }
}

extension ButtonStyle where Self == ZoroSecondaryButtonStyle {
    public static var zoroSecondary: ZoroSecondaryButtonStyle { ZoroSecondaryButtonStyle() }
}

private struct ZoroButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let filled: Bool
    let role: ZoroRole

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var minHeight: CGFloat = 50

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.body.weight(.semibold))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, ZoroSpace.l.value)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .foregroundStyle(filled ? AnyShapeStyle(role.hue.labelOnFill(scheme: scheme, highContrast: contrast == .increased).color) : AnyShapeStyle(labelStyle))
            .background(filled ? AnyShapeStyle(role.style) : AnyShapeStyle(ZoroNeutral.inset), in: ZoroRadius.control.shape)
            .opacity(isEnabled ? (pressed ? 0.82 : 1) : 0.4)
            .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
            .animation(ZoroMotion.quick.animation(reduceMotion: reduceMotion), value: pressed)
            .contentShape(ZoroRadius.control.shape)
    }

    /// Secondary labels use the Increase Contrast variant when the standard hue is not text-safe.
    private var labelStyle: Color {
        role.hue.color(scheme: scheme, contrast: role.hue.isTextSafeAtStandardContrast ? .standard : .increased)
    }
}
