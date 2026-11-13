import SwiftUI
import ZoroCore
import ZoroDesign

/// The capability registry in plain language: what works, what needs you, what iOS doesn't allow.
public struct IntegrationsView: View {
    @Bindable var model: IntegrationsViewModel

    public init(model: IntegrationsViewModel) { self.model = model }

    public var body: some View {
        ScreenScroll {
            Text("Integrations").zoroText(.title).accessibilityAddTraits(.isHeader)
            Text("What ZORO can connect to, and what each connection still needs.")
                .zoroText(.detail).foregroundStyle(.secondary)
            if let note = model.serverNote {
                NoticeBanner(notice: .failure(note), dismiss: {})
            }
            PhaseView(
                phase: model.phase, loadingMessage: "Loading integrations.", emptyMessage: model.emptyMessage,
                retry: { await model.load() }
            ) {
                loaded
            }
        }
        .navigationTitle("Integrations")
        .systemInlineTitle()
        .searchable(text: $model.searchText, prompt: "Search integrations")
        .task { if model.phase == .idle { await model.load() } }
        .refreshable { await model.load() }
    }

    @ViewBuilder private var loaded: some View {
        if !model.summary.isEmpty { Text(model.summary).zoroText(.detail).foregroundStyle(.secondary) }
        if model.domains.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: ZoroSpace.s.value) {
                    ZoroChip("All", isSelected: model.domainFilter == nil) { model.domainFilter = nil }
                    ForEach(model.domains, id: \.self) { domain in
                        ZoroChip(SystemFormat.sentenceCase(domain), isSelected: model.domainFilter == domain) { model.domainFilter = domain }
                    }
                }
            }
        }
        if model.sections.isEmpty {
            ZoroCard { ZoroStateView(.empty, message: model.emptyMessage) }
        }
        ForEach(model.sections) { section in
            VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                ZoroSectionHeader(section.group.title, detail: section.group.explanation)
                ZoroCard {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { RowDivider() }
                            row(item)
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: IntegrationItem) -> some View {
        VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title).zoroText(.body)
                Spacer(minLength: ZoroSpace.s.value)
                StatusPill(IntegrationCopy.statusLabel(item.status), role: pillRole(item.group), symbol: item.group.symbol)
            }
            if let level = item.levelLabel {
                Text(level).zoroText(.caption).foregroundStyle(.secondary)
            }
            if !item.note.isEmpty {
                Text(item.note).zoroText(.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !item.requires.isEmpty {
                Text("Needs: \(item.requires.joined(separator: ", "))").zoroText(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, ZoroSpace.m.value)
        .accessibilityElement(children: .combine)
    }

    private func pillRole(_ group: IntegrationGroup) -> ZoroRole? {
        switch group {
        case .working: .positive
        case .needsTap, .needsCredentials, .needsPartnerAgreement: .attention
        case .notAllowedByIOS: .privateMode
        case .notAvailable: nil
        }
    }
}
