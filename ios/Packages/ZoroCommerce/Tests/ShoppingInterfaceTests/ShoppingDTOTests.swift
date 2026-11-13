import Foundation
import Testing
import ZoroCore
@testable import ShoppingInterface

@Suite("Shopping DTOs decode backend fixtures")
struct ShoppingDTOTests {
    @Test func searchResults() throws {
        let out = try Fixture.decode(SearchOut.self, "search_out")
        #expect(out.query == "milk")
        #expect(out.products.count == 2)
        let milk = out.products[0]
        #expect(milk.ref == "swiggy_instamart:p-101")
        #expect(milk.variants[0].price == Decimal(string: "29.00"))
        #expect(milk.variants[0].mrp == Decimal(string: "30.00"))
        #expect(milk.variants[1].price == Decimal(string: "56.5"))
        #expect(milk.variants[1].mrp == nil)
        #expect(milk.variants[1].inStock == nil)
        #expect(milk.attributes["fat_content"] == "3%")
        #expect(out.unavailable.first?.reason == "requires_partnership")
        #expect(out.unavailable.first?.handoff?.url == "https://www.zepto.com/")
    }

    @Test func basketAndChanges() throws {
        let basket = try #require(try Fixture.decode(BasketViewOut.self, "basket_view_out").basket)
        #expect(basket.items.count == 2)
        #expect(basket.knownTotal == Decimal(string: "58.00"))
        #expect(basket.items[1].unitPrice == nil)
        #expect(basket.items[1].substitutionsAllowed)
        #expect(try Fixture.decode(BasketViewOut.self, "basket_view_empty").basket == nil)
        let change = try Fixture.decode(BasketChangeOut.self, "basket_change_out")
        #expect(change.status == "updated")
    }

    @Test func comparisonVariants() throws {
        let c = try #require(try Fixture.decode(CompareOut.self, "compare_out_cheapest").comparison)
        #expect(c.cheapestReason == .cheapest)
        #expect(c.cheapestProvider == "store_b")
        #expect(c.providers.map(\.status) == [.ranked, .ranked, .partial, .unavailable])
        let partial = c.providers[2]
        #expect(partial.finalPayable == nil)
        #expect(partial.staleItems == ["bi-2"])
        #expect(partial.missing.first?.reason == .stalePrice)
        #expect(partial.substitutes.first?.offerLabel == "Test brown eggs 6 pcs")
        #expect(try Fixture.decode(CompareOut.self, "compare_out_partial").comparison?.cheapestReason == .noCompleteProvider)
        #expect(try Fixture.decode(CompareOut.self, "compare_out_fees_unknown").comparison?.cheapestReason == .feesUnknown)
        #expect(try Fixture.decode(CompareOut.self, "compare_out_empty").comparison == nil)
    }

    @Test func checkoutRuns() throws {
        let done = try Fixture.decode(CheckoutRun.self, "checkout_completed")
        #expect(done.result?.status == .handoff)
        #expect(done.result?.finalPayable == Decimal(string: "113.00"))
        let approval = try Fixture.decode(CheckoutRun.self, "checkout_needs_approval")
        #expect(approval.status == "needs_approval")
        #expect(approval.approval?.tool == "shopping.prepare_checkout")
        #expect(try Fixture.decode(CheckoutRun.self, "checkout_rejected").result?.reason == "payable_changed")
    }

    @Test func providersShortlistAndRecord() throws {
        let providers = try Fixture.decode([ProviderInfo].self, "providers")
        #expect(providers[0].methods[0].level == .officialAPI)
        #expect(providers[1].methods[0].level == .unavailable)
        let shortlist = try Fixture.decode([ShortlistEntry].self, "shortlist")
        #expect(shortlist[0].price == Decimal(string: "29.00"))
        let recorded = try Fixture.decode(RecordPriceOut.self, "record_price_out")
        #expect(recorded.price == Decimal(string: "31.50"))
    }

    @Test func moneyAsJSONNumberIsRejected() {
        let json = Data(#"{"code":"X","kind":"flat","amount":12.5}"#.utf8)
        #expect(throws: (any Error).self) { try ZoroJSON.decoder().decode(ComparisonDiscount.self, from: json) }
    }

    @Test func priceRecordEncodesDecimalStringsAndOnlyKnownKeys() throws {
        let record = PriceRecord(provider: "store_b", itemId: "bi-1", price: Decimal(string: "31.50")!, observedAt: Fixture.generatedAt)
        let object = try JSONSerialization.jsonObject(with: ZoroJSON.encoder().encode(record)) as? [String: Any]
        #expect(object?["price"] as? String == "31.5")
        #expect(object?["provenance"] as? String == "user_reported")
        #expect(object?["observed_at"] as? String == "2026-11-13T09:30:00Z")
        let allowed: Set<String> = ["provider", "kind", "item_id", "price", "mrp", "provenance", "observed_at", "label", "in_stock"]
        #expect(Set((object ?? [:]).keys).isSubset(of: allowed))
    }
}

@Suite("Shopping cards")
@MainActor
struct ShoppingCardTests {
    @Test func cardsDecode() throws {
        #expect(ShoppingCardDecoding.products(try Fixture.card("card_products"))?.products.count == 2)
        #expect(ShoppingCardDecoding.products(try Fixture.card("card_products"))?.lowestPrice == Decimal(29))
        #expect(ShoppingCardDecoding.basket(try Fixture.card("card_basket"))?.name == "Groceries")
        #expect(ShoppingCardDecoding.comparison(try Fixture.card("card_basket_comparison"))?.cheapestProvider == "store_b")
    }

    @Test func malformedOrWrongKindDegradesToNil() {
        let bad = UICard(kind: "basket", title: "Groceries", payload: ["items": "not a list"])
        #expect(ShoppingCardDecoding.basket(bad) == nil)
        #expect(ShoppingCardDecoding.products(UICard(kind: "basket")) == nil)
        _ = BasketCardView(card: bad).body
        _ = ProductsCardView(card: bad).body
        _ = BasketComparisonCardView(card: bad).body
    }
}
