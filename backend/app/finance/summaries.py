"""Spoken one-sentence summaries (en, hi in Devanagari, hinglish romanised) and cards.

Every figure is formatted from the tool result itself (`format_inr`), so the orchestrator's numeric
guard finds each number in the result. The period is always stated.
"""

from __future__ import annotations

from typing import Any

from app.core.money import format_inr
from app.finance.periods import Period
from app.finance.schemas import (
    BudgetStatus,
    CashflowForecast,
    CategoryBreakdown,
    IncomeExpense,
    MerchantReport,
    RecurringReport,
    SpendingSummary,
    TransactionList,
)
from app.schemas.common import UICard

_POINT_DAYS = {"today", "yesterday"}


def _in(period: Period, lang: str) -> str:
    label = period.label(lang)
    if period.key in _POINT_DAYS:
        return label
    return {"hi": f"{label} में", "hinglish": f"{label} mein"}.get(lang, f"in {label}")


def _cap(text: str) -> str:
    return text[:1].upper() + text[1:]


def _pick(lang: str, en: str, hi: str, hinglish: str) -> str:
    return {"hi": hi, "hinglish": hinglish}.get(lang, en)


def spending_summary(r: SpendingSummary, lang: str) -> str:
    spent, got, when = format_inr(r.spent), format_inr(r.received), _in(r.period, lang)
    if r.category:
        name = r.category_name or r.category
        return _pick(
            lang,
            f"You spent {spent} on {name} {when}.",
            f"{when} आपने {name} पर {spent} खर्च किए।",
            f"{when} aapne {name} par {spent} kharch kiye.",
        )
    n = r.transactions
    return _pick(
        lang,
        f"You spent {spent} and received {got} {when}, across {n} transactions.",
        f"{when} आपने {spent} खर्च किए और {got} पाए, कुल {n} लेन-देन।",
        f"{when} aapne {spent} kharch kiye aur {got} paaye, total {n} transactions.",
    )


def category_breakdown(r: CategoryBreakdown, lang: str) -> str:
    total, when = format_inr(r.total), _in(r.period, lang)
    if not r.categories:
        return _pick(
            lang, f"No spending found {when}.", f"{when} कोई खर्च नहीं मिला।", f"{when} koi kharch nahi mila."
        )
    top = r.categories[0]
    return _pick(
        lang,
        f"{_cap(when)} you spent {total}; the biggest category was {top.name} at {format_inr(top.amount)}.",
        f"{when} कुल खर्च {total} रहा; सबसे ज़्यादा {top.name} पर {format_inr(top.amount)}।",
        f"{when} total kharch {total} raha; sabse zyada {top.name} par {format_inr(top.amount)}.",
    )


def income_expense(r: IncomeExpense, lang: str) -> str:
    inc, exp, net, when = format_inr(r.income), format_inr(r.expense), format_inr(r.net), _in(r.period, lang)
    return _pick(
        lang,
        f"{_cap(when)} your income was {inc} and spending {exp}, leaving {net}.",
        f"{when} आपकी आय {inc} और खर्च {exp} रहा, बचत {net}।",
        f"{when} aapki income {inc} aur kharch {exp} raha, bachat {net}.",
    )


def merchant_report(r: MerchantReport, lang: str) -> str:
    total, when = format_inr(r.total), _in(r.period, lang)
    if r.merchant:
        return _pick(
            lang,
            f"You paid {r.merchant} {total} {when}, in {r.count} payments.",
            f"{when} आपने {r.merchant} को {r.count} बार में {total} दिए।",
            f"{when} aapne {r.merchant} ko {r.count} payments mein {total} diye.",
        )
    if not r.merchants:
        return _pick(
            lang,
            f"No payments found {when}.",
            f"{when} कोई भुगतान नहीं मिला।",
            f"{when} koi payment nahi mila.",
        )
    top = r.merchants[0]
    return _pick(
        lang,
        f"Your top merchant {when} was {top.merchant} at {format_inr(top.amount)}.",
        f"{when} सबसे ज़्यादा भुगतान {top.merchant} को हुआ: {format_inr(top.amount)}।",
        f"{when} sabse zyada payment {top.merchant} ko hua: {format_inr(top.amount)}.",
    )


def transactions(r: TransactionList, lang: str) -> str:
    n, debit, when = r.count, format_inr(r.total_debit), _in(r.period, lang)
    return _pick(
        lang,
        f"Found {n} transactions {when}, with {debit} going out.",
        f"{when} {n} लेन-देन मिले, जिनमें {debit} ख़र्च हुए।",
        f"{when} {n} transactions mile, jinme {debit} kharch hue.",
    )


def recurring(r: RecurringReport, lang: str) -> str:
    n = len(r.items)
    subs = sum(1 for i in r.items if i.is_subscription)
    monthly = format_inr(r.monthly_total)
    return _pick(
        lang,
        f"You have {n} recurring payments, {subs} of them subscriptions, about {monthly} a month as of {r.as_of.isoformat()}.",
        f"{r.as_of.isoformat()} तक आपके {n} नियमित भुगतान हैं, जिनमें {subs} सदस्यताएँ, हर महीने लगभग {monthly}।",
        f"{r.as_of.isoformat()} tak aapke {n} recurring payments hain, {subs} subscriptions, har mahine lagbhag {monthly}.",
    )


def budget_status(r: BudgetStatus, lang: str) -> str:
    when = _in(r.period, lang)
    if not r.items:
        return _pick(
            lang,
            "You have no budgets set.",
            "आपने कोई बजट तय नहीं किया है।",
            "Aapne koi budget set nahi kiya hai.",
        )
    b = r.items[0]
    spent, limit, used = format_inr(b.spent), format_inr(b.limit), f"{b.used_pct}%"
    return _pick(
        lang,
        f"{_cap(when)} you have used {spent} of your {limit} {b.name} budget ({used}).",
        f"{when} आपने {b.name} के {limit} बजट में से {spent} ख़र्च किए ({used})।",
        f"{when} aapne {b.name} ke {limit} budget mein se {spent} kharch kiye ({used}).",
    )


def cashflow_forecast(r: CashflowForecast, lang: str) -> str:
    exp, lo, hi_, inc = (
        format_inr(v) for v in (r.expected_outflow, r.outflow_low, r.outflow_high, r.expected_inflow)
    )
    d = r.horizon_days
    return _pick(
        lang,
        f"Over the next {d} days expect about {exp} going out (range {lo} to {hi_}) and {inc} coming in.",
        f"अगले {d} दिनों में लगभग {exp} ख़र्च ({lo} से {hi_}) और {inc} आमदनी का अनुमान है।",
        f"Agle {d} din mein lagbhag {exp} kharch ({lo} se {hi_}) aur {inc} income ka anumaan hai.",
    )


def set_budget(r: Any, lang: str) -> str:
    limit = format_inr(r.limit)
    return _pick(
        lang,
        f"Set your monthly {r.name} budget to {limit}.",
        f"आपका मासिक {r.name} बजट {limit} कर दिया।",
        f"Aapka monthly {r.name} budget {limit} set kar diya.",
    )


def recategorize(r: Any, lang: str) -> str:
    t = r.transaction
    amount, n = format_inr(t.amount), r.changed
    return _pick(
        lang,
        f"Moved {t.counterparty} {amount} to {r.category_name}; {n} transactions updated.",
        f"{t.counterparty} {amount} को {r.category_name} में डाल दिया; {n} लेन-देन बदले।",
        f"{t.counterparty} {amount} ko {r.category_name} mein daal diya; {n} transactions update hue.",
    )


def summary_card(result: Any) -> UICard:
    period = getattr(result, "period", None)
    title = f"Finance: {period.label_en}" if isinstance(period, Period) else "Finance"
    return UICard(kind="finance_summary", title=title, payload=result.model_dump(mode="json"))


def transactions_card(result: TransactionList) -> UICard:
    return UICard(kind="transactions", title=f"Transactions: {result.period.label_en}",
                  payload=result.model_dump(mode="json"))  # fmt: skip
