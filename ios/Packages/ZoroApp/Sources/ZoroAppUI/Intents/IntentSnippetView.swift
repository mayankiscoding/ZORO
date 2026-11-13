import SwiftUI

/// The view Siri shows under its dialog: ZORO's words (New York, per the design spec) and the first
/// card's summary. Static: approvals and other actions happen in the app, never in a snippet.
public struct IntentSnippetView: View {
    public let snippet: IntentSnippet?

    public nonisolated init(snippet: IntentSnippet?) { self.snippet = snippet }

    public var body: some View {
        if let snippet, !snippet.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !snippet.text.isEmpty {
                    Text(snippet.text)
                        .font(.body)
                        .fontDesign(.serif)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let title = snippet.cardTitle {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.subheadline.weight(.semibold))
                        ForEach(snippet.cardLines, id: \.self) { line in
                            Text(line)
                                .font(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

/// A small tip the app can show (Home, Settings, after first run): "Say: “Hey Siri, ask ZORO …”".
/// Cross-platform; on iPhone the app may show Apple's `SiriTipView` instead (`ZoroSystemSiriTip`).
public struct ZoroSiriTip: View {
    private let language: ZoroLanguage
    private let onDismiss: (() -> Void)?

    public init(language: ZoroLanguage, onDismiss: (() -> Void)? = nil) {
        self.language = language
        self.onDismiss = onDismiss
    }

    public var body: some View {
        let copy = IntentCopy(language)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.siriTip).font(.subheadline.weight(.semibold))
                Text(copy.siriTipDetail).font(.footnote).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(language == .hindi ? "हटाएँ" : "Dismiss")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
