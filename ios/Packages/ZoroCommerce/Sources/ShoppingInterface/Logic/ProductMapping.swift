import CommerceSupport
import Foundation
import ZoroCore
import ZoroDesign

/// Maps shopping DTOs to ZoroDesign display models. Nothing is invented: a variant without a price
/// gets no product card, unknown stock stays "Stock not reported".
public enum ProductMapping {
    /// Store name for a source like "swiggy_instamart:search_products" or a provider id.
    public static func storeName(_ sourceOrProvider: String, titles: [String: String] = [:]) -> String {
        let provider = String(sourceOrProvider.split(separator: ":").first ?? Substring(sourceOrProvider))
        if provider == "user" { return "you" }
        if let title = titles[provider] { return title }
        let words = provider.split(separator: "_").map(String.init)
        guard let first = words.first else { return provider }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    /// Parses the server's unit price line ("₹5.80 per 100 ml", "₹1,250 per kg").
    public static func unitPrice(_ line: String?) -> UnitPrice? {
        guard let line, let range = line.range(of: " per ") else { return nil }
        let amountText = line[..<range.lowerBound]
            .replacingOccurrences(of: ZoroMoney.rupee, with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        let unit = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !unit.isEmpty, let amount = DecimalString.parse(amountText) else { return nil }
        return UnitPrice(amount: amount, unit: unit)
    }

    public static func availability(_ inStock: Bool?) -> ProductAvailability {
        switch inStock {
        case .some(true): .inStock
        case .some(false): .outOfStock
        case .none: .unknown
        }
    }

    /// The variant shown first: the first one with a price, preferring one in stock.
    public static func primaryVariant(_ product: ShownProduct) -> VariantOut? {
        let priced = product.variants.filter { $0.price != nil }
        return priced.first { $0.inStock != false } ?? priced.first
    }

    public static func card(_ product: ShownProduct, variant: VariantOut? = nil, quantity: Int = 1,
                            titles: [String: String] = [:]) -> ProductCardModel? {
        guard let v = variant ?? primaryVariant(product), let price = v.price else { return nil }
        return ProductCardModel(
            id: "\(product.ref)#\(v.variantId)", name: product.name, brand: product.brand, variant: nil,
            packSize: v.label.isEmpty ? nil : v.label, quantity: quantity, price: price,
            unitPrice: unitPrice(v.unitPrice), availability: availability(v.inStock), imageURL: nil,
            stamp: SourceStamp(source: storeName(product.source, titles: titles), retrievedAt: product.retrievedAt))
    }
}
