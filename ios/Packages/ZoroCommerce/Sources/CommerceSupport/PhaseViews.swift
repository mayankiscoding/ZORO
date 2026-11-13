import SwiftUI
import ZoroDesign

/// Renders the non-content phases of a screen with `ZoroStateView`: loading, empty (an invitation to
/// act), error and disconnected, each with one sentence and one action.
public struct PhaseStateView: View {
    let phase: ScreenPhase
    let loadingMessage: String
    let emptyMessage: String
    let emptyAction: ZoroStateAction?
    let retry: () -> Void

    public init(_ phase: ScreenPhase, loading: String, empty: String, emptyAction: ZoroStateAction? = nil,
                retry: @escaping () -> Void) {
        self.phase = phase
        self.loadingMessage = loading
        self.emptyMessage = empty
        self.emptyAction = emptyAction
        self.retry = retry
    }

    public var body: some View {
        switch phase {
        case .idle, .loading:
            ZoroStateView(.loading, message: loadingMessage)
        case .empty:
            ZoroStateView(.empty, message: emptyMessage, action: emptyAction)
        case .failed(let failure):
            ZoroStateView(failure.kind == .disconnected ? .disconnected : .error, message: failure.message,
                          action: failure.retryable ? ZoroStateAction(failure.kind == .disconnected ? "Reconnect" : "Try again", perform: retry) : nil)
        case .loaded:
            EmptyView()
        }
    }
}

/// A label and a right-aligned figure, combined for VoiceOver.
public struct FigureRow: View {
    let label: String
    let value: String
    let role: ZoroRole?

    public init(_ label: String, value: String, role: ZoroRole? = nil) {
        self.label = label
        self.value = value
        self.role = role
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).zoroText(.body)
            Spacer(minLength: ZoroSpace.s.value)
            Text(value)
                .zoroText(.amount)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(role.map { AnyShapeStyle($0.style) } ?? AnyShapeStyle(.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A one-line notice under an action ("Added to your basket.").
public struct NoticeLine: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Label(text, systemImage: "info.circle")
            .zoroText(.detail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
