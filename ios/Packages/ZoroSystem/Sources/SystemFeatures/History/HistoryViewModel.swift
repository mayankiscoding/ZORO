import ConversationManager
import Foundation
import Observation
import ZoroCore

/// The encrypted on-device copy of conversations. `ConversationStore` conforms.
public protocol LocalConversationStoring: Sendable {
    func conversations(limit: Int) async throws -> [ConversationSummary]
    func messages(in conversationId: String) async throws -> [Message]
    func deleteConversation(id: String) async throws
}

extension ConversationStore: LocalConversationStoring {}

/// Conversation history: list, open, delete. Reads the server's list; when the server can't be
/// reached it shows the copy kept on this device, read-only.
@MainActor
@Observable
public final class HistoryViewModel {
    public enum Source: Equatable, Sendable { case server, thisDevice }

    public private(set) var phase: ScreenPhase = .idle
    public private(set) var source: Source = .server
    public private(set) var conversations: [ConversationSummary] = []
    public private(set) var hasMore = false
    public private(set) var isLoadingMore = false
    public private(set) var notice: SystemNotice?
    public var searchText = ""

    // Opened conversation
    public private(set) var opened: ConversationSummary?
    public private(set) var messagesPhase: ScreenPhase = .idle
    public private(set) var messages: [Message] = []
    public private(set) var hasMoreMessages = false
    public private(set) var isLoadingMoreMessages = false

    /// The app wires this to continue the conversation in the ZORO tab.
    @ObservationIgnored public var onContinue: (@MainActor (String) -> Void)?

    @ObservationIgnored private let api: any ZoroAPI
    @ObservationIgnored private let local: (any LocalConversationStoring)?
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var pages = PageAccumulator<ConversationSummary>(id: { $0.id })
    @ObservationIgnored private var messagePages = PageAccumulator<Message>(id: { $0.id })
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var openGeneration = 0
    private var deleting: Set<String> = []

    public init(api: any ZoroAPI, local: (any LocalConversationStoring)? = nil, pageSize: Int = 30) {
        self.api = api
        self.local = local
        self.pageSize = pageSize
    }

    public var emptyMessage: String {
        searchText.isEmpty ? "No conversations yet. Talk to ZORO and they show up here." : "No conversation matches that. Try different words."
    }

    public var canDelete: Bool { source == .server }

    public var visibleConversations: [ConversationSummary] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return conversations }
        return conversations.filter { $0.title.lowercased().contains(q) || $0.lastMessagePreview.lowercased().contains(q) }
    }

    public func isDeleting(_ id: String) -> Bool { deleting.contains(id) }

    // MARK: - List

    public func load() async {
        phase = .loading
        notice = nil
        generation += 1
        let gen = generation
        do {
            let page = try await api.conversations(cursor: nil, limit: pageSize)
            guard gen == generation else { return }
            source = .server
            pages.reset(with: page)
            publish()
            phase = conversations.isEmpty ? .empty : .loaded
        } catch {
            guard gen == generation, let failure = SystemFailure.phase(for: error) else { return }
            if failure.isDisconnected, let local, let stored = try? await local.conversations(limit: 100), !stored.isEmpty {
                guard gen == generation else { return }
                source = .thisDevice
                pages.clear()
                conversations = stored.sorted { $0.updatedAt > $1.updatedAt }
                hasMore = false
                notice = .failure("Showing conversations saved on this device. \(failure.failure?.message ?? "")")
                phase = .loaded
            } else {
                conversations = []
                hasMore = false
                phase = failure
            }
        }
    }

    public func loadMore() async {
        guard source == .server, !isLoadingMore, let cursor = pages.nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let gen = generation
        do {
            let page = try await api.conversations(cursor: cursor, limit: pageSize)
            guard gen == generation else { return }
            pages.append(page, requestedCursor: cursor)
            publish()
        } catch {
            if let n = SystemNotice.failed(error, action: "Loading more") { notice = n }
        }
    }

    /// Deletes on the server (and the copy on this device). The row leaves at once and returns if the server refuses.
    public func delete(_ conversation: ConversationSummary) async {
        guard canDelete else {
            notice = .failure("Deleting needs your server. Reconnect, then try again.")
            return
        }
        guard !deleting.contains(conversation.id) else { return }
        deleting.insert(conversation.id)
        defer { deleting.remove(conversation.id) }
        let index = pages.items.firstIndex { $0.id == conversation.id } ?? 0
        pages.remove(id: conversation.id)
        publish()
        if opened?.id == conversation.id { closeConversation() }
        if conversations.isEmpty { phase = .empty }
        do {
            try await api.deleteConversation(id: conversation.id)
            try? await local?.deleteConversation(id: conversation.id)
            notice = .success("Deleted.")
        } catch {
            pages.insert(conversation, at: index)
            publish()
            if phase == .empty { phase = .loaded }
            notice = SystemNotice.failed(error, action: "Deleting") ?? .failure("Deleting didn't happen. Nothing was changed.")
        }
    }

    // MARK: - Open

    public func open(_ conversation: ConversationSummary) async {
        opened = conversation
        messages = []
        messagePages.clear()
        hasMoreMessages = false
        messagesPhase = .loading
        openGeneration += 1
        let gen = openGeneration
        if source == .thisDevice, let local {
            do {
                let stored = try await local.messages(in: conversation.id)
                guard gen == openGeneration else { return }
                messages = stored.sorted { $0.createdAt < $1.createdAt }
                messagesPhase = messages.isEmpty ? .empty : .loaded
            } catch {
                guard gen == openGeneration, let next = SystemFailure.phase(for: error) else { return }
                messagesPhase = next
            }
            return
        }
        do {
            let page = try await api.messages(conversationId: conversation.id, cursor: nil, limit: pageSize)
            guard gen == openGeneration else { return }
            messagePages.reset(with: page)
            publishMessages()
            messagesPhase = messages.isEmpty ? .empty : .loaded
        } catch {
            guard gen == openGeneration, let next = SystemFailure.phase(for: error) else { return }
            messagesPhase = next
        }
    }

    public func loadMoreMessages() async {
        guard let opened, !isLoadingMoreMessages, let cursor = messagePages.nextCursor else { return }
        isLoadingMoreMessages = true
        defer { isLoadingMoreMessages = false }
        let gen = openGeneration
        do {
            let page = try await api.messages(conversationId: opened.id, cursor: cursor, limit: pageSize)
            guard gen == openGeneration else { return }
            messagePages.append(page, requestedCursor: cursor)
            publishMessages()
        } catch {
            if let n = SystemNotice.failed(error, action: "Loading more") { notice = n }
        }
    }

    public func closeConversation() {
        openGeneration += 1
        opened = nil
        messages = []
        messagePages.clear()
        hasMoreMessages = false
        messagesPhase = .idle
    }

    /// Continues the opened conversation in the ZORO tab.
    public func continueOpened() {
        guard let opened else { return }
        onContinue?(opened.id)
    }

    public func dismissNotice() { notice = nil }

    private func publish() {
        conversations = pages.items
        hasMore = pages.hasMore
    }

    private func publishMessages() {
        messages = messagePages.items.sorted { $0.createdAt < $1.createdAt }
        hasMoreMessages = messagePages.hasMore
    }
}
