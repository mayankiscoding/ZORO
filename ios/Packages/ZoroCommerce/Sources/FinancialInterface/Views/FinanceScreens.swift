import CommerceSupport
import SwiftUI
import UniformTypeIdentifiers
import ZoroCore
import ZoroDesign

// MARK: - Transactions

struct TransactionsView: View {
    @State var model: TransactionsViewModel

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $model.filters.period) {
                    ForEach(TransactionFilters.periods, id: \.key) { Text($0.title).tag($0.key) }
                }
                Picker("Direction", selection: $model.filters.direction) {
                    Text("Money in and out").tag(TransactionOut.Direction?.none)
                    Text("Money out").tag(Optional(TransactionOut.Direction.debit))
                    Text("Money in").tag(Optional(TransactionOut.Direction.credit))
                }
                Picker("Channel", selection: $model.filters.channel) {
                    Text("Any channel").tag(String?.none)
                    ForEach(TransactionFilters.channels, id: \.self) { Text($0.uppercased() == "UPI" ? "UPI" : $0.capitalized).tag(Optional($0)) }
                }
                HStack {
                    TextField("At least ₹", text: $model.minAmountText)
                    TextField("At most ₹", text: $model.maxAmountText)
                }
                if model.filters != TransactionFilters() {
                    Button("Clear filters") { model.clearFilters() }.buttonStyle(.zoroLink)
                }
            }
            if model.phase == .loaded {
                Section {
                    FigureRow("Out", value: Figures.money(model.totalDebit))
                    FigureRow("In", value: Figures.money(model.totalCredit))
                    Text("\(model.totalCount) transactions in \(model.periodLabel)").zoroText(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(model.items) { tx in
                        TransactionRow(tx: tx)
                            .task { if tx.id == model.items.last?.id { await model.loadMore() } }
                    }
                    if model.isLoadingMore { ZoroStateView(.loading, message: "Loading more transactions.") }
                    if let error = model.loadMoreError {
                        ZoroStateView(.error, message: error, action: ZoroStateAction("Try again") { Task { await model.loadMore() } })
                    } else if model.hasMore && !model.isLoadingMore {
                        Button("Show more") { Task { await model.loadMore() } }.buttonStyle(.zoroLink)
                    }
                }
            } else {
                PhaseStateView(model.phase, loading: "Loading transactions.", empty: model.emptyMessage) {
                    Task { await model.reload() }
                }
            }
        }
        .searchable(text: $model.filters.search, prompt: "Search merchant or narration")
        .navigationTitle("Transactions")
        .task(id: model.filters) { await model.reload() }
    }
}

struct TransactionRow: View {
    let tx: TransactionOut
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
                Text(tx.counterparty.isEmpty ? tx.narration : tx.counterparty).zoroText(.body)
                Text("\(tx.date.shortDisplay) · \(tx.category.replacingOccurrences(of: "_", with: " ")) · \(tx.channel.uppercased())")
                    .zoroText(.caption).foregroundStyle(.secondary)
                if tx.duplicateOf != nil { Text("Possible duplicate").zoroText(.caption).foregroundStyle(ZoroRole.attention.style) }
            }
            Spacer()
            Text(Figures.money(tx.direction == .debit ? -tx.amount : tx.amount, style: .exact))
                .zoroText(.amount)
                .foregroundStyle(tx.direction == .credit ? AnyShapeStyle(ZoroRole.positive.style) : AnyShapeStyle(.primary))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tx.direction == .debit ? "Paid" : "Received") \(Figures.money(tx.amount)), \(tx.counterparty), \(tx.date.display)")
    }
}

// MARK: - Statement import

struct StatementImportView: View {
    @State var model: StatementImportViewModel
    @State private var picking = false

    private static let types: [UTType] = [.pdf, .commaSeparatedText] + [UTType(filenameExtension: "xlsx")].compactMap { $0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
                Text("Import a statement your bank or card gave you: PDF, CSV or Excel (.xlsx), up to 20 MB. ZORO reads it on your server and never asks for bank logins.")
                    .zoroText(.zoroBody).fixedSize(horizontal: false, vertical: true)
                TextField("Account name (optional), like Savings", text: $model.accountName)
                    .textFieldStyle(.roundedBorder)
                stateContent
                if !model.recent.isEmpty {
                    ZoroSectionHeader("Recent imports")
                    ForEach(model.recent) { s in
                        VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
                            Text(s.filename).zoroText(.body)
                            Text(StatementImportViewModel.outcome(s)).zoroText(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(ZoroSpace.l.value)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .navigationTitle("Import a statement")
        .task { await model.loadRecent() }
        .fileImporter(isPresented: $picking, allowedContentTypes: Self.types) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    model.choose(filename: url.lastPathComponent, data: try Data(contentsOf: url))
                } catch {
                    model.chooseFailed(error)
                }
            case .failure(let error):
                model.chooseFailed(error)
            }
        }
    }

    @ViewBuilder private var stateContent: some View {
        switch model.state {
        case .idle:
            Button("Choose a file") { picking = true }.buttonStyle(.zoroPrimary)
        case .chosen(let file):
            Label(file.filename, systemImage: "doc").zoroText(.body)
            Button("Import \(file.filename)") { Task { await model.upload() } }.buttonStyle(.zoroPrimary)
            Button("Choose another file") { picking = true }.buttonStyle(.zoroLink)
        case .rejected(let reason):
            ZoroStateView(.error, message: reason, action: ZoroStateAction("Choose a file") { picking = true })
        case .uploading(let name):
            ZoroStateView(.loading, message: "Reading \(name) on your server.")
        case .finished(let status):
            ZoroCard {
                VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                    Text(StatementImportViewModel.outcome(status)).zoroText(.body).fixedSize(horizontal: false, vertical: true)
                    if let start = status.periodStart, let end = status.periodEnd {
                        Text("Covers \(start.display) to \(end.display)").zoroText(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(status.errors.prefix(5), id: \.self) { issue in
                        Text("Line \(issue.line): \(issue.reason)").zoroText(.caption)
                    }
                }
            }
            Button("Import another") { model.reset() }.buttonStyle(.zoroSecondary)
        case .failed(let failure):
            ZoroStateView(failure.kind == .disconnected ? .disconnected : .error, message: failure.message,
                          action: ZoroStateAction("Start again") { model.reset() })
        }
    }
}

// MARK: - Budgets

struct BudgetsView: View {
    @State var model: BudgetsViewModel
    @State private var category = ""
    @State private var limit = ""

    var body: some View {
        List {
            if model.phase == .loaded {
                ForEach(model.items, id: \.category) { item in
                    let (label, role) = BudgetsViewModel.stateLabel(item)
                    VStack(alignment: .leading, spacing: ZoroSpace.xs.value) {
                        HStack {
                            Text(item.name).zoroText(.body)
                            Spacer()
                            Text("\(Figures.money(item.spent)) of \(Figures.money(item.limit))").zoroText(.amount)
                        }
                        ProgressView(value: min(ZoroChartMath.plotValue(item.usedPct), 100), total: 100)
                            .tint(role.map { AnyShapeStyle($0.style) } ?? AnyShapeStyle(.tint))
                            .accessibilityHidden(true)
                        Text(label).zoroText(.caption).foregroundStyle(role.map { AnyShapeStyle($0.style) } ?? AnyShapeStyle(.secondary))
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                PhaseStateView(model.phase, loading: "Loading budgets.",
                               empty: "No budgets yet. Set a monthly limit below, like 5000 for groceries.") {
                    Task { await model.load() }
                }
            }
            Section("Set a monthly budget") {
                TextField("Category, like groceries", text: $category)
                TextField("Monthly limit in rupees", text: $limit)
                Button("Set budget") { Task { await model.setBudget(category: category.lowercased(), limitText: limit) } }
                    .disabled(category.isEmpty || limit.isEmpty || model.isSaving)
                if let notice = model.notice { NoticeLine(notice) }
            }
        }
        .navigationTitle("Budgets")
        .task { await model.load() }
    }
}

// MARK: - Recurring and subscriptions

struct RecurringView: View {
    @State var model: RecurringViewModel

    var body: some View {
        List {
            if model.phase == .loaded, let report = model.report {
                Section { FigureRow("About each month", value: Figures.money(report.monthlyTotal)) }
                if !model.subscriptions.isEmpty {
                    Section("Subscriptions") { ForEach(model.subscriptions, id: \.merchantKey, content: row) }
                }
                if !model.otherRecurring.isEmpty {
                    Section("Other recurring payments") { ForEach(model.otherRecurring, id: \.merchantKey, content: row) }
                }
            } else {
                PhaseStateView(model.phase, loading: "Looking for repeating payments.",
                               empty: "No repeating payments found yet. Import two or more months of statements to find them.") {
                    Task { await model.load() }
                }
            }
        }
        .navigationTitle("Recurring payments")
        .task { await model.load() }
    }

    private func row(_ item: RecurringItem) -> some View {
        VStack(alignment: .leading, spacing: ZoroSpace.hair.value) {
            Text(item.merchant).zoroText(.body)
            Text(RecurringViewModel.line(item)).zoroText(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
