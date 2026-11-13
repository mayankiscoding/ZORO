import Foundation
import ZoroCore

/// Items from a cursor-paginated endpoint. Appends pages without duplicates and stops when the server
/// returns no cursor, an empty cursor, the cursor it was just asked with (a loop) or an empty page.
public struct PageAccumulator<Item: Codable & Sendable & Equatable>: Sendable {
    public private(set) var items: [Item] = []
    public private(set) var nextCursor: String?
    public private(set) var pagesLoaded = 0
    private let idOf: @Sendable (Item) -> String

    public init(id: @escaping @Sendable (Item) -> String) {
        idOf = id
    }

    public var hasMore: Bool { nextCursor != nil }

    public mutating func reset(with page: Page<Item>) {
        clear()
        append(page, requestedCursor: nil)
    }

    public mutating func clear() {
        items = []
        nextCursor = nil
        pagesLoaded = 0
    }

    /// - Parameter requestedCursor: the cursor the page was fetched with.
    public mutating func append(_ page: Page<Item>, requestedCursor: String?) {
        var seen = Set(items.map(idOf))
        for item in page.items where seen.insert(idOf(item)).inserted { items.append(item) }
        pagesLoaded += 1
        if let next = page.nextCursor, !next.isEmpty, next != requestedCursor, !page.items.isEmpty {
            nextCursor = next
        } else {
            nextCursor = nil
        }
    }

    public mutating func remove(id: String) {
        let idOf = idOf
        items.removeAll { idOf($0) == id }
    }

    public mutating func replace(_ item: Item) {
        let id = idOf(item)
        if let i = items.firstIndex(where: { idOf($0) == id }) { items[i] = item }
    }

    public mutating func insert(_ item: Item, at index: Int) {
        let id = idOf(item)
        guard !items.contains(where: { idOf($0) == id }) else { return }
        items.insert(item, at: min(max(index, 0), items.count))
    }
}
