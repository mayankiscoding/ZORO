import CommerceSupport
import Foundation
import SwiftUI
import ZoroCore
import ZoroDesign

/// What a `finance_summary` card carries. The backend uses that one kind for every read tool's result,
/// so the payload is told apart by its fields.
public enum FinanceSummaryPayload: Equatable, Sendable {
    case spending(SpendingSummary)
    case breakdown(CategoryBreakdown)
    case incomeExpense(IncomeExpense)
    case budgets(BudgetStatus)
    case recurring(RecurringReport)
    case forecast(CashflowForecast)

    public static func decode(_ card: UICard) -> FinanceSummaryPayload? {
        guard card.kind == "finance_summary" else { return nil }
        let keys = Set(card.payload.keys)
        if keys.contains("spent"), let v = try? card.decodePayload(SpendingSummary.self) { return .spending(v) }
        if keys.contains("categories"), let v = try? card.decodePayload(CategoryBreakdown.self) { return .breakdown(v) }
        if keys.contains("months"), let v = try? card.decodePayload(IncomeExpense.self) { return .incomeExpense(v) }
        if keys.contains("expected_outflow"), let v = try? card.decodePayload(CashflowForecast.self) { return .forecast(v) }
        if keys.contains("monthly_total"), let v = try? card.decodePayload(RecurringReport.self) { return .recurring(v) }
        if keys.contains("items"), keys.contains("period"), let v = try? card.decodePayload(BudgetStatus.self) { return .budgets(v) }
        return nil
    }
}

public enum FinanceCardDecoding {
    public static func transactions(_ card: UICard) -> TransactionList? {
        guard card.kind == "transactions" else { return nil }
        return try? card.decodePayload(TransactionList.self)
    }
}

struct UnreadableFinanceCard: View {
    let title: String
    var body: some View {
        ZoroCard {
            ZoroStateView(.error, message: "\(title) could not be shown in this version of the app. Ask ZORO again, or open Finance.")
        }
    }
}

/// `finance_summary` card.
public struct FinanceSummaryCardView: View {
    let card: UICard
    let payload: FinanceSummaryPayload?

    public init(card: UICard) {
        self.card = card
        self.payload = FinanceSummaryPayload.decode(card)
    }

    public var body: some View {
        if let payload {
            ZoroCard {
                VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                    Text(card.title ?? "Finance").zoroText(.heading)
                    content(payload)
                    Text("From your imported statements. Read-only.").zoroText(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            UnreadableFinanceCard(title: card.title ?? "This summary")
        }
    }

    @ViewBuilder private func content(_ payload: FinanceSummaryPayload) -> some View {
        switch payload {
        case .spending(let s):
            MoneyText(s.spent, textStyle: .amountHero)
            FigureRow("Received", value: Figures.money(s.received))
            if !s.topCategories.isEmpty {
                CategoryBarChart(s.topCategories.map { CategoryValue(label: $0.name, amount: $0.amount) })
            }
        case .breakdown(let b):
            FigureRow("Total", value: Figures.money(b.total))
            CategoryBarChart(b.categories.map { CategoryValue(label: $0.name, amount: $0.amount) })
        case .incomeExpense(let ie):
            FigureRow("Income", value: Figures.money(ie.income))
            FigureRow("Expenses", value: Figures.money(ie.expense))
            FigureRow("Net", value: Figures.money(ie.net), role: ie.net < 0 ? .critical : nil)
        case .budgets(let b):
            ForEach(b.items, id: \.category) { item in
                FigureRow(item.name, value: BudgetsViewModel.stateLabel(item).0, role: BudgetsViewModel.stateLabel(item).1)
            }
        case .recurring(let r):
            FigureRow("About each month", value: Figures.money(r.monthlyTotal))
            ForEach(r.items, id: \.merchantKey) { Text("\($0.merchant): \(RecurringViewModel.line($0))").zoroText(.detail) }
        case .forecast(let f):
            Text("Expected out \(Figures.money(f.outflowLow)) to \(Figures.money(f.outflowHigh)), most likely \(Figures.money(f.expectedOutflow)).")
                .zoroText(.body).fixedSize(horizontal: false, vertical: true)
            Text("How: \(f.method).").zoroText(.caption).foregroundStyle(.secondary)
        }
    }
}

/// `transactions` card.
public struct TransactionsCardView: View {
    let card: UICard
    let list: TransactionList?

    public init(card: UICard) {
        self.card = card
        self.list = FinanceCardDecoding.transactions(card)
    }

    public var body: some View {
        if let list {
            ZoroCard {
                VStack(alignment: .leading, spacing: ZoroSpace.s.value) {
                    Text(card.title ?? "Transactions").zoroText(.heading)
                    ForEach(list.items.prefix(8)) { TransactionRow(tx: $0) }
                    if list.count > min(list.items.count, 8) {
                        Text("\(list.count) in all. Open Finance to see every one.").zoroText(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            UnreadableFinanceCard(title: card.title ?? "These transactions")
        }
    }
}
