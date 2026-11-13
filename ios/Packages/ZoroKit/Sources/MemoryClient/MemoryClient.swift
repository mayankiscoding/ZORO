import Foundation
import ZoroCore

/// Typed client for `/v1/memory`. Export and category deletion carry a `SignedProof` made with the
/// approval key (`export_memory` / `delete_memory_category`).
///
/// Routes (the memory router is owned by the backend memory package):
/// `GET /v1/memory` · `GET /v1/memory/search` · `POST /v1/memory` · `PATCH|DELETE /v1/memory/{id}` ·
/// `GET|PUT /v1/memory/settings` · `POST /v1/memory/export` · `POST /v1/memory/categories/{category}/delete`.
public struct MemoryClient: Sendable {
    public static let basePath = "/v1/memory"
    private let api: any ZoroAPI

    public init(api: any ZoroAPI) {
        self.api = api
    }

    // MARK: - Records

    public func list(
        category: MemoryCategory? = nil, status: MemoryStatus? = nil, cursor: String? = nil, limit: Int? = nil
    ) async throws -> Page<MemoryRecord> {
        var query: [URLQueryItem] = []
        if let category { query.append(URLQueryItem(name: "category", value: category.rawValue)) }
        if let status { query.append(URLQueryItem(name: "status", value: status.rawValue)) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await api.send(.get(Self.basePath, query: query), as: Page<MemoryRecord>.self)
    }

    /// Records awaiting the owner's review (sensitive memories land here first).
    public func pendingReview(cursor: String? = nil, limit: Int? = nil) async throws -> Page<MemoryRecord> {
        try await list(status: .pendingReview, cursor: cursor, limit: limit)
    }

    /// Search; an empty query returns nothing without a request.
    public func search(_ text: String, category: MemoryCategory? = nil, limit: Int = 20) async throws -> [MemoryRecord] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var query = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: String(max(1, min(limit, 100))))]
        if let category { query.append(URLQueryItem(name: "category", value: category.rawValue)) }
        return try await api.send(.get("\(Self.basePath)/search", query: query), as: ListOrPage<MemoryRecord>.self).items
    }

    /// Credentials are never stored in memory: `secret` sensitivity and empty text are rejected locally.
    public func create(_ memory: MemoryCreate) async throws -> MemoryRecord {
        guard !memory.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ZoroError.invalidResponse("a memory needs some text")
        }
        guard memory.sensitivity != .secret else {
            throw ZoroError.unavailable(capability: "Memory", reason: "secrets are never stored in memory")
        }
        return try await api.send(.json(.post, Self.basePath, body: memory), as: MemoryRecord.self)
    }

    public func patch(id: String, _ patch: MemoryPatch) async throws -> MemoryRecord {
        guard patch.text != nil || patch.status != nil || patch.verified != nil else {
            throw ZoroError.invalidResponse("nothing to change")
        }
        return try await api.send(.json(.patch, "\(Self.basePath)/\(APIRequest.segment(id))", body: patch), as: MemoryRecord.self)
    }

    public func verify(id: String) async throws -> MemoryRecord {
        try await patch(id: id, MemoryPatch(verified: true))
    }

    public func delete(id: String) async throws {
        try await api.send(.delete("\(Self.basePath)/\(APIRequest.segment(id))"))
    }

    // MARK: - Settings

    public func settings() async throws -> MemorySettings {
        try await api.send(.get("\(Self.basePath)/settings"), as: MemorySettings.self)
    }

    public func updateSettings(_ settings: MemorySettings) async throws -> MemorySettings {
        guard settings.conversationRetentionDays >= 0,
              settings.categories.allSatisfy({ ($0.retentionDays ?? 1) >= 1 })
        else { throw ZoroError.invalidResponse("retention must be positive") }
        return try await api.send(.json(.put, "\(Self.basePath)/settings", body: settings), as: MemorySettings.self)
    }

    // MARK: - Signed operations

    /// Exports memory (all, or one category). Returns the server's export document unchanged.
    public func export(_ request: MemoryExportRequest) async throws -> Data {
        try await api.sendRaw(.json(.post, "\(Self.basePath)/export", body: request))
    }

    /// Signs `export_memory|{category or all}` with the approval key, then exports.
    public func export(category: MemoryCategory? = nil, signer: any DeviceIdentityProviding, at date: Date = Date()) async throws -> Data {
        let proof = try await signer.signProof(.exportMemory(category), key: .approval, at: date)
        return try await export(MemoryExportRequest(category: category, proof: proof))
    }

    public func deleteCategory(_ category: MemoryCategory, _ request: MemoryDeleteCategoryRequest) async throws {
        try await api.send(.json(.post, "\(Self.basePath)/categories/\(category.rawValue)/delete", body: request))
    }

    /// Signs `delete_memory_category|{category}` with the approval key, then deletes the category.
    public func deleteCategory(_ category: MemoryCategory, signer: any DeviceIdentityProviding, at date: Date = Date()) async throws {
        let proof = try await signer.signProof(.deleteMemoryCategory(category), key: .approval, at: date)
        try await deleteCategory(category, MemoryDeleteCategoryRequest(proof: proof))
    }
}
