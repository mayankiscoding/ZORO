import CommerceSupport
import SwiftUI
import ZoroCore
import ZoroDesign

/// The Finance space. Read-only: everything here comes from statements the owner imported.
public struct FinanceDashboardView: View {
    @Environment(\.zoroServices) private var services
    @Environment(\.commerceFileUploader) private var uploader

    public init() {}

    public var body: some View {
        FinanceSpace(client: FinanceClient(api: services.api, uploader: uploader))
    }
}

struct FinanceSpace: View {
    let client: FinanceClient
    @State private var model: FinanceDashboardViewModel

    init(client: FinanceClient) {
        self.client = client
        _model = State(initialValue: FinanceDashboardViewModel(client: client))
    }

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: ZoroSpace.l.value, alignment: .top)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ZoroSpace.l.value) {
                    Label(FinanceDashboardViewModel.readOnlyNotice, systemImage: "lock")
                        .zoroText(.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    destinations
                    if model.phase == .loaded {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: ZoroSpace.l.value) {
                            monthCard
                            categoriesCard
                            incomeCard
                            forecastCard
                        }
                        alertsSection
                    } else {
                        PhaseStateView(model.phase, loading: "Adding up this month.",
                                       empty: "No transactions yet. Import a bank or card statement to see your month.") {
                            Task { await model.load() }
                        }
                    }
                }
                .padding(ZoroSpace.l.value)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(ZoroNeutral.background)
            .navigationTitle("Finance")
            .task { await model.load() }
            .refreshable { await model.load() }
        }
    }

    private var destinations: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ZoroSpace.s.value) {
                NavigationLink("Transactions") { TransactionsView(model: TransactionsViewModel(client: client)) }
                NavigationLink("Import a statement") { StatementImportView(model: StatementImportViewModel(client: client)) }
                NavigationLink("Budgets") { BudgetsView(model: BudgetsViewModel(client: client)) }
                NavigationLink("Recurring payments") { RecurringView(model: RecurringViewModel(client: client)) }
            }
            .buttonStyle(.zoroSecondary)
        }
    }

    @ViewBuilder private var monthCard: some View {
        if let s = model.summary {
            ZoroCard {
                VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                    Text(s.period.labelEn.prefix(1).uppercased() + s.period.labelEn.dropFirst()).zoroText(.heading)
                    MoneyText(s.spent, textStyle: .amountHero)
                    Text("spent across \(s.transactions) transactions").zoroText(.detail).foregroundStyle(.secondary)
                    FigureRow("Received", value: Figures.money(s.received))
                    FigureRow("Net", value: Figures.money(s.net), role: s.net < 0 ? .critical : nil)
                    Text("\(s.period.start.shortDisplay) to \(s.period.end.shortDisplay), from your imported statements")
                        .zoroText(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var categoriesCard: some View {
        ZoroCard {
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                Text("Where it went").zoroText(.heading)
                if let failure = model.partFailures["categories"], model.breakdown == nil {
                    Text(failure).zoroText(.detail)
                } else if model.categoryValues.isEmpty {
                    Text("No spending this month yet.").zoroText(.detail).foregroundStyle(.secondary)
                } else {
                    CategoryBarChart(model.categoryValues)
                }
            }
        }
    }

    @ViewBuilder private var incomeCard: some View {
        ZoroCard {
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                Text("Income and expenses").zoroText(.heading)
                if let ie = model.incomeExpense {
                    FigureRow("Income \(ie.period.labelEn)", value: Figures.money(ie.income))
                    FigureRow("Expenses", value: Figures.money(ie.expense))
                    FigureRow("Saved", value: ie.savingsRatePct.map { Figures.percent($0) } ?? "No income recorded")
                    if model.netTrend.count > 1 {
                        Text("Net by month").zoroText(.caption).foregroundStyle(.secondary)
                        TrendLineChart(model.netTrend)
                    }
                } else {
                    Text(model.partFailures["income"] ?? "Loading.").zoroText(.detail)
                }
            }
        }
    }

    @ViewBuilder private var forecastCard: some View {
        ZoroCard {
            VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                Text("Next \(model.forecast?.horizonDays ?? 30) days").zoroText(.heading)
                if let f = model.forecast, let range = model.forecastRange {
                    Text("Expected out: \(range).").zoroText(.body).fixedSize(horizontal: false, vertical: true)
                    FigureRow("Expected in", value: Figures.money(f.expectedInflow))
                    Text("How: \(f.method). A forecast, not a promise.").zoroText(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(model.partFailures["forecast"] ?? "Loading.").zoroText(.detail)
                }
            }
        }
    }

    @ViewBuilder private var alertsSection: some View {
        if !model.alerts.isEmpty || model.partFailures["alerts"] != nil {
            ZoroSectionHeader("Alerts")
            if let failure = model.partFailures["alerts"] { Text(failure).zoroText(.detail) }
            ForEach(model.alerts, id: \.self) { alert in
                Label(alert.message, systemImage: alert.kind == "budget_exceeded" ? "exclamationmark.circle" : "bell")
                    .zoroText(.body)
                    .foregroundStyle(alert.kind == "budget_exceeded" ? AnyShapeStyle(ZoroRole.critical.style) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
