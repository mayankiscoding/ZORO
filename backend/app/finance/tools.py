"""Finance tools. Reads are LOW risk (read-only, safe to re-run); set_budget and recategorize are
MEDIUM and change only ZORO's own records, never an account."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import date
from decimal import Decimal
from typing import Annotated, Any

from pydantic import AfterValidator, BeforeValidator, Field, model_validator

from app.core.errors import ValidationFailed
from app.core.money import format_inr, to_paise
from app.core.types import AgentId, DataClass, RiskLevel
from app.finance import summaries as s
from app.finance.analytics import FinanceAnalytics, SearchFilters
from app.finance.categories import CategoryConfigSource
from app.finance.insights import FinanceInsights
from app.finance.periods import Period, PeriodError, local_today, resolve_period
from app.finance.schemas import (
    BudgetStatus,
    CashflowForecast,
    CategoryBreakdown,
    ChannelName,
    Direction,
    FModel,
    IncomeExpense,
    MerchantReport,
    RecurringReport,
    SpendingSummary,
    TransactionList,
    TransactionOut,
)
from app.schemas.common import LabelValue
from app.tools.spec import ApprovalView, ToolContext, ToolSpec

READ = "finance.read"
WRITE = "finance.write"
GROUP = "finance-mcp"
AGENTS = frozenset({AgentId.FINANCE, AgentId.PERSONAL_ASSISTANT, AgentId.VOICE})
WRITE_AGENTS = frozenset({AgentId.FINANCE, AgentId.PERSONAL_ASSISTANT})
WORKING_SET = "transactions"


def _check_period(value: str) -> str:
    try:
        resolve_period(value, date(2000, 1, 15))
    except PeriodError as exc:
        raise ValueError(str(exc)) from exc
    return value.strip().lower()


def _no_float(value: object) -> object:
    if isinstance(value, float):
        raise ValueError("send amounts as decimal strings")
    return value


PeriodKey = Annotated[str, AfterValidator(_check_period)]
Rupees = Annotated[Decimal, BeforeValidator(_no_float)]
PERIOD_HELP = ("this_month, last_month, this_year, last_year, last_N_days, this_week, last_week, today, "
               "yesterday, YYYY-MM, YYYY or YYYY-MM-DD..YYYY-MM-DD")  # fmt: skip


class PeriodIn(FModel):
    period: PeriodKey = Field(default="this_month", description=PERIOD_HELP)


class SpendingSummaryIn(PeriodIn):
    category: str | None = None


class TransactionsSearchIn(PeriodIn):
    period: PeriodKey = Field(default="last_30_days", description=PERIOD_HELP)
    query: str | None = Field(default=None, max_length=100)
    category: str | None = None
    merchant: str | None = Field(default=None, max_length=100)
    direction: Direction | None = None
    channel: ChannelName | None = None
    min_amount: Rupees | None = Field(default=None, ge=0)
    max_amount: Rupees | None = Field(default=None, ge=0)
    limit: int = Field(default=10, ge=1, le=50)


class CategoryBreakdownIn(PeriodIn):
    direction: Direction = "debit"


class IncomeExpenseIn(PeriodIn):
    period: PeriodKey = Field(default="this_year", description=PERIOD_HELP)


class MerchantReportIn(PeriodIn):
    merchant: str | None = Field(default=None, max_length=100)


class RecurringIn(FModel):
    pass


class BudgetStatusIn(FModel):
    category: str | None = None


class CashflowForecastIn(FModel):
    horizon_days: int = Field(default=30, ge=7, le=90)


class SetBudgetIn(FModel):
    category: str = Field(min_length=1, max_length=40)  # a category id or "all"
    limit: Rupees = Field(gt=0, max_digits=14, decimal_places=2)


class SetBudgetOut(FModel):
    budget_id: str
    category: str
    name: str
    limit: Decimal
    period: str = "monthly"


class RecategorizeIn(FModel):
    transaction_id: str | None = None
    position: int | None = Field(default=None, ge=1, le=50)  # 1-based, in the list last shown
    category: str = Field(min_length=1, max_length=40)
    apply_to_merchant: bool = False

    @model_validator(mode="after")
    def _target(self) -> RecategorizeIn:
        if (self.transaction_id is None) == (self.position is None):
            raise ValueError("give exactly one of transaction_id or position")
        return self


class RecategorizeOut(FModel):
    transaction: TransactionOut
    category_name: str
    changed: int
    rule_created: bool


@dataclass(frozen=True)
class FinanceServices:
    analytics: FinanceAnalytics
    insights: FinanceInsights
    categories: CategoryConfigSource


def today(ctx: ToolContext) -> date:
    return local_today(ctx.now(), ctx.timezone)


def _period(ctx: ToolContext, key: str) -> Period:
    return resolve_period(key, today(ctx))


def _known(svc: FinanceServices, category: str | None) -> str | None:
    if category is not None and svc.categories.current().get(category) is None:
        raise ValidationFailed(f"unknown category: {category}", code="unknown_category")
    return category


def build_tools(svc: FinanceServices) -> list[ToolSpec]:
    a, ins = svc.analytics, svc.insights

    async def spending_summary(ctx: ToolContext, args: SpendingSummaryIn) -> SpendingSummary:
        return await a.spending_summary(_period(ctx, args.period), _known(svc, args.category))

    async def transactions_search(ctx: ToolContext, args: TransactionsSearchIn) -> TransactionList:
        filters = SearchFilters(
            query=args.query, category=_known(svc, args.category), merchant=args.merchant,
            direction=args.direction, channel=args.channel,
            min_paise=to_paise(args.min_amount) if args.min_amount is not None else None,
            max_paise=to_paise(args.max_amount) if args.max_amount is not None else None,
        )  # fmt: skip
        result = await a.search(_period(ctx, args.period), filters, limit=args.limit)
        await ctx.set_working_set(
            WORKING_SET, [{"id": t.id, "counterparty": t.counterparty} for t in result.items]
        )
        return result

    async def category_breakdown(ctx: ToolContext, args: CategoryBreakdownIn) -> CategoryBreakdown:
        return await a.category_breakdown(_period(ctx, args.period), args.direction)

    async def income_expense(ctx: ToolContext, args: IncomeExpenseIn) -> IncomeExpense:
        return await a.income_expense(_period(ctx, args.period))

    async def merchant_report(ctx: ToolContext, args: MerchantReportIn) -> MerchantReport:
        return await a.merchant_report(_period(ctx, args.period), args.merchant)

    async def recurring(ctx: ToolContext, args: RecurringIn) -> RecurringReport:
        return await ins.recurring(today(ctx))

    async def budget_status(ctx: ToolContext, args: BudgetStatusIn) -> BudgetStatus:
        return await ins.budget_status(_period(ctx, "this_month"), args.category)

    async def cashflow_forecast(ctx: ToolContext, args: CashflowForecastIn) -> CashflowForecast:
        return await ins.forecast(today(ctx), args.horizon_days)

    async def set_budget(ctx: ToolContext, args: SetBudgetIn) -> SetBudgetOut:
        budget_id, limit = await ins.set_budget(args.category, args.limit)
        name = "all spending" if args.category == "all" else svc.categories.current().name(args.category)
        return SetBudgetOut(budget_id=budget_id, category=args.category, name=name, limit=limit)

    async def recategorize(ctx: ToolContext, args: RecategorizeIn) -> RecategorizeOut:
        txn_id = args.transaction_id
        if txn_id is None:
            shown = await ctx.working_set(WORKING_SET)
            if args.position is None or args.position > len(shown):
                raise ValidationFailed("that item is not in the list last shown", code="not_in_working_set")
            txn_id = str(shown[args.position - 1]["id"])
        out, changed = await ins.recategorize(txn_id, args.category, apply_to_merchant=args.apply_to_merchant)
        return RecategorizeOut(transaction=out, category_name=svc.categories.current().name(args.category),
                               changed=changed, rule_created=args.apply_to_merchant)  # fmt: skip

    def budget_view(args: SetBudgetIn) -> ApprovalView:
        return ApprovalView(
            title="Set a monthly budget",
            summary=f"Monthly budget for {args.category}: {format_inr(args.limit)}",
            details=(LabelValue(label="category", value=args.category),
                     LabelValue(label="monthly limit", value=format_inr(args.limit))),
        )  # fmt: skip

    def recat_view(args: RecategorizeIn) -> ApprovalView:
        target = args.transaction_id or f"item {args.position} in the last list"
        scope = "and every transaction from the same merchant" if args.apply_to_merchant else "only"
        return ApprovalView(
            title="Change a transaction's category",
            summary=f"Move {target} to {args.category} ({scope})",
            details=(LabelValue(label="transaction", value=target), LabelValue(label="category", value=args.category),
                     LabelValue(label="apply to merchant", value="yes" if args.apply_to_merchant else "no")),
        )  # fmt: skip

    def spec(
        name: str, description: str, input_model: Any, output_model: Any,
        handler: Callable[[ToolContext, Any], Awaitable[Any]], summarizer: Callable[[Any, str], str],
        card: Callable[[Any], Any] | None = s.summary_card, *, write: bool = False,
        approval_view: Callable[[Any], ApprovalView] | None = None,
    ) -> ToolSpec:  # fmt: skip
        return ToolSpec(
            name=name, description=description, input_model=input_model, output_model=output_model,
            handler=handler, risk=RiskLevel.MEDIUM if write else RiskLevel.LOW,
            data_classes=frozenset({DataClass.FINANCIAL}), permission=WRITE if write else READ,
            agents=WRITE_AGENTS if write else AGENTS, mcp_group=GROUP, summarizer=summarizer, card=card,
            approval_view=approval_view, rate_limit_per_min=20 if write else 60,
        )  # fmt: skip

    return [
        spec("finance.spending_summary", "Total spent and received in a period, optionally for one category.",
             SpendingSummaryIn, SpendingSummary, spending_summary, s.spending_summary),
        spec("finance.transactions_search", "Find imported transactions by period, text, category, merchant, "
             "direction, channel or amount range.", TransactionsSearchIn, TransactionList, transactions_search,
             s.transactions, s.transactions_card),
        spec("finance.category_breakdown", "Spending (or income) per category in a period, with shares.",
             CategoryBreakdownIn, CategoryBreakdown, category_breakdown, s.category_breakdown),
        spec("finance.income_expense", "Income versus spending in a period, month by month.",
             IncomeExpenseIn, IncomeExpense, income_expense, s.income_expense),
        spec("finance.merchant_report", "What was paid to one merchant in a period, or the top merchants.",
             MerchantReportIn, MerchantReport, merchant_report, s.merchant_report),
        spec("finance.recurring", "Recurring payments and subscriptions detected in imported transactions.",
             RecurringIn, RecurringReport, recurring, s.recurring),
        spec("finance.budget_status", "Progress against monthly budgets this month.",
             BudgetStatusIn, BudgetStatus, budget_status, s.budget_status),
        spec("finance.cashflow_forecast", "Expected money out and in over the next days, with a range and method.",
             CashflowForecastIn, CashflowForecast, cashflow_forecast, s.cashflow_forecast),
        spec("finance.set_budget", "Set a monthly budget for a category (or 'all').", SetBudgetIn, SetBudgetOut,
             set_budget, s.set_budget, None, write=True, approval_view=budget_view),
        spec("finance.recategorize", "Change a transaction's category; optionally make it the rule for that "
             "merchant.", RecategorizeIn, RecategorizeOut, recategorize, s.recategorize, None, write=True,
             approval_view=recat_view),
    ]  # fmt: skip
