import SwiftUI

/// A product as one store reports it: what it is, how much, whether it is there, and where and when
/// that was checked. The source line is always visible; stale prices are marked.
public struct ProductCardView: View {
    let product: ProductCardModel
    let now: Date

    public init(_ product: ProductCardModel, now: Date = Date()) {
        self.product = product
        self.now = now
    }

    @ScaledMetric(relativeTo: .body) private var imageSize: CGFloat = 64

    public var body: some View {
        ZoroCard {
            VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                HStack(alignment: .top, spacing: ZoroSpace.m.value) {
                    image
                    VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
                        Text(product.name).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        if !product.descriptor.isEmpty {
                            Text(product.descriptor).zoroText(.detail).foregroundStyle(.secondary)
                        }
                        availability.padding(.top, ZoroSpace.xs.value)
                    }
                    Spacer(minLength: 0)
                }
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
                        MoneyText(product.lineTotal, style: .compact)
                        if product.quantity != 1 {
                            Text("\(product.quantity) × \(ZoroMoney.format(product.price, style: .compact))")
                                .zoroText(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let unit = product.unitPrice {
                        Text(ZoroMoney.unitPrice(unit.amount, per: unit.unit)).zoroText(.detail).foregroundStyle(.secondary)
                    }
                }
                SourceLine(stamp: product.stamp, now: now)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var image: some View {
        AsyncImage(url: product.imageURL) { phase in
            if let img = phase.image {
                img.resizable().scaledToFit()
            } else {
                Image(systemName: "basket").font(.title3).foregroundStyle(.tertiary)
            }
        }
        .frame(width: imageSize, height: imageSize)
        .background(ZoroNeutral.inset, in: ZoroRadius.inset.shape)
        .clipShape(ZoroRadius.inset.shape)
        .accessibilityHidden(true)
    }

    private var availability: some View {
        Label(product.availability.label, systemImage: product.availability.symbol)
            .zoroText(.caption)
            .foregroundStyle(product.availability.role.map { AnyShapeStyle($0.style) } ?? AnyShapeStyle(.secondary))
    }
}

/// "From Instamart, checked 4:12 pm", with a marigold clock when older than 30 minutes.
public struct SourceLine: View {
    let stamp: SourceStamp
    let now: Date
    public init(stamp: SourceStamp, now: Date = Date()) {
        self.stamp = stamp
        self.now = now
    }

    public var body: some View {
        let stale = stamp.isStale(now: now)
        HStack(spacing: ZoroSpace.xs.value) {
            Image(systemName: stale ? "clock.badge.exclamationmark" : "clock")
                .foregroundStyle(stale ? AnyShapeStyle(.genda) : AnyShapeStyle(.tertiary))
                .accessibilityHidden(true)
            Text(stamp.line(now: now) + (stale ? ". Price may have changed." : ""))
        }
        .zoroText(.caption)
        .foregroundStyle(.secondary)
    }
}

/// A basket compared across stores. Items are rows, stores are columns; the cheapest complete basket
/// is marked with a mor rule above its total. Unavailable items read "Not available", never 0.
public struct ComparisonTableView: View {
    let model: ComparisonTableModel
    let now: Date

    public init(_ model: ComparisonTableModel, now: Date = Date()) {
        self.model = model
        self.now = now
    }

    public var body: some View {
        let best = model.bestStoreID
        ZoroCard {
            Grid(alignment: .leading, horizontalSpacing: ZoroSpace.m.value, verticalSpacing: ZoroSpace.s.value) {
                GridRow {
                    Text("Item").zoroText(.caption).foregroundStyle(.secondary)
                    ForEach(model.stores) { store in
                        Text(store.name).font(.subheadline.weight(.semibold)).gridColumnAlignment(.trailing)
                    }
                }
                Divider()
                ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                    GridRow {
                        Text(item).zoroText(.detail).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        ForEach(model.stores) { store in
                            cell(index < store.prices.count ? store.prices[index] : nil)
                        }
                    }
                }
                Divider()
                GridRow {
                    Text("Delivery").zoroText(.caption).foregroundStyle(.secondary)
                    ForEach(model.stores) { store in
                        Group {
                            if let fee = store.deliveryFee {
                                Text(fee == 0 ? "Free" : ZoroMoney.format(fee, style: .compact))
                            } else {
                                Text("Not reported").foregroundStyle(.secondary)
                            }
                        }
                        .zoroText(.caption)
                    }
                }
                GridRow(alignment: .top) {
                    Text("Total").font(.subheadline.weight(.semibold))
                    ForEach(model.stores) { store in
                        totalCell(store, isBest: store.id == best)
                    }
                }
            }
            if best == nil {
                Text("No store has every item. Totals cover only what each store has.")
                    .zoroText(.caption).foregroundStyle(.secondary).padding(.top, ZoroSpace.s.value)
            }
            VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
                ForEach(model.stores) { SourceLine(stamp: $0.stamp, now: now) }
            }
            .padding(.top, ZoroSpace.m.value)
        }
    }

    @ViewBuilder private func cell(_ price: Decimal?) -> some View {
        if let price {
            Text(ZoroMoney.format(price, style: .compact)).zoroText(.detail)
        } else {
            Text("Not available").zoroText(.caption).foregroundStyle(.secondary)
        }
    }

    private func totalCell(_ store: ComparisonStore, isBest: Bool) -> some View {
        let missing = model.missingCount(store)
        return VStack(alignment: .trailing, spacing: ZoroSpace.hair.value) {
            if isBest {
                Rectangle().fill(.mor).frame(width: 28, height: 2).accessibilityHidden(true)
            }
            Text(ZoroMoney.format(model.total(store), style: .compact))
                .font(ZoroTextStyle.amount.font)
                .foregroundStyle(isBest ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            if isBest {
                Text("Lowest").zoroText(.caption).foregroundStyle(ZoroColor(.mor))
            } else if missing > 0 {
                Text(missing == 1 ? "1 item missing" : "\(missing) items missing").zoroText(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
