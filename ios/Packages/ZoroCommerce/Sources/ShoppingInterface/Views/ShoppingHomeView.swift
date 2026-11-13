import CommerceSupport
import SwiftUI
import ZoroCore
import ZoroDesign

/// The Shopping space: search, basket, store comparison and stores. Dependencies come from the
/// `\.zoroServices` environment value.
public struct ShoppingHomeView: View {
    @Environment(\.zoroServices) private var services

    public init() {}

    public var body: some View {
        ShoppingSpace(client: ShoppingClient(api: services.api))
    }
}

enum ShoppingSection: String, CaseIterable, Identifiable {
    case search, basket, compare, stores
    var id: String { rawValue }
    var title: String {
        switch self {
        case .search: "Search"
        case .basket: "Basket"
        case .compare: "Compare"
        case .stores: "Stores"
        }
    }
}

struct ShoppingSpace: View {
    let client: ShoppingClient
    @State private var section: ShoppingSection = .search
    @State private var search: ProductSearchViewModel
    @State private var basket: BasketViewModel
    @State private var comparison: ComparisonViewModel
    @State private var stores: StoresViewModel

    init(client: ShoppingClient) {
        self.client = client
        _search = State(initialValue: ProductSearchViewModel(client: client))
        _basket = State(initialValue: BasketViewModel(client: client))
        _comparison = State(initialValue: ComparisonViewModel(client: client))
        _stores = State(initialValue: StoresViewModel(client: client))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
                    Picker("Section", selection: $section) {
                        ForEach(ShoppingSection.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Shopping section")

                    switch section {
                    case .search: ProductSearchSection(model: search)
                    case .basket: BasketSection(model: basket, client: client) { section = .compare }
                    case .compare: ComparisonSection(model: comparison, basket: basket, client: client)
                    case .stores: StoresSection(model: stores)
                    }
                }
                .padding(ZoroSpace.l.value)
                .frame(maxWidth: 960, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(ZoroNeutral.background)
            .navigationTitle("Shopping")
        }
    }
}

// MARK: - Search

struct ProductSearchSection: View {
    @Bindable var model: ProductSearchViewModel
    @State private var selected: ShownProduct?
    private let columns = [GridItem(.adaptive(minimum: 280), spacing: ZoroSpace.m.value, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            HStack(spacing: ZoroSpace.s.value) {
                TextField("Search for a product, like toned milk", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.search() } }
                    .accessibilityLabel("Product search")
                Button("Search") { Task { await model.search() } }
                    .buttonStyle(.zoroSecondary)
                    .fixedSize()
                    .disabled(!model.canSearch)
            }
            if let notice = model.notice { NoticeLine(notice) }

            switch model.phase {
            case .loaded:
                LazyVGrid(columns: columns, alignment: .leading, spacing: ZoroSpace.m.value) {
                    ForEach(model.results) { product in
                        Button { selected = product } label: { ProductResultCell(product: product, titles: model.storeTitles) }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows sizes and adds to your basket")
                    }
                }
                UnavailableStoresNote(items: model.unavailable, titles: model.storeTitles)
            case .idle:
                ZoroStateView(.empty, message: "Search for something you buy, and ZORO checks the stores it can reach.")
            default:
                PhaseStateView(model.phase, loading: "Checking stores for “\(model.query)”.", empty: model.emptyMessage) {
                    Task { await model.search() }
                }
                if model.phase == .empty { UnavailableStoresNote(items: model.unavailable, titles: model.storeTitles) }
            }
        }
        .task { await model.loadStoreTitles() }
        .sheet(item: $selected) { product in
            ProductDetailView(product: product, model: model)
        }
    }
}

struct ProductResultCell: View {
    let product: ShownProduct
    let titles: [String: String]

    var body: some View {
        if let card = ProductMapping.card(product, titles: titles) {
            ProductCardView(card)
        } else {
            ZoroCard {
                VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                    Text(product.name).font(.body.weight(.semibold))
                    Text("Price not reported by \(ProductMapping.storeName(product.source, titles: titles)).")
                        .zoroText(.detail).foregroundStyle(.secondary)
                    SourceLine(stamp: SourceStamp(source: ProductMapping.storeName(product.source, titles: titles),
                                                  retrievedAt: product.retrievedAt))
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct UnavailableStoresNote: View {
    let items: [ProviderUnavailable]
    let titles: [String: String]
    @Environment(\.openURL) private var openURL

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                ZoroSectionHeader("Not searched here")
                ForEach(items, id: \.self) { item in
                    VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                        Text("\(ProductMapping.storeName(item.provider, titles: titles)): \(item.message.isEmpty ? "no official search route." : item.message)")
                            .zoroText(.detail)
                            .fixedSize(horizontal: false, vertical: true)
                        if let handoff = item.handoff, let raw = handoff.url, let url = URL(string: raw) {
                            Button(handoff.title) { openURL(url) }.buttonStyle(.zoroLink)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Product detail

struct ProductDetailView: View {
    let product: ShownProduct
    let model: ProductSearchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var variantId: String
    @State private var quantity = 1
    @State private var substitutions = false

    init(product: ShownProduct, model: ProductSearchViewModel) {
        self.product = product
        self.model = model
        _variantId = State(initialValue: ProductMapping.primaryVariant(product)?.variantId ?? product.variants.first?.variantId ?? "")
    }

    private var variant: VariantOut? { product.variants.first { $0.variantId == variantId } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
                    if let v = variant, let card = ProductMapping.card(product, variant: v, quantity: quantity, titles: model.storeTitles) {
                        ProductCardView(card)
                    } else {
                        Text(product.name).zoroText(.heading)
                        NoticeLine("This size has no price from the store, so it cannot be added. Record a price you saw instead.")
                    }
                    if product.variants.count > 1 {
                        ZoroSectionHeader("Size")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(product.variants, id: \.variantId) { v in
                                    ZoroChip(v.label.isEmpty ? "Standard" : v.label, isSelected: v.variantId == variantId) {
                                        variantId = v.variantId
                                    }
                                }
                            }
                        }
                    }
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...99)
                    Toggle("Allow a close substitute if this is not available", isOn: $substitutions)
                    if let mrp = variant?.mrp, let price = variant?.price, mrp > price {
                        FigureRow("Maximum retail price", value: Figures.money(mrp))
                    }
                    if !product.attributes.isEmpty {
                        ZoroSectionHeader("Details from the store")
                        ForEach(product.attributes.sorted { $0.key < $1.key }, id: \.key) { key, value in
                            FigureRow(StoresViewModel.methodTitle(key), value: value)
                        }
                    }
                    if let notice = model.notice { NoticeLine(notice) }
                    Button("Add to basket") {
                        guard let v = variant else { return }
                        Task { await model.add(product, variant: v, quantity: quantity, substitutionsAllowed: substitutions) }
                    }
                    .buttonStyle(.zoroPrimary)
                    .disabled(variant?.price == nil || model.isWorking)
                    Button("Save to shortlist") { Task { await model.shortlist(product) } }
                        .buttonStyle(.zoroLink)
                        .disabled(model.isWorking)
                }
                .padding(ZoroSpace.l.value)
            }
            .navigationTitle(product.name)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 360, minHeight: 480)
    }
}
