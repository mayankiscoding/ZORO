import LifeSupport
import SwiftUI
import ZoroCore
import ZoroDesign

/// Search your photos in your own words. The photos stay on this device; the grid shows the real photos by their Photos identifier.
public struct PhotoSearchView: View {
    @Environment(\.zoroServices) private var services
    @Environment(\.limitedLibraryPresenter) private var picker
    @State private var model: PhotoSearchViewModel?

    public init() {}

    public var body: some View {
        Group {
            if let model {
                PhotoSearchContent(model: model)
            } else {
                ZoroStateView(.loading, message: "Getting your photo search ready.")
            }
        }
        .task {
            if model == nil { model = PhotoSearchViewModel(services: services, picker: picker) }
            await model?.onAppear()
            await model?.monitorIndex()
        }
    }
}

struct PhotoSearchContent: View {
    @Bindable var model: PhotoSearchViewModel
    @State private var confirmingDelete = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoroSpace.xl.value) {
                VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                    Text("Photos").zoroText(.title).accessibilityAddTraits(.isHeader)
                    Text("Describe a photo in your own words. Searching happens on this device and your photos do not leave it.")
                        .zoroText(.body).foregroundStyle(.secondary)
                }
                searchField
                if let access = model.access { accessCard(access) }
                results
                indexCard
            }
            .padding(ZoroSpace.l.value)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(ZoroNeutral.background)
        .navigationTitle("Photos")
        .confirmationDialog("Delete the photo index?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete index", role: .destructive) { Task { await model.deleteIndex() } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Your photos are not touched. Search stops working until you build the index again.")
        }
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
            HStack(spacing: ZoroSpace.s.value) {
                TextField("Try: photos from yesterday with a blue cap", text: $model.queryText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { Task { await model.search() } }
                    .accessibilityLabel("Describe the photo you want")
                Button("Search") {
                    searchFocused = false
                    Task { await model.search() }
                }
                .buttonStyle(ZoroPrimaryButtonStyle())
                .frame(maxWidth: 140)
                .disabled(!model.canSearch)
            }
            if !model.chips.isEmpty {
                Text("How ZORO understood it").zoroText(.caption).foregroundStyle(.secondary)
                ChipFlow(chips: model.chips)
                if let note = model.understoodNote { Text(note).zoroText(.caption).foregroundStyle(.secondary) }
                ForEach(model.parsed?.assumptions ?? [], id: \.self) { Text($0).zoroText(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func accessCard(_ access: PhotoAccessPresentation) -> some View {
        ZoroCard {
            VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                Label(access.message, systemImage: access.symbol).zoroText(.body).fixedSize(horizontal: false, vertical: true)
                if let title = access.actionTitle, let action = access.action {
                    Button(title) { Task { await model.perform(action) } }
                        .buttonStyle(ZoroSecondaryButtonStyle()).frame(maxWidth: 300)
                }
            }
        }
    }

    @ViewBuilder private var results: some View {
        switch model.phase {
        case .idle:
            ZoroStateView(.empty, message: "Type what you remember, like \u{201C}screenshots from last week that say boarding pass\u{201D}, then tap Search.")
        case .searching:
            ZoroStateView(.loading, message: "Searching your photos.")
        case .failed(let failure):
            ZoroStateView(
                failure.kind == .disconnected ? .disconnected : .error, message: failure.message,
                action: failure.retryable ? ZoroStateAction("Try again") { Task { await model.search() } } : nil)
        case .noResults:
            ZoroStateView(.empty, message: model.emptyMessage)
        case .results:
            VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                ZoroSectionHeader(
                    model.hits.count == 1 ? "1 photo" : "\(model.hits.count) photos",
                    detail: "\(LifeFormat.count(model.indexedCount)) photos are indexed.")
                PhotoGrid(items: model.hits.map { hit in
                    .init(
                        id: hit.assetId,
                        accessibilityText: PhotoHitPresenter.accessibilityLabel(
                            capturedAt: hit.capturedAt, labels: hit.labels, matched: hit.matched, now: model.now, timeZone: .current))
                })
                if model.nextCursor != nil {
                    Button(model.isLoadingMore ? "Loading more" : "Show more") { Task { await model.loadMore() } }
                        .buttonStyle(ZoroSecondaryButtonStyle()).frame(maxWidth: 300).disabled(model.isLoadingMore)
                }
            }
        }
    }

    private var indexCard: some View {
        let index = model.index
        return VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
            ZoroSectionHeader("Photo index")
            ZoroCard {
                VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                    Label(index.headline, systemImage: index.symbol).zoroText(.heading)
                    Text(index.detail).zoroText(.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let progress = index.progress {
                        ProgressView(value: progress).accessibilityLabel("Indexing progress").accessibilityValue("\(Int((progress * 100).rounded())) percent")
                    }
                    if let last = index.lastRun { Text(last).zoroText(.caption).foregroundStyle(.secondary) }
                    switch model.indexAction {
                    case .rebuilding: ZoroStateView(.loading, message: "Rebuilding the index. You can keep searching meanwhile.")
                    case .deleting: ZoroStateView(.loading, message: "Deleting the index.")
                    case .failed(let message): ZoroStateView(.error, message: message)
                    case .idle: EmptyView()
                    }
                    HStack(spacing: ZoroSpace.m.value) {
                        Button(index.rebuildTitle) { Task { await model.rebuildIndex() } }
                            .buttonStyle(ZoroSecondaryButtonStyle())
                            .disabled(!index.canRebuild || model.indexAction == .rebuilding || model.indexAction == .deleting)
                        Button("Delete index") { confirmingDelete = true }
                            .buttonStyle(ZoroSecondaryButtonStyle(role: .critical))
                            .disabled(!index.canDelete || model.indexAction == .rebuilding || model.indexAction == .deleting)
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }
}
