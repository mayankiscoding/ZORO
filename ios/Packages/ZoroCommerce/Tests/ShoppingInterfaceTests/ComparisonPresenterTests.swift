import Foundation
import Testing
import ZoroCore
@testable import ShoppingInterface

@Suite("Comparison presentation")
struct ComparisonPresenterTests {
    private func comparison(_ name: String) throws -> BasketComparison {
        try #require(try Fixture.decode(CompareOut.self, name).comparison)
    }

    @Test func namesTheCheapestOnlyWithFullCoverage() throws {
        let p = ComparisonPresenter.present(try comparison("compare_out_cheapest"), now: Fixture.generatedAt)
        #expect(p.headline == "Store B is cheapest for the full basket at ₹121.00.")
        #expect(p.explanation?.contains("Store C and Store D are left out") == true)
        #expect(p.rows.map(\.badge) == ["Lowest", "2nd", "Partial", "Not available"])
        #expect(p.rows[0].canCheckout)
        #expect(p.rows[0].amountLine == "₹121.00 to pay")
        #expect(p.freshnessWarning == nil)
    }

    @Test func partialCoverageNeverCalledCheapest() throws {
        let p = ComparisonPresenter.present(try comparison("compare_out_partial"), now: Fixture.generatedAt)
        #expect(p.headline == "No store can be called cheapest.")
        #expect(p.explanation?.contains("No store has a fresh price for every item") == true)
        #expect(p.cheapestProviderId == nil)
        let c = try #require(p.rows.first { $0.id == "store_c" })
        #expect(c.badge == "Partial")
        #expect(c.amountLine == "₹54.00 for 1 of 2 items")
        #expect(c.coverageLine == "1 of 2 items priced (50%)")
        #expect(!c.canCheckout)
        #expect(c.feeLine == "Fees not checked until every item is priced")
    }

    @Test func stalePricesAreMarkedAndSubstitutesListedSeparately() throws {
        let p = ComparisonPresenter.present(try comparison("compare_out_cheapest"), now: Fixture.generatedAt)
        let c = try #require(p.rows.first { $0.id == "store_c" })
        #expect(c.missingLines == ["Test eggs: price is old, so it is left out"])
        #expect(c.staleLine == "1 price is too old to use. Check the store or record what you see.")
        #expect(c.substituteLines == ["Instead of Test eggs: Test brown eggs 6 pcs, ₹52.00 (substitutes allowed)"])
        // Store C's partial total (₹54) is below the cheapest full basket (₹121): say why.
        #expect(c.cautions.contains("Looks lower only because 1 of 2 items are missing."))
        let d = try #require(p.rows.first { $0.id == "store_d" })
        #expect(d.amountLine == "No prices")
        #expect(d.missingLines.allSatisfy { $0.hasSuffix("not available") })
    }

    @Test func unknownFeesBlockTheCheapestClaim() throws {
        let p = ComparisonPresenter.present(try comparison("compare_out_fees_unknown"), now: Fixture.generatedAt)
        #expect(p.headline == "No store is called cheapest yet.")
        #expect(p.explanation?.contains("fees are not known for Store A") == true)
        let a = try #require(p.rows.first { $0.id == "store_a" })
        #expect(a.feeLine == "Fees not known; the payable may be higher")
    }

    @Test func oldComparisonGetsAFreshnessWarning() throws {
        let later = Fixture.generatedAt.addingTimeInterval(2 * 3600)
        let p = ComparisonPresenter.present(try comparison("compare_out_cheapest"), now: later)
        #expect(p.freshnessWarning?.hasSuffix("may have changed. Compare again before you check out.") == true)
    }

    @Test func feeLinesUseServerAmounts() throws {
        let p = ComparisonPresenter.present(try comparison("compare_out_cheapest"), now: Fixture.generatedAt)
        #expect(p.rows[0].feeLine == "Delivery fee waived")  // Store B waives it at ₹100 and above
        #expect(p.rows[1].feeLine == "Delivery fee ₹25.00")
    }

    @Test func wording() {
        #expect(ComparisonPresenter.ordinal(1) == "1st")
        #expect(ComparisonPresenter.ordinal(12) == "12th")
        #expect(ComparisonPresenter.ordinal(23) == "23rd")
        #expect(ComparisonPresenter.storeList(["A", "B", "C"]) == "A, B and C")
    }
}

@Suite("Product mapping")
struct ProductMappingTests {
    @Test func cardCarriesSourceAndUnitPrice() throws {
        let out = try Fixture.decode(SearchOut.self, "search_out")
        let card = try #require(ProductMapping.card(out.products[0], titles: ["swiggy_instamart": "Instamart"]))
        #expect(card.price == Decimal(29))
        #expect(card.packSize == "500 ml")
        #expect(card.unitPrice?.amount == Decimal(string: "5.80"))
        #expect(card.unitPrice?.unit == "100 ml")
        #expect(card.stamp.source == "Instamart")
        #expect(card.availability == .inStock)
        // Out-of-stock only variant still maps, honestly marked.
        #expect(ProductMapping.card(out.products[1])?.availability == .outOfStock)
    }

    @Test func storeNameFallsBackToReadableId() {
        #expect(ProductMapping.storeName("swiggy_instamart:search_products") == "Swiggy instamart")
        #expect(ProductMapping.storeName("user") == "you")
        #expect(ProductMapping.unitPrice("₹1,250 per kg")?.amount == Decimal(1250))
        #expect(ProductMapping.unitPrice("garbage") == nil)
    }
}
