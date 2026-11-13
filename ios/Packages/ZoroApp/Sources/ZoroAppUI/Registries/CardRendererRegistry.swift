import SwiftUI
import ZoroCore
import ZoroDesign

/// Maps `UICard.kind` to a view. Feature packages register renderers for their kinds; anything else
/// is drawn by the generic renderer (title and key-value rows), so a new card kind from a newer server
/// is still readable.
@MainActor
public final class CardRendererRegistry {
    public typealias Builder = @MainActor (UICard) -> AnyView

    private var builders: [String: Builder] = [:]

    public init() {}

    public func register<Content: View>(kind: String, @ViewBuilder content: @escaping @MainActor (UICard) -> Content) {
        builders[kind] = { AnyView(content($0)) }
    }

    public func unregister(kind: String) { builders[kind] = nil }

    public func hasRenderer(for kind: String) -> Bool { builders[kind] != nil }

    public func view(for card: UICard) -> AnyView {
        if let builder = builders[card.kind] { return builder(card) }
        return AnyView(GenericCardView(model: GenericCardModel(card)))
    }
}

/// The fallback's display model: the title and the payload's scalar fields as rows, in a stable order.
/// Values are shown exactly as sent (money arrives as decimal strings and stays that way).
public struct GenericCardModel: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }
    }

    public static let maxRows = 12

    public var title: String
    public var rows: [Row]
    /// How many fields were not shown (nested data or past `maxRows`).
    public var hiddenCount: Int

    public init(_ card: UICard) {
        let explicitTitle = card.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let payloadTitle = card.payload["title"]?.stringValue
        title = (explicitTitle?.isEmpty == false ? explicitTitle : payloadTitle) ?? Self.humanise(card.kind)
        var rows: [Row] = []
        var hidden = 0
        for key in card.payload.keys.sorted() where key != "title" {
            guard let value = Self.display(card.payload[key]!) else {
                hidden += 1
                continue
            }
            if rows.count < Self.maxRows {
                rows.append(Row(label: Self.humanise(key), value: value))
            } else {
                hidden += 1
            }
        }
        self.rows = rows
        self.hiddenCount = hidden
    }

    /// "delivery_fee" → "Delivery fee", "unitPrice" → "Unit price".
    public static func humanise(_ key: String) -> String {
        var words: [String] = []
        var current = ""
        for ch in key {
            if ch == "_" || ch == "-" || ch == "." || ch == " " {
                if !current.isEmpty { words.append(current); current = "" }
            } else if ch.isUppercase, !current.isEmpty, current.last?.isUppercase == false {
                words.append(current)
                current = String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        let sentence = words.map { $0.lowercased() }.joined(separator: " ")
        guard let first = sentence.first else { return key }
        return first.uppercased() + sentence.dropFirst()
    }

    /// Scalars become text; short lists of scalars are joined; objects and nulls are hidden.
    static func display(_ value: JSONValue) -> String? {
        switch value {
        case .null, .object: return nil
        case .string(let s): return s.isEmpty ? nil : s
        case .bool(let b): return b ? "Yes" : "No"
        case .number(let n):
            if let i = Int(exactly: n) { return String(i) }
            return String(n)
        case .array(let items):
            let scalars = items.compactMap { item -> String? in
                if case .object = item { return nil }
                if case .array = item { return nil }
                return display(item)
            }
            guard !scalars.isEmpty, scalars.count == items.count else {
                return items.isEmpty ? nil : (items.count == 1 ? "1 item" : "\(items.count) items")
            }
            return ListFormatter.localizedString(byJoining: scalars)
        }
    }
}

/// Title and key-value rows in one card.
public struct GenericCardView: View {
    let model: GenericCardModel
    public init(model: GenericCardModel) { self.model = model }

    public var body: some View {
        ZoroCard {
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                Text(model.title).zoroText(.heading)
                ForEach(model.rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label).zoroText(.detail).foregroundStyle(.secondary)
                        Spacer(minLength: ZoroSpace.m.value)
                        Text(row.value).zoroText(.body).multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
                if model.hiddenCount > 0 {
                    Text(model.hiddenCount == 1 ? "1 more detail isn't shown here." : "\(model.hiddenCount) more details aren't shown here.")
                        .zoroText(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
