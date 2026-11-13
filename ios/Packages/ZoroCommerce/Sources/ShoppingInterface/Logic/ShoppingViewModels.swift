import CommerceSupport
import Foundation
import Observation
import ZoroCore

/// Search, product detail actions (add to basket, shortlist) and store names.
@MainActor
@Observable
public final class ProductSearchViewModel {
    public var query = ""
    public private(set) var phase: ScreenPhase = .idle
    public private(set) var results: [ShownProduct] = []
    public private(set) var unavailable: [ProviderUnavailable] = []
    /// One sentence after an action ("Added 2 to your basket.").
    public private(set) var notice: String?
    public private(set) var isWorking = false
    public private(set) var storeTitles: [String: String] = [:]

    @ObservationIgnored private let client: ShoppingClient

    public init(client: ShoppingClient) { self.client = client }

    public var canSearch: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !phase.isLoading }

    public func loadStoreTitles() async {
        if let providers = try? await client.providers() {
            storeTitles = Dictionary(providers.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        }
    }

    public func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        phase = .loading
        notice = nil
        do {
            let out = try await client.search(SearchIn(query: String(text.prefix(120))))
            results = out.products
            unavailable = out.unavailable
            phase = out.products.isEmpty ? .empty : .loaded
        } catch {
            results = []
            phase = .failed(ScreenFailure.from(error, subject: "search results"))
        }
    }

    public var emptyMessage: String {
        let skipped = unavailable.map { ProductMapping.storeName($0.provider, titles: storeTitles) }
        if skipped.isEmpty { return "Nothing matched “\(query)”. Try a shorter name or a brand." }
        return "Nothing matched “\(query)”. \(skipped.joined(separator: ", ")) could not be searched here; open \(skipped.count == 1 ? "it" : "them") to look there."
    }

    public func add(_ product: ShownProduct, variant: VariantOut, quantity: Int, substitutionsAllowed: Bool) async {
        guard (1...99).contains(quantity) else {
            notice = "Choose a quantity from 1 to 99."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let out = try await client.add(BasketAddIn(ref: product.ref, variantHint: variant.variantId, quantity: quantity,
                                                        substitutionsAllowed: substitutionsAllowed))
            switch out.status {
            case "added", "updated": notice = "Added \(quantity) × \(product.name) to your basket."
            case "needs_clarification": notice = out.clarification?.question ?? "Choose a size, then add it again."
            default: notice = "That product is no longer in your results. Search again, then add it."
            }
        } catch {
            notice = ScreenFailure.from(error, subject: "your basket").message
        }
    }

    public func shortlist(_ product: ShownProduct) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let out = try await client.shortlistAdd(ref: product.ref)
            notice = out.status == "added" ? "Saved \(product.name) to your shortlist."
                : "That product is no longer in your results. Search again, then save it."
        } catch {
            notice = ScreenFailure.from(error, subject: "your shortlist").message
        }
    }
}

/// The universal basket: items, quantities, substitution choices, removal.
@MainActor
@Observable
public final class BasketViewModel {
    public private(set) var phase: ScreenPhase = .idle
    public private(set) var basket: BasketView?
    public private(set) var busyItems: Set<String> = []
    public private(set) var notice: String?

    @ObservationIgnored private let client: ShoppingClient

    public init(client: ShoppingClient) { self.client = client }

    public func load() async {
        if basket == nil { phase = .loading }
        do {
            apply(try await client.basket().basket)
        } catch {
            phase = .failed(ScreenFailure.from(error, subject: "your basket"))
        }
    }

    private func apply(_ view: BasketView?) {
        basket = view
        phase = (view?.items.isEmpty ?? true) ? .empty : .loaded
    }

    /// "1 of 2 items priced: ₹58.00 known so far."
    public var totalLine: String? {
        guard let b = basket, !b.items.isEmpty else { return nil }
        if b.pricedItems == b.items.count { return "All \(b.items.count) items priced: \(Figures.money(b.knownTotal))" }
        return "\(b.pricedItems) of \(b.items.count) items priced: \(Figures.money(b.knownTotal)) known so far"
    }

    public func setQuantity(_ item: BasketItemView, to quantity: Int) async {
        guard (1...99).contains(quantity), quantity != item.quantity else { return }
        await change(item) { try await $0.setQuantity(itemId: item.itemId, quantity: quantity) }
    }

    public func remove(_ item: BasketItemView) async {
        await change(item) { try await $0.remove(itemId: item.itemId) }
    }

    private func change(_ item: BasketItemView, _ op: (ShoppingClient) async throws -> BasketChangeOut) async {
        busyItems.insert(item.itemId)
        defer { busyItems.remove(item.itemId) }
        do {
            let out = try await op(client)
            if out.status == "not_found" {
                notice = "\(item.name) is no longer in your basket."
                await load()
            } else if let b = out.basket {
                apply(b)
                notice = nil
            } else {
                await load()
            }
        } catch {
            notice = ScreenFailure.from(error, subject: "your basket").message
        }
    }
}

/// Cross-store comparison of the basket.
@MainActor
@Observable
public final class ComparisonViewModel {
    public private(set) var phase: ScreenPhase = .idle
    public private(set) var result: CompareOut?
    public private(set) var presentation: ComparisonPresentation?

    @ObservationIgnored private let client: ShoppingClient
    @ObservationIgnored private let clock: @Sendable () -> Date

    public init(client: ShoppingClient, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.clock = clock
    }

    public func compare(basketId: String? = nil) async {
        phase = .loading
        do {
            let out = try await client.compare(basketId: basketId)
            result = out
            if let c = out.comparison, c.cheapestReason != .emptyBasket {
                presentation = ComparisonPresenter.present(c, now: clock())
                phase = .loaded
            } else {
                presentation = nil
                phase = .empty
            }
        } catch {
            phase = .failed(ScreenFailure.from(error, subject: "the comparison"))
        }
    }

    public func provider(_ id: String) -> ProviderComparison? {
        result?.comparison?.providers.first { $0.provider == id }
    }
}

/// Store list with the integration level of each capability, plus the shortlist.
@MainActor
@Observable
public final class StoresViewModel {
    public private(set) var phase: ScreenPhase = .idle
    public private(set) var providers: [ProviderInfo] = []
    public private(set) var shortlistPhase: ScreenPhase = .idle
    public private(set) var shortlist: [ShortlistEntry] = []

    @ObservationIgnored private let client: ShoppingClient

    public init(client: ShoppingClient) { self.client = client }

    public func load() async {
        phase = .loading
        do {
            providers = try await client.providers()
            phase = providers.isEmpty ? .empty : .loaded
        } catch {
            phase = .failed(ScreenFailure.from(error, subject: "the store list"))
        }
    }

    public func loadShortlist() async {
        shortlistPhase = .loading
        do {
            shortlist = try await client.shortlist()
            shortlistPhase = shortlist.isEmpty ? .empty : .loaded
        } catch {
            shortlistPhase = .failed(ScreenFailure.from(error, subject: "your shortlist"))
        }
    }

    public static func methodTitle(_ method: String) -> String {
        let text = method.replacingOccurrences(of: "_", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
