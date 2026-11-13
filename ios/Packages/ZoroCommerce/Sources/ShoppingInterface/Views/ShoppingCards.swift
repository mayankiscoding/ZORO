import CommerceSupport
import Foundation
import SwiftUI
import ZoroCore
import ZoroDesign

// Views for the UICard kinds the shopping tools emit: products, basket, basket_comparison.
// Each decodes its payload into the DTOs; when decoding fails it says so plainly instead of guessing.

/// `products` payload: `{"products": [ShownProduct], "lowest_price": "…"|null}`.
public struct ProductsCardPayload: Codable, Sendable, Equatable {
    public var products: [ShownProduct]
    @WireDecimalOptional public var lowestPrice: Decimal?
    enum CodingKeys: String, CodingKey { case products, lowestPrice = "lowest_price" }
}

public enum ShoppingCardDecoding {
    public static func products(_ card: UICard) -> ProductsCardPayload? {
        guard card.kind == "products" else { return nil }
        return try? card.decodePayload(ProductsCardPayload.self)
    }
    public static func basket(_ card: UICard) -> BasketView? {
        guard card.kind == "basket" else { return nil }
        return try? card.decodePayload(BasketView.self)
    }
    public static func comparison(_ card: UICard) -> BasketComparison? {
        guard card.kind == "basket_comparison" else { return nil }
        return try? card.decodePayload(BasketComparison.self)
    }
}

/// Shown when a card's payload cannot be read.
struct UnreadableCard: View {
    let title: String
    var body: some View {
        ZoroCard {
            ZoroStateView(.error, message: "\(title) could not be shown in this version of the app. Ask ZORO again, or update the app.")
        }
    }
}

public struct ProductsCardView: View {
    let card: UICard
    let payload: ProductsCardPayload?

    public init(card: UICard) {
        self.card = card
        self.payload = ShoppingCardDecoding.products(card)
    }

    public var body: some View {
        if let payload {
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                ZoroSectionHeader(card.title ?? "Products",
                                  detail: payload.lowestPrice.map { "Lowest \(Figures.money($0, style: .compact))" })
                ForEach(payload.products) { product in
                    if let model = ProductMapping.card(product) {
                        ProductCardView(model)
                    } else {
                        Text("\(product.name): price not reported").zoroText(.detail)
                    }
                }
            }
        } else {
            UnreadableCard(title: card.title ?? "These products")
        }
    }
}

public struct BasketCardView: View {
    let card: UICard
    let basket: BasketView?

    public init(card: UICard) {
        self.card = card
        self.basket = ShoppingCardDecoding.basket(card)
    }

    public var body: some View {
        if let basket {
            ZoroCard {
                VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                    Text(basket.name).zoroText(.heading)
                    ForEach(basket.items) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(item.quantity) × \(item.name)").zoroText(.body)
                            Spacer()
                            Text(item.unitPrice.map { Figures.money($0 * Decimal(item.quantity), style: .compact) } ?? "Not priced")
                                .zoroText(.amount)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Divider()
                    FigureRow(basket.pricedItems == basket.items.count ? "Total" : "Known so far (\(basket.pricedItems) of \(basket.items.count) priced)",
                              value: Figures.money(basket.knownTotal))
                }
            }
        } else {
            UnreadableCard(title: card.title ?? "This basket")
        }
    }
}

public struct BasketComparisonCardView: View {
    let card: UICard
    let result: BasketComparison?
    let now: Date

    public init(card: UICard, now: Date = Date()) {
        self.card = card
        self.result = ShoppingCardDecoding.comparison(card)
        self.now = now
    }

    public var body: some View {
        if let result {
            ComparisonSummaryView(presentation: ComparisonPresenter.present(result, now: now))
        } else {
            UnreadableCard(title: card.title ?? "This comparison")
        }
    }
}
