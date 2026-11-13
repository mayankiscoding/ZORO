import Foundation
import ZoroCore

/// Walks cursor-paginated endpoints (`Page`). Stops at a nil or empty cursor, after `maxPages`, and
/// fails with `ZoroError.invalidResponse` when the server repeats a cursor (a loop).
public enum Pagination {
    public typealias Fetch<T: Codable & Sendable & Equatable> = @Sendable (_ cursor: String?) async throws -> Page<T>

    public static func pages<T: Codable & Sendable & Equatable>(
        maxPages: Int = 100, fetch: @escaping Fetch<T>
    ) -> AsyncThrowingStream<[T], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var cursor: String?
                    var seen: Set<String> = []
                    for _ in 0..<maxPages {
                        try Task.checkCancellation()
                        let page = try await fetch(cursor)
                        continuation.yield(page.items)
                        guard let next = page.nextCursor, !next.isEmpty else { break }
                        guard seen.insert(next).inserted else { throw ZoroError.invalidResponse("pagination cursor repeated") }
                        cursor = next
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ZoroError.wrap(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Collects up to `maxItems` items across pages.
    public static func collect<T: Codable & Sendable & Equatable>(
        maxItems: Int = 1000, maxPages: Int = 100, fetch: @escaping Fetch<T>
    ) async throws -> [T] {
        var out: [T] = []
        for try await items in pages(maxPages: maxPages, fetch: fetch) {
            out.append(contentsOf: items)
            if out.count >= maxItems { return Array(out.prefix(maxItems)) }
        }
        return out
    }
}
