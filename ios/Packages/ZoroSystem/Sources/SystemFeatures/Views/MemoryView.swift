import SwiftUI
import UniformTypeIdentifiers
import ZoroCore
import ZoroDesign

/// Personal memory. Categories as chips, a review queue, search, and per-category controls.
public struct MemoryView: View {
    @Bindable var model: MemoryViewModel
    @State private var editing: MemoryRecord?
    @State private var editText = ""
    @State private var deleting: MemoryRecord?
    @State private var showExporter = false

    public init(model: MemoryViewModel) { self.model = model }

    public var body: some View {
        ScreenScroll {
            Text("Memory").zoroText(.title).accessibilityAddTraits(.isHeader)
            Text("What ZORO has saved about you. You can correct, verify or delete any of it.")
                .zoroText(.detail).foregroundStyle(.secondary)
            NoticeBanner(notice: model.notice, dismiss: model.dismissNotice)
            sectionChips
            PhaseView(
                phase: model.phase, loadingMessage: "Loading your memory.", emptyMessage: model.emptyMessage,
                retry: { await model.load() }
            ) {
                content
            }
            if model.phase != .loading && model.phase != .idle, model.selectedCategory != nil, model.settings != nil {
                categoryControls
            }
        }
        .navigationTitle("Memory")
        .systemInlineTitle()
        .searchable(text: $model.searchText, prompt: "Search your memory")
        .task(id: model.searchText) {
            // Pause after typing; a new keystroke cancels this task.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await model.search()
        }
        .task { if model.phase == .idle { await model.load() } }
        .refreshable { await model.load() }
        .sheet(item: $editing) { record in editor(record) }
        .confirmationDialog(
            "Delete this memory?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting
        ) { record in
            Button("Delete", role: .destructive) { Task { await model.delete(record) } }
            Button("Keep it", role: .cancel) {}
        } message: { _ in
            Text("ZORO will forget this. You can't undo it.")
        }
        .confirmationDialog(
            deleteCategoryTitle,
            isPresented: Binding(get: { model.pendingCategoryDelete != nil }, set: { if !$0 { model.cancelDeleteCategory() } }),
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) { Task { await model.confirmDeleteCategory() } }
            Button("Keep it", role: .cancel) { model.cancelDeleteCategory() }
        } message: {
            Text("Your device will ask you to confirm. ZORO forgets every memory in this category. You can't undo it.")
        }
        .fileExporter(
            isPresented: $showExporter, document: model.export.map { MemoryExportDocument(data: $0.data) },
            contentType: .json, defaultFilename: model.export?.suggestedFilename ?? "zoro-memory"
        ) { _ in model.clearExport() }
        .onChange(of: model.export) { _, new in showExporter = new != nil }
    }

    private var deleteCategoryTitle: String {
        "Delete everything in \(model.pendingCategoryDelete.map { MemoryCopy.title($0).lowercased() } ?? "this category")?"
    }

    // MARK: Pieces

    private var sectionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ZoroSpace.s.value) {
                ZoroChip(
                    model.reviewCount > 0 ? "To review (\(model.reviewCount)\(model.reviewCountHasMore ? "+" : ""))" : "To review",
                    symbol: "checkmark.seal", isSelected: model.section == .reviewQueue
                ) { Task { await model.select(.reviewQueue) } }
                ForEach(model.categories, id: \.self) { category in
                    ZoroChip(MemoryCopy.title(category), symbol: MemoryCopy.symbol(category), isSelected: model.section == .category(category)) {
                        Task { await model.select(.category(category)) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if model.isSearching && model.searchResults == nil {
            ZoroStateView(.loading, message: "Searching.")
        } else if model.visibleRecords.isEmpty {
            ZoroCard { ZoroStateView(.empty, message: model.emptyMessage) }
        } else {
            ZoroCard {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.visibleRecords.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { RowDivider() }
                        row(record)
                    }
                    if model.hasMore && !model.isSearchActive {
                        RowDivider()
                        Button(model.isLoadingMore ? "Loading" : "Show more") { Task { await model.loadMore() } }
                            .buttonStyle(.zoroLink).padding(.vertical, ZoroSpace.m.value).disabled(model.isLoadingMore)
                    }
                }
            }
        }
    }

    private func row(_ record: MemoryRecord) -> some View {
        VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
            Text(record.text).zoroText(.zoroBody).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: ZoroSpace.s.value) {
                StatusPill(MemoryCopy.sensitivityLabel(record.sensitivity), role: record.sensitivity.rank >= 2 ? .attention : nil)
                Text(verifiedText(record)).zoroText(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: ZoroSpace.m.value) {
                if record.status == .pendingReview {
                    Button("Keep") { Task { await model.keep(record) } }.buttonStyle(.zoroLink)
                } else {
                    Button("Verify") { Task { await model.verify(record) } }.buttonStyle(.zoroLink)
                }
                if record.userEditable {
                    Button("Correct") { editText = record.text; editing = record }.buttonStyle(.zoroLink)
                }
                Button("Delete") { deleting = record }.buttonStyle(ZoroLinkButtonStyle(role: .critical))
            }
            .disabled(model.busyIds.contains(record.id))
        }
        .padding(.vertical, ZoroSpace.m.value)
        .accessibilityElement(children: .contain)
    }

    private func verifiedText(_ record: MemoryRecord) -> String {
        if let verified = record.lastVerifiedAt { return "Verified \(SystemFormat.relative(verified))" }
        return "From \(record.source), \(dateText(record.createdAt))"
    }

    @ViewBuilder private var categoryControls: some View {
        if let category = model.selectedCategory, let setting = model.setting(for: category) {
            VStack(alignment: .leading, spacing: ZoroSpace.m.value) {
                ZoroSectionHeader(MemoryCopy.title(category), detail: MemoryCopy.detail(category))
                ZoroCard {
                    VStack(alignment: .leading, spacing: 0) {
                        Toggle(isOn: Binding(get: { setting.enabled }, set: { v in Task { await model.setEnabled(v, for: category) } })) {
                            InfoRow("Save things in this category", detail: setting.enabled ? "ZORO is saving here." : "ZORO isn't saving anything here.")
                        }
                        RowDivider()
                        InfoRow("Keep for", detail: "After this, ZORO forgets it on its own.") {
                            Picker("Keep for", selection: Binding(get: { setting.retentionDays ?? 0 }, set: { v in Task { await model.setRetention(days: v == 0 ? nil : v, for: category) } })) {
                                Text("Until I delete it").tag(0)
                                Text("30 days").tag(30)
                                Text("90 days").tag(90)
                                Text("1 year").tag(365)
                            }
                            .labelsHidden()
                        }
                        RowDivider()
                        VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                            Button("Export this category") { Task { await model.exportMemory(category: category) } }
                                .buttonStyle(.zoroSecondary).disabled(model.isWorking)
                            Button("Export everything") { Task { await model.exportMemory(category: nil) } }
                                .buttonStyle(.zoroSecondary).disabled(model.isWorking)
                            Button("Delete everything in this category") { model.requestDeleteCategory(category) }
                                .buttonStyle(ZoroSecondaryButtonStyle(role: .critical)).disabled(model.isWorking)
                        }
                        .padding(.top, ZoroSpace.m.value)
                        Text("Exporting and deleting a category ask you to confirm with Face ID, Touch ID or your passcode.")
                            .zoroText(.caption).foregroundStyle(.secondary).padding(.top, ZoroSpace.s.value)
                    }
                }
            }
        }
    }

    private func editor(_ record: MemoryRecord) -> some View {
        VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
            Text("Correct this memory").zoroText(.heading)
            TextEditor(text: $editText)
                .zoroText(.zoroBody)
                .frame(minHeight: 120)
                .padding(ZoroSpace.s.value)
                .background(ZoroNeutral.inset, in: ZoroRadius.control.shape)
            Button("Save correction") {
                let text = editText
                editing = nil
                Task { await model.correct(record, to: text) }
            }
            .buttonStyle(.zoroPrimary)
            Button("Cancel") { editing = nil }.buttonStyle(.zoroSecondary)
        }
        .padding(ZoroSpace.xl.value)
        .presentationDetents([.medium])
    }
}

/// The export document the file exporter writes: the server's bytes, unchanged.
struct MemoryExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
