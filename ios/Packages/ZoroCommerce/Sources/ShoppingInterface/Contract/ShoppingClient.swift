import Foundation
import ZoroCore

/// Typed client for `/v1/shopping` (backend/app/shopping/api.py). Every call goes through `ZoroAPI`,
/// so the server runs the same tools, policy and audit as a voice turn.
public struct ShoppingClient: Sendable {
    public let api: any ZoroAPI
    /// Conversation the shopping working set belongs to (routes that resolve "the second one" need it).
    public let conversationId: String

    public init(api: any ZoroAPI, conversationId: String = "shopping-space") {
        self.api = api
        self.conversationId = conversationId
    }

    private var conversation: [URLQueryItem] { [URLQueryItem(name: "conversation_id", value: conversationId)] }

    public func providers() async throws -> [ProviderInfo] {
        try await api.send(.get("/v1/shopping/providers"), as: [ProviderInfo].self)
    }

    public func search(_ body: SearchIn) async throws -> SearchOut {
        var request = try APIRequest.json(.post, "/v1/shopping/search", body: body)
        request.query = conversation
        return try await api.send(request, as: SearchOut.self)
    }

    public func basket(id: String? = nil) async throws -> BasketViewOut {
        try await api.send(.get("/v1/shopping/baskets", query: [URLQueryItem(name: "basket_id", value: id)]),
                           as: BasketViewOut.self)
    }

    public func add(_ body: BasketAddIn) async throws -> BasketChangeOut {
        var request = try APIRequest.json(.post, "/v1/shopping/baskets/items", body: body)
        request.query = conversation
        return try await api.send(request, as: BasketChangeOut.self)
    }

    public func setQuantity(itemId: String, quantity: Int) async throws -> BasketChangeOut {
        struct Body: Encodable { let quantity: Int }
        return try await api.send(
            .json(.patch, "/v1/shopping/items/\(APIRequest.segment(itemId))", body: Body(quantity: quantity)),
            as: BasketChangeOut.self)
    }

    public func remove(itemId: String) async throws -> BasketChangeOut {
        try await api.send(.delete("/v1/shopping/items/\(APIRequest.segment(itemId))"), as: BasketChangeOut.self)
    }

    public func record(_ body: PriceRecord) async throws -> RecordPriceOut {
        try await api.send(.json(.post, "/v1/shopping/observations", body: body), as: RecordPriceOut.self)
    }

    public func compare(basketId: String?) async throws -> CompareOut {
        try await api.send(.json(.post, "/v1/shopping/compare", body: CompareIn(basketId: basketId)), as: CompareOut.self)
    }

    public func checkout(_ body: CheckoutIn) async throws -> CheckoutRun {
        try await api.send(.json(.post, "/v1/shopping/checkout", body: body), as: CheckoutRun.self)
    }

    public func shortlist() async throws -> [ShortlistEntry] {
        try await api.send(.get("/v1/shopping/shortlist"), as: [ShortlistEntry].self)
    }

    public func shortlistAdd(ref: String) async throws -> ShortlistOut {
        var request = try APIRequest.json(.post, "/v1/shopping/shortlist", body: ProductPick(ref: ref))
        request.query = conversation
        return try await api.send(request, as: ShortlistOut.self)
    }
}
