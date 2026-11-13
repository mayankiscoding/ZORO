import SwiftUI
import ZoroCore
import ZoroDesign

/// Lets a state view offer "Open settings" without every screen knowing how navigation works.
private struct OpenSettingsKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}

extension EnvironmentValues {
    public var systemOpenSettings: (@MainActor @Sendable () -> Void)? {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }
}

enum SystemLayout {
    #if os(macOS)
    static let gutter: CGFloat = 24
    #else
    static let gutter: CGFloat = 16
    #endif
    /// Readable width on Mac and iPad; phones are narrower than this anyway.
    static let maxWidth: CGFloat = 720
}

/// Scrolling screen body: gutter, readable width, system background.
struct ScreenScroll<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoroSpace.xl.value) { content }
                .padding(.horizontal, SystemLayout.gutter)
                .padding(.vertical, ZoroSpace.l.value)
                .frame(maxWidth: SystemLayout.maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(ZoroNeutral.background)
    }
}

/// Shows loading, empty, error or disconnected for a phase, or the content when there is some.
struct PhaseView<Loaded: View>: View {
    let phase: ScreenPhase
    let loadingMessage: String
    let emptyMessage: String
    let retry: @MainActor () async -> Void
    @ViewBuilder let loaded: () -> Loaded
    @Environment(\.systemOpenSettings) private var openSettings

    var body: some View {
        switch phase {
        case .idle, .loading:
            ZoroStateView(.loading, message: loadingMessage)
        case .loaded:
            loaded()
        case .empty:
            ZoroCard { ZoroStateView(.empty, message: emptyMessage) }
        case .failed(let failure):
            ZoroCard {
                ZoroStateView(.error, message: failure.message, action: failure.retryable ? ZoroStateAction("Try again") { Task { await retry() } } : nil)
            }
        case .disconnected(let failure):
            ZoroCard {
                ZoroStateView(.disconnected, message: failure.message, action: disconnectedAction(failure))
            }
        }
    }

    private func disconnectedAction(_ failure: ScreenFailure) -> ZoroStateAction? {
        if failure.retryable { return ZoroStateAction("Try again") { Task { await retry() } } }
        if let openSettings { return ZoroStateAction("Open settings") { openSettings() } }
        return nil
    }
}

/// The result of the last action, inline, in words (colour is never the only signal).
struct NoticeBanner: View {
    let notice: SystemNotice?
    let dismiss: () -> Void

    var body: some View {
        if let notice {
            HStack(alignment: .firstTextBaseline, spacing: ZoroSpace.m.value) {
                Image(systemName: notice.kind == .success ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(notice.kind == .success ? AnyShapeStyle(.mor) : AnyShapeStyle(.lac))
                    .accessibilityHidden(true)
                Text(notice.text).zoroText(.body).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: ZoroSpace.s.value)
                Button("Dismiss", action: dismiss).buttonStyle(.zoroLink)
            }
            .padding(ZoroSpace.m.value)
            .background(ZoroNeutral.raised, in: ZoroRadius.control.shape)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// A row in a grouped card: title and detail on the left, trailing content on the right.
struct InfoRow<Trailing: View>: View {
    let title: String
    let detail: String?
    let symbol: String?
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, detail: String? = nil, symbol: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: ZoroSpace.m.value) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(.neel).frame(width: 24).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
                Text(title).zoroText(.body).fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail).zoroText(.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: ZoroSpace.s.value)
            trailing()
        }
        .padding(.vertical, ZoroSpace.s.value)
    }
}

/// Hairline between rows inside one card.
struct RowDivider: View {
    var body: some View {
        Rectangle().fill(ZoroNeutral.hairline).frame(height: ZoroStroke.hairline).accessibilityHidden(true)
    }
}

/// A short capsule label with words; the tint is secondary to the text.
struct StatusPill: View {
    let text: String
    let role: ZoroRole?
    let symbol: String?
    @Environment(\.colorScheme) private var scheme

    init(_ text: String, role: ZoroRole? = nil, symbol: String? = nil) {
        self.text = text
        self.role = role
        self.symbol = symbol
    }

    var body: some View {
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

/// Risk shown as words and a symbol: "Low risk", "Medium risk", "High risk", "Critical risk".
struct RiskBadge: View {
    let risk: RiskLevel
    var body: some View {
        StatusPill(AuditCopy.riskLabel(risk), role: role, symbol: symbol)
    }

    private var role: ZoroRole? {
        switch risk {
        case .low: nil
        case .medium: .attention
        case .high, .critical: .critical
        }
    }

    private var symbol: String {
        switch risk {
        case .low: "checkmark.shield"
        case .medium: "exclamationmark.shield"
        case .high: "exclamationmark.triangle"
        case .critical: "exclamationmark.octagon"
        }
    }
}

extension PrivacyMode {
    var designMode: ZoroPrivacyMode { self == .strictPrivate ? .strictPrivate : .cloudIntelligence }
}

extension SecurityViewModel {
    var privacyBannerMode: ZoroPrivacyMode? { privacyMode?.designMode }
}

func dateText(_ date: Date) -> String { SystemFormat.dateTime(date) }
