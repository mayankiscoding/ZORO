import CommerceSupport
import SwiftUI
import ZoroCore
import ZoroDesign

// MARK: - Basket

struct BasketSection: View {
    let model: BasketViewModel
    let client: ShoppingClient
    let onCompare: () -> Void
    @State private var recording = false

    var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            if let basket = model.basket, model.phase == .loaded {
                ZoroSectionHeader(basket.name, detail: model.totalLine)
                ZoroCard {
                    VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                        ForEach(basket.items) { item in
                            BasketItemRow(item: item, busy: model.busyItems.contains(item.itemId),
                                          setQuantity: { q in Task { await model.setQuantity(item, to: q) } },
                                          remove: { Task { await model.remove(item) } })
                            if item.id != basket.items.last?.id { Divider() }
                        }
                    }
                }
                if let notice = model.notice { NoticeLine(notice) }
                Button("Compare stores", action: onCompare).buttonStyle(.zoroPrimary)
                Button("Record a price you saw") { recording = true }.buttonStyle(.zoroLink)
            } else {
                PhaseStateView(model.phase, loading: "Loading your basket.",
                               empty: "No baskets yet. Search for a product and add it, or ask ZORO to “add milk and eggs”.") {
                    Task { await model.load() }
                }
            }
        }
        .task { await model.load() }
        .sheet(isPresented: $recording) {
            RecordPriceView(model: RecordPriceViewModel(client: client), items: model.basket?.items ?? [])
        }
    }
}

struct BasketItemRow: View {
    let item: BasketItemView
    let busy: Bool
    let setQuantity: @Sendable (Int) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
                    Text(item.name).font(.body.weight(.semibold))
                    let detail = [item.brand, item.size].compactMap { $0 }.joined(separator: ", ")
                    if !detail.isEmpty { Text(detail).zoroText(.detail).foregroundStyle(.secondary) }
                }
                Spacer()
                if let price = item.unitPrice {
                    MoneyText(price * Decimal(item.quantity), style: .compact)
                } else {
                    Text("Not priced").zoroText(.detail).foregroundStyle(.secondary)
                }
            }
            HStack {
                Stepper("Quantity \(item.quantity)", value: Binding(get: { item.quantity }, set: setQuantity), in: 1...99)
                    .disabled(busy)
                    .fixedSize()
                Spacer()
                Button("Remove", role: .destructive, action: remove).buttonStyle(.zoroLink).disabled(busy)
            }
            Label(item.substitutionsAllowed ? "Substitutes allowed" : "Exact item only",
                  systemImage: item.substitutionsAllowed ? "arrow.triangle.swap" : "checkmark.seal")
                .zoroText(.caption).foregroundStyle(.secondary)
            if let at = item.priceAt, let source = item.priceSource {
                SourceLine(stamp: SourceStamp(source: ProductMapping.storeName(source), retrievedAt: at))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Comparison

struct ComparisonSection: View {
    let model: ComparisonViewModel
    let basket: BasketViewModel
    let client: ShoppingClient
    @State private var checkoutProvider: ProviderComparison?

    var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            if let p = model.presentation, model.phase == .loaded {
                ComparisonSummaryView(presentation: p) { id in checkoutProvider = model.provider(id) }
                Button("Compare again") { Task { await model.compare() } }.buttonStyle(.zoroSecondary)
            } else {
                PhaseStateView(model.phase, loading: "Comparing every store for your basket.",
                               empty: "Your basket is empty. Add items, then compare stores.") {
                    Task { await model.compare() }
                }
            }
        }
        .task { await model.compare() }
        .sheet(item: $checkoutProvider) { provider in
            if let b = model.result?.basket {
                CheckoutHandoffView(model: CheckoutViewModel(client: client, provider: provider, basket: b))
            }
        }
    }
}

/// The comparison as words and rows. Used by the screen and by the `basket_comparison` card.
public struct ComparisonSummaryView: View {
    let presentation: ComparisonPresentation
    let onCheckout: ((String) -> Void)?

    public init(presentation: ComparisonPresentation, onCheckout: ((String) -> Void)? = nil) {
        self.presentation = presentation
        self.onCheckout = onCheckout
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
            Text(presentation.headline).zoroText(.heading).fixedSize(horizontal: false, vertical: true)
            if let e = presentation.explanation {
                Text(e).zoroText(.zoroBody).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let w = presentation.freshnessWarning {
                Label(w, systemImage: "clock").zoroText(.detail).foregroundStyle(ZoroRole.attention.style)
            }
            ForEach(presentation.rows) { row in
                ComparisonRowView(row: row, onCheckout: onCheckout)
            }
        }
    }
}

struct ComparisonRowView: View {
    let row: ComparisonPresentation.Row
    let onCheckout: ((String) -> Void)?

    var body: some View {
        ZoroCard {
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title).zoroText(.heading)
                    ZoroCapsuleLabel(text: row.badge, role: row.badgeRole)
                    Spacer()
                }
                Text(row.amountLine).zoroText(.amount)
                Text(row.coverageLine).zoroText(.detail).foregroundStyle(.secondary)
                if let c = row.matchConfidence { ConfidenceBadge(score: c) }
                Text(row.feeLine).zoroText(.detail)
                if let d = row.discountLine { Text(d).zoroText(.detail) }
                ForEach(row.missingLines, id: \.self) { Label($0, systemImage: "minus.circle").zoroText(.detail) }
                if let s = row.staleLine {
                    Label(s, systemImage: "clock").zoroText(.detail).foregroundStyle(ZoroRole.attention.style)
                }
                if !row.substituteLines.isEmpty {
                    Text("Substitutes, not counted in the total").zoroText(.caption).foregroundStyle(.secondary)
                    ForEach(row.substituteLines, id: \.self) { Text($0).zoroText(.detail) }
                }
                ForEach(row.cautions, id: \.self) {
                    Label($0, systemImage: "exclamationmark.circle").zoroText(.detail).foregroundStyle(ZoroRole.attention.style)
                }
                if row.canCheckout, let onCheckout {
                    Button("Check out in \(row.title)") { onCheckout(row.id) }.buttonStyle(.zoroSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Checkout handoff

struct CheckoutHandoffView: View {
    @State var model: CheckoutViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
                    Text("Check these before ZORO opens \(model.provider.title). You pay in \(model.provider.title)'s own app; ZORO never pays.")
                        .zoroText(.zoroBody).fixedSize(horizontal: false, vertical: true)
                    ForEach(CheckoutViewModel.Check.allCases, id: \.self) { check in
                        Toggle(isOn: Binding(get: { model.confirmed.contains(check) }, set: { _ in model.toggle(check) })) {
                            Text(model.checkLine(check)).zoroText(.body).fixedSize(horizontal: false, vertical: true)
                        }
                        .disabled(model.step != .review)
                    }
                    stepContent
                }
                .padding(ZoroSpace.l.value)
            }
            .navigationTitle("Check out")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .frame(minWidth: 360, minHeight: 420)
    }

    @ViewBuilder private var stepContent: some View {
        switch model.step {
        case .review:
            Button("Prepare and open \(model.provider.title)") { Task { await model.prepare() } }
                .buttonStyle(.zoroPrimary).disabled(!model.canContinue)
            if !model.canContinue { NoticeLine("Tick each line once you have checked it.") }
        case .preparing:
            ZoroStateView(.loading, message: "Checking prices and preparing your \(model.provider.title) cart.")
        case .handoff(let result):
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                FigureRow("Final payable", value: Figures.money(result.finalPayable))
                if let bill = result.providerToPay { FigureRow("\(model.provider.title) bill", value: Figures.money(bill)) }
                ForEach(result.warnings, id: \.self) { NoticeLine($0) }
                Text(result.note).zoroText(.detail).foregroundStyle(.secondary)
                openButton
            }
        case .rejected(let message):
            ZoroStateView(.error, message: message, action: ZoroStateAction("Start again") { model.restart() })
        case .needsApproval(let approval):
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                NoticeLine("Preparing the cart needs your approval: \(approval.title). Approve it from ZORO's pending approvals, or open \(model.provider.title) and add the items yourself.")
                openButton
            }
        case .failed(let failure):
            ZoroStateView(failure.kind == .disconnected ? .disconnected : .error, message: failure.message,
                          action: ZoroStateAction("Start again") { model.restart() })
        }
    }

    @ViewBuilder private var openButton: some View {
        if let url = model.handoffURL {
            Button("Open \(model.provider.title)") { openURL(url) }.buttonStyle(.zoroPrimary)
        } else {
            NoticeLine("\(model.provider.title) has no verified link. Open its app yourself; your basket is listed above.")
        }
    }
}
