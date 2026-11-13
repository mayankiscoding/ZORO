import CommerceSupport
import SwiftUI
import ZoroCore
import ZoroDesign

// MARK: - Record a price

struct RecordPriceView: View {
    @State var model: RecordPriceViewModel
    let items: [BasketItemView]
    @State private var stores = [ProviderInfo]()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Type a price you saw in a store's app or on a shelf. ZORO keeps it as your own note with the time you saw it.")
                        .zoroText(.detail).foregroundStyle(.secondary)
                }
                Picker("Store", selection: $model.providerId) {
                    Text("Choose a store").tag("")
                    ForEach(stores) { Text($0.title).tag($0.id) }
                }
                Picker("What it is", selection: $model.kind) {
                    ForEach(RecordPriceViewModel.kinds, id: \.id) { Text($0.title).tag($0.id) }
                }
                if model.kind == "item" {
                    Picker("Basket item", selection: $model.itemId) {
                        Text("Choose an item").tag(String?.none)
                        ForEach(items) { Text($0.name).tag(Optional($0.itemId)) }
                    }
                }
                TextField("Price in rupees", text: $model.priceText)
                    .accessibilityHint("For example 49.50")
                DatePicker("When you saw it", selection: $model.seenAt, in: ...Date())
                TextField("Note (optional)", text: $model.label)
                if let message = model.message { NoticeLine(message) }
                Button("Save price") { Task { await model.save() } }
                    .buttonStyle(.zoroPrimary)
                    .disabled(model.isSaving || model.validationMessage != nil)
                if let v = model.validationMessage { Text(v).zoroText(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("Record a price")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                let vm = StoresViewModel(client: model.client)
                await vm.load()
                stores = vm.providers
            }
        }
        .frame(minWidth: 360, minHeight: 480)
    }
}

// MARK: - Stores and shortlist

struct StoresSection: View {
    let model: StoresViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            ZoroSectionHeader("Stores", detail: "What ZORO can do with each store")
            if model.phase == .loaded {
                ForEach(model.providers) { provider in
                    ZoroCard {
                        VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                            Text(provider.title).zoroText(.heading)
                            if !provider.note.isEmpty { Text(provider.note).zoroText(.detail).foregroundStyle(.secondary) }
                            ForEach(provider.methods, id: \.self) { m in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(StoresViewModel.methodTitle(m.method)).zoroText(.body)
                                    Spacer()
                                    ZoroCapsuleLabel(text: m.level.label, role: role(m.level))
                                }
                                .accessibilityElement(children: .combine)
                            }
                            if let h = provider.handoff, let raw = h.url, let url = URL(string: raw) {
                                Button(h.title) { openURL(url) }.buttonStyle(.zoroLink)
                            }
                        }
                    }
                }
            } else {
                PhaseStateView(model.phase, loading: "Loading stores.",
                               empty: "No stores are set up on your ZORO server. Add one in its shopping settings, then come back.") {
                    Task { await model.load() }
                }
            }

            ZoroSectionHeader("Shortlist", detail: "Products you saved to think about")
            if model.shortlistPhase == .loaded {
                ZoroCard {
                    VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                        ForEach(model.shortlist) { entry in
                            VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(entry.name).font(.body.weight(.semibold))
                                    Spacer()
                                    Text(Figures.money(entry.price, style: .compact, unknown: "No price")).zoroText(.amount)
                                }
                                if let b = entry.brand { Text(b).zoroText(.detail).foregroundStyle(.secondary) }
                                SourceLine(stamp: SourceStamp(source: ProductMapping.storeName(entry.source), retrievedAt: entry.retrievedAt))
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            } else {
                PhaseStateView(model.shortlistPhase, loading: "Loading your shortlist.",
                               empty: "Nothing saved yet. Open a search result and choose Save to shortlist.") {
                    Task { await model.loadShortlist() }
                }
            }
        }
        .task {
            await model.load()
            await model.loadShortlist()
        }
    }

    private func role(_ level: IntegrationLevel) -> ZoroRole? {
        switch level {
        case .fullyIntegrated, .officialAPI: .positive
        case .affiliateSearch, .deepLinkHandoff, .manualFallback: nil
        case .unavailable: .attention
        }
    }
}
