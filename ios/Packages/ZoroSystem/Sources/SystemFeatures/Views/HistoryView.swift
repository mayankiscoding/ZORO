import SwiftUI
import ZoroCore
import ZoroDesign

/// Conversation history: list, open, delete.
public struct HistoryView: View {
    @Bindable var model: HistoryViewModel
    @State private var deleting: ConversationSummary?

    public init(model: HistoryViewModel) { self.model = model }

    public var body: some View {
        ScreenScroll {
            NoticeBanner(notice: model.notice, dismiss: model.dismissNotice)
            PhaseView(phase: model.phase, loadingMessage: "Loading your conversations.", emptyMessage: model.emptyMessage, retry: { await model.load() }) {
                list
            }
        }
        .navigationTitle("History")
        .systemInlineTitle()
        .searchable(text: $model.searchText, prompt: "Search conversations")
        .task { if model.phase == .idle { await model.load() } }
        .refreshable { await model.load() }
        .navigationDestination(isPresented: Binding(get: { model.opened != nil }, set: { if !$0 { model.closeConversation() } })) {
            ConversationDetailView(model: model)
        }
        .confirmationDialog(
            "Delete this conversation?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting
        ) { conversation in
            Button("Delete", role: .destructive) { Task { await model.delete(conversation) } }
            Button("Keep it", role: .cancel) {}
        } message: { _ in
            Text("It's removed from your server and this device. You can't undo it.")
        }
    }

    @ViewBuilder private var list: some View {
        if model.visibleConversations.isEmpty {
            ZoroCard { ZoroStateView(.empty, message: model.emptyMessage) }
        } else {
            ZoroCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.visibleConversations.enumerated()), id: \.element.id) { index, conversation in
                        if index > 0 { RowDivider() }
                        HStack(alignment: .top) {
                            Button {
                                Task { await model.open(conversation) }
                            } label: {
                                VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
                                    Text(conversation.title).zoroText(.body).multilineTextAlignment(.leading)
                                    if !conversation.lastMessagePreview.isEmpty {
                                        Text(conversation.lastMessagePreview).zoroText(.detail).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                                    }
                                    Text("\(dateText(conversation.updatedAt)), \(conversation.messageCount) messages").zoroText(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if model.canDelete {
                                Button("Delete") { deleting = conversation }
                                    .buttonStyle(ZoroLinkButtonStyle(role: .critical))
                                    .disabled(model.isDeleting(conversation.id))
                                    .accessibilityLabel("Delete \(conversation.title)")
                            }
                        }
                        .padding(.vertical, ZoroSpace.m.value)
                    }
                    if model.hasMore {
                        RowDivider()
                        Button(model.isLoadingMore ? "Loading" : "Show more") { Task { await model.loadMore() } }
                            .buttonStyle(.zoroLink).padding(.vertical, ZoroSpace.m.value).disabled(model.isLoadingMore)
                    }
                }
            }
        }
    }
}

/// One opened conversation. The owner's words in SF Pro, ZORO's in New York.
public struct ConversationDetailView: View {
    let model: HistoryViewModel

    public init(model: HistoryViewModel) { self.model = model }

    public var body: some View {
        ScreenScroll {
            if let opened = model.opened {
                Text(opened.title).zoroText(.title).accessibilityAddTraits(.isHeader)
                if model.onContinue != nil {
                    Button("Continue this conversation") { model.continueOpened() }.buttonStyle(.zoroPrimary)
                }
            }
            PhaseView(phase: model.messagesPhase, loadingMessage: "Loading the conversation.", emptyMessage: "This conversation has no messages saved.", retry: {
                if let opened = model.opened { await model.open(opened) }
            }) {
                ZoroCard {
                    VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
                        ForEach(model.messages) { message in
                            VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                                Text(message.role == .user ? "You" : "ZORO").zoroText(.caption).foregroundStyle(.secondary)
                                Text(message.text).zoroText(message.role == .user ? .ownerVoice : .zoroBody).fixedSize(horizontal: false, vertical: true)
                                Text(dateText(message.createdAt)).zoroText(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if model.hasMoreMessages {
                            Button(model.isLoadingMoreMessages ? "Loading" : "Show more") { Task { await model.loadMoreMessages() } }
                                .buttonStyle(.zoroLink).disabled(model.isLoadingMoreMessages)
                        }
                    }
                }
            }
        }
        .navigationTitle(model.opened?.title ?? "Conversation")
        .systemInlineTitle()
    }
}
