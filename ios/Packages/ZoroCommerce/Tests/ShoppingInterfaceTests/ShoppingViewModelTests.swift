import CommerceSupport
import Foundation
import Testing
import ZoroCore
@testable import ShoppingInterface

@Suite("Shopping view models")
@MainActor
struct ShoppingViewModelTests {
    let api = FakeAPI()
    var client: ShoppingClient { ShoppingClient(api: api, conversationId: "c-test") }

    @Test func searchLoadsResultsAndSendsConversation() async throws {
        api.on("POST /v1/shopping/search", fixture: "search_out")
        let vm = ProductSearchViewModel(client: client)
        vm.query = "  milk "
        await vm.search()
        #expect(vm.phase == .loaded)
        #expect(vm.results.count == 2)
        #expect(vm.unavailable.count == 1)
        let request = try #require(api.sent(.post, "/v1/shopping/search").first)
        #expect(request.query.first { $0.name == "conversation_id" }?.value == "c-test")
        let body = try JSONSerialization.jsonObject(with: try #require(request.body)) as? [String: Any]
        #expect(body?["query"] as? String == "milk")
    }

    @Test func emptySearchInvitesAndNamesSkippedStores() async {
        api.on("POST /v1/shopping/search") { _ in Data(#"{"query":"x","products":[],"unavailable":[{"kind":"unavailable","provider":"zepto","method":"search_products","reason":"requires_partnership","message":"","handoff":null}]}"#.utf8) }
        let vm = ProductSearchViewModel(client: client)
        vm.query = "x"
        await vm.search()
        #expect(vm.phase == .empty)
        #expect(vm.emptyMessage.contains("Zepto could not be searched here"))
    }

    @Test func disconnectedAndPermissionErrors() async {
        api.on("POST /v1/shopping/search", error: .transport("offline"))
        let vm = ProductSearchViewModel(client: client)
        vm.query = "milk"
        await vm.search()
        #expect(vm.phase.failure?.kind == .disconnected)

        api.on("GET /v1/shopping/baskets", error: .http(status: 403, body: ErrorBody(code: "permission_not_granted:shopping.basket", message: "Allow it")))
        let basket = BasketViewModel(client: client)
        await basket.load()
        #expect(basket.phase.failure == ScreenFailure(kind: .error, message: "Allow shopping.basket in Security and privacy, then try again."))
    }

    @Test func malformedServerDataIsAnErrorNotACrash() async {
        api.on("GET /v1/shopping/baskets") { _ in Data(#"{"basket":{"basket_id":1}}"#.utf8) }
        let vm = BasketViewModel(client: client)
        await vm.load()
        #expect(vm.phase.failure?.kind == .error)
        #expect(vm.phase.failure?.retryable == false)
    }

    @Test func addToBasketSendsVariantQuantityAndSubstitution() async throws {
        api.on("POST /v1/shopping/search", fixture: "search_out")
        api.on("POST /v1/shopping/baskets/items", fixture: "basket_change_out")
        let vm = ProductSearchViewModel(client: client)
        vm.query = "milk"
        await vm.search()
        let product = vm.results[0]
        await vm.add(product, variant: product.variants[1], quantity: 3, substitutionsAllowed: true)
        #expect(vm.notice == "Added 3 × Test toned milk to your basket.")
        let body = try JSONSerialization.jsonObject(with: try #require(api.sent(.post, "/v1/shopping/baskets/items").first?.body)) as? [String: Any]
        #expect(body?["variant_hint"] as? String == "v-2")
        #expect(body?["quantity"] as? Int == 3)
        #expect(body?["substitutions_allowed"] as? Bool == true)
        await vm.add(product, variant: product.variants[0], quantity: 120, substitutionsAllowed: false)
        #expect(vm.notice == "Choose a quantity from 1 to 99.")
        #expect(api.sent(.post, "/v1/shopping/baskets/items").count == 1)
    }

    @Test func basketQuantityChangesAndEmptyState() async throws {
        api.on("GET /v1/shopping/baskets", fixture: "basket_view_out")
        api.on("PATCH /v1/shopping/items/bi-1", fixture: "basket_change_out")
        let vm = BasketViewModel(client: client)
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(vm.totalLine == "1 of 2 items priced: ₹58.00 known so far")
        await vm.setQuantity(try #require(vm.basket?.items.first), to: 4)
        let body = try JSONSerialization.jsonObject(with: try #require(api.sent(.patch, "/v1/shopping/items/bi-1").first?.body)) as? [String: Any]
        #expect(body?["quantity"] as? Int == 4)
        await vm.setQuantity(try #require(vm.basket?.items.first), to: 0)
        #expect(api.sent(.patch, "/v1/shopping/items/bi-1").count == 1)

        api.on("GET /v1/shopping/baskets", fixture: "basket_view_empty")
        let empty = BasketViewModel(client: client)
        await empty.load()
        #expect(empty.phase == .empty)
    }

    @Test func comparisonLoadsPresentationOrEmpty() async {
        api.on("POST /v1/shopping/compare", fixture: "compare_out_partial")
        let vm = ComparisonViewModel(client: client, clock: { Fixture.generatedAt })
        await vm.compare()
        #expect(vm.phase == .loaded)
        #expect(vm.presentation?.headline == "No store can be called cheapest.")

        api.on("POST /v1/shopping/compare", fixture: "compare_out_empty")
        await vm.compare()
        #expect(vm.phase == .empty)
    }

    @Test func recordPriceValidatesThenSends() async throws {
        api.on("POST /v1/shopping/observations", fixture: "record_price_out")
        let vm = RecordPriceViewModel(client: client, clock: { Fixture.generatedAt })
        #expect(vm.validationMessage == "Choose the store where you saw the price.")
        vm.providerId = "store_b"
        #expect(vm.validationMessage == "Choose the basket item this price is for.")
        vm.itemId = "bi-1"
        vm.priceText = "31.505"
        #expect(vm.validationMessage == "Enter the price in rupees, like 49.50.")
        vm.priceText = "₹31.50"
        vm.seenAt = Fixture.generatedAt
        #expect(vm.validationMessage == nil)
        await vm.save()
        #expect(vm.message == "Saved ₹31.50 as a price you saw. Compare again to use it.")
        let body = try JSONSerialization.jsonObject(with: try #require(api.sent(.post, "/v1/shopping/observations").first?.body)) as? [String: Any]
        #expect(body?["price"] as? String == "31.5")
        #expect(body?["item_id"] as? String == "bi-1")
        #expect(RecordPriceViewModel.parsePrice("1,250.5") == Decimal(string: "1250.5"))
        #expect(RecordPriceViewModel.parsePrice("-3") == nil)
        #expect(RecordPriceViewModel.parsePrice("1e5") == nil)
    }

    @Test func storesAndShortlist() async {
        api.on("GET /v1/shopping/providers", fixture: "providers")
        api.on("GET /v1/shopping/shortlist") { _ in Data("[]".utf8) }
        let vm = StoresViewModel(client: client)
        await vm.load()
        await vm.loadShortlist()
        #expect(vm.providers.count == 2)
        #expect(vm.shortlistPhase == .empty)
        #expect(StoresViewModel.methodTitle("prepare_checkout") == "Prepare checkout")
    }
}

@Suite("Checkout handoff")
@MainActor
struct CheckoutViewModelTests {
    let api = FakeAPI()

    private func make() throws -> CheckoutViewModel {
        let out = try Fixture.decode(CompareOut.self, "compare_out_cheapest")
        let provider = try #require(out.comparison?.providers.first { $0.provider == "store_a" })
        return CheckoutViewModel(client: ShoppingClient(api: api), provider: provider, basket: try #require(out.basket))
    }

    @Test func requiresEveryCheckBeforeSending() async throws {
        api.on("POST /v1/shopping/checkout", fixture: "checkout_completed")
        let vm = try make()
        #expect(vm.checkLine(.payable) == "Final payable: ₹143.00")
        #expect(vm.checkLine(.quantities) == "2 × Test toned milk, 1 × Test eggs")
        #expect(vm.checkLine(.address) == "Delivery address: home")
        await vm.prepare()
        #expect(api.sent(.post, "/v1/shopping/checkout").isEmpty)
        for check in CheckoutViewModel.Check.allCases { vm.toggle(check) }
        #expect(vm.canContinue)
        await vm.prepare()
        guard case .handoff(let result) = vm.step else { Issue.record("expected handoff"); return }
        #expect(result.finalPayable == Decimal(string: "113.00"))
        #expect(vm.handoffURL?.absoluteString == "https://example.invalid/a")
        let body = try JSONSerialization.jsonObject(with: try #require(api.sent(.post, "/v1/shopping/checkout").first?.body)) as? [String: Any]
        #expect(body?["expected_payable"] as? String == "143")
        #expect(body?["provider"] as? String == "store_a")
    }

    @Test func rejectionAndApprovalPaths() async throws {
        api.on("POST /v1/shopping/checkout", fixture: "checkout_rejected")
        let vm = try make()
        for check in CheckoutViewModel.Check.allCases { vm.toggle(check) }
        await vm.prepare()
        #expect(vm.step == .rejected("The payable changed since you compared. Compare again, then check out."))
        vm.restart()
        #expect(vm.confirmed.isEmpty)

        api.on("POST /v1/shopping/checkout", fixture: "checkout_needs_approval")
        for check in CheckoutViewModel.Check.allCases { vm.toggle(check) }
        await vm.prepare()
        guard case .needsApproval(let request) = vm.step else { Issue.record("expected approval"); return }
        #expect(request.approvalId == "ap-1")
        // Falls back to the comparison's own store link; opening a link needs no approval.
        #expect(vm.handoffURL?.absoluteString == "https://example.invalid/a")
    }

    @Test func serverDownIsDisconnected() async throws {
        api.on("POST /v1/shopping/checkout", error: .timeout)
        let vm = try make()
        for check in CheckoutViewModel.Check.allCases { vm.toggle(check) }
        await vm.prepare()
        guard case .failed(let f) = vm.step else { Issue.record("expected failure"); return }
        #expect(f.kind == .disconnected)
    }
}
