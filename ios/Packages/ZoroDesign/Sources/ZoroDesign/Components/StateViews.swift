import SwiftUI

/// What a section shows when it has nothing to show yet.
public enum ZoroStateKind: String, CaseIterable, Sendable {
    case empty, loading, error, disconnected

    public var symbol: String {
        switch self {
        case .empty: "tray"
        case .loading: "ellipsis"
        case .error: "exclamationmark.triangle"
        case .disconnected: "bolt.horizontal.circle"
        }
    }

    public var role: ZoroRole? {
        switch self {
        case .empty, .loading: nil
        case .error: .critical
        case .disconnected: .attention
        }
    }
}

/// An action offered by a state view. One plain verb phrase: "Try again", "Reconnect".
public struct ZoroStateAction {
    public let title: String
    public let perform: () -> Void
    public init(_ title: String, perform: @escaping () -> Void) {
        self.title = title
        self.perform = perform
    }
}

/// Empty, loading, error and disconnected states. Each takes one plain sentence saying what happened
/// and what to do next, and an optional action. Left-aligned like the content it stands in for.
public struct ZoroStateView: View {
    let kind: ZoroStateKind
    let message: String
    let action: ZoroStateAction?

    public init(_ kind: ZoroStateKind, message: String, action: ZoroStateAction? = nil) {
        self.kind = kind
        self.message = message
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            HStack(alignment: .firstTextBaseline, spacing: ZoroSpace.m.value) {
                Group {
                    if kind == .loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: kind.symbol)
                            .foregroundStyle(kind.role.map { AnyShapeStyle($0.style) } ?? AnyShapeStyle(.secondary))
                    }
                }
                .font(.title3)
                .accessibilityHidden(true)
                Text(message).zoroText(.body).fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(ZoroSecondaryButtonStyle(role: kind == .error ? .critical : .accent))
                    .frame(maxWidth: 280)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ZoroSpace.l.value)
        .accessibilityElement(children: .combine)
    }
}
