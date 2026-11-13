"""The research team: seven analysts, each writing a typed section from computed facts only.

fundamental · technical · news and sentiment · quantitative · risk · portfolio manager ·
independent verification. Sections are deterministic text built from the fact sheet. A model may
add an interpretation (task `financial_interpretation`) only when asked and only when the gateway
permits financial data; the verification analyst re-checks every number in every section and in
that narrative, and rejects mismatches and guaranteed-return wording. Not investment advice.
"""

from __future__ import annotations

import json
from datetime import date, datetime
from typing import Any, Literal
from zoneinfo import ZoneInfo

import numpy as np
from pydantic import Field

from app.core.types import AgentId, DataClass, PrivacyMode, TaskClass
from app.investment import indicators as ind
from app.investment.config import AnalyticsConfig
from app.investment.providers.base import ProviderUnavailable
from app.investment.providers.sources import Fundamentals, NewsItem
from app.investment.schemas import NOT_ADVICE, Exchange, HoldingView, Series
from app.investment.verify import Fact, FactSheet, VerificationReport, verify_texts
from app.schemas.common import ZModel

AnalystName = Literal[
    "fundamental", "technical", "news_sentiment", "quantitative", "risk", "portfolio_manager", "verification"
]
IST = ZoneInfo("Asia/Kolkata")


class AnalystSection(ZModel):
    analyst: AnalystName
    title: str
    status: Literal["ok", "unavailable", "rejected"]
    findings: list[str]
    sources: list[str]
    reason: str = ""


class Interpretation(ZModel):
    status: Literal["not_requested", "not_permitted", "unavailable", "accepted", "rejected"]
    text: str | None = None
    problems: list[str] = Field(default_factory=list)


class StockAnalysis(ZModel):
    symbol: str
    exchange: Exchange
    generated_at: datetime
    last_bar: date | None
    freshness: str
    data_sources: list[str]
    sections: list[AnalystSection]
    facts: list[Fact]
    verification: VerificationReport
    interpretation: Interpretation
    disclaimer: str = NOT_ADVICE


def _unavailable(analyst: AnalystName, title: str, reason: str) -> AnalystSection:
    return AnalystSection(
        analyst=analyst, title=title, status="unavailable", findings=[], sources=[], reason=reason
    )


def fundamental_analyst(result: Fundamentals | ProviderUnavailable, sheet: FactSheet) -> AnalystSection:
    title = "Fundamentals"
    if isinstance(result, ProviderUnavailable):
        return _unavailable("fundamental", title, f"Fundamentals source unavailable: {result.reason}.")
    findings: list[str] = []
    for key, label in (("pe_ratio", "P/E"), ("pb_ratio", "P/B"), ("roe_percent", "ROE"),
                       ("debt_to_equity", "Debt to equity"), ("dividend_yield_percent", "Dividend yield")):  # fmt: skip
        value = getattr(result, key)
        if value is not None:
            sheet.add(
                key, label, value, "%" if key.endswith("percent") else "", result.source, result.as_of.date()
            )
            findings.append(f"{label} is {sheet.text(key)}.")
    if not findings:
        return _unavailable("fundamental", title, "The fundamentals source returned no ratios.")
    return AnalystSection(
        analyst="fundamental", title=title, status="ok", findings=findings, sources=[result.source]
    )


def technical_analyst(series: Series, sheet: FactSheet) -> AnalystSection:
    c = series.candles
    close = ind.as_array([x.close for x in c])
    src, day = series.source, c[-1].day
    sheet.add("close", "Last close", c[-1].close, "INR", src, day)
    findings = [f"Last close {sheet.text('close')} on {day.isoformat()}."]
    for n in (20, 50):
        value = ind.last(ind.sma(close, n))
        if value is not None:
            sheet.add(f"sma_{n}_period", "SMA period", n, "bars", src, places=0)
            sheet.add(f"sma_{n}", f"{n}-day average", value, "INR", src, day)
            side = "above" if float(c[-1].close) > value else "below"
            findings.append(f"The close is {side} its {n}-day average of {sheet.text(f'sma_{n}')}.")
    rsi = ind.last(ind.rsi(close, 14))
    if rsi is not None:
        sheet.add("rsi_period", "RSI period", 14, "bars", src, places=0)
        sheet.add("rsi_14", "RSI (14, Wilder)", rsi, "", src, day, places=1)
        zone = "above 70, often read as overbought" if rsi > 70 else (
            "below 30, often read as oversold" if rsi < 30 else "between 30 and 70")  # fmt: skip
        sheet.add("rsi_upper", "RSI upper band", 70, "", "convention", places=0)
        sheet.add("rsi_lower", "RSI lower band", 30, "", "convention", places=0)
        findings.append(f"RSI(14) is {sheet.text('rsi_14')}, {zone}.")
    hist = ind.last(ind.macd(close).histogram)
    if hist is not None:
        sheet.add("macd_histogram", "MACD histogram", hist, "", src, day)
        word = "positive" if hist > 0 else "negative"
        findings.append(f"The MACD histogram is {sheet.text('macd_histogram')} ({word} short-term momentum).")
    if len(findings) == 1:
        findings.append("Too few bars for moving averages, RSI or MACD.")
    return AnalystSection(
        analyst="technical", title="Technical", status="ok", findings=findings, sources=[src]
    )


def news_analyst(result: list[NewsItem] | ProviderUnavailable, sheet: FactSheet) -> AnalystSection:
    title = "News and sentiment"
    if isinstance(result, ProviderUnavailable):
        return _unavailable("news_sentiment", title, f"News source unavailable: {result.reason}.")
    if not result:
        return _unavailable("news_sentiment", title, "No recent news items from the configured source.")
    sources = sorted({n.source for n in result})
    sheet.add("news_count", "News items", len(result), "", ",".join(sources), places=0)
    findings = [f"{sheet.text('news_count')} recent items: " + "; ".join(n.title[:80] for n in result[:3])]
    scored = [n.sentiment for n in result if n.sentiment is not None]
    if scored:
        sheet.add(
            "news_sentiment", "Average source sentiment (-1 to 1)", float(np.mean(scored)), "", sources[0]
        )
        findings.append(f"Average sentiment reported by the source is {sheet.text('news_sentiment')}.")
    return AnalystSection(
        analyst="news_sentiment", title=title, status="ok", findings=findings, sources=sources
    )


def quantitative_analyst(
    series: Series, benchmark: Series | None, cfg: AnalyticsConfig, sheet: FactSheet
) -> AnalystSection:
    c = series.candles
    close = ind.as_array([x.close for x in c])
    src, day = series.source, c[-1].day
    findings: list[str] = []
    for bars, word in ((21, "one-month"), (63, "three-month"), (252, "one-year")):
        if close.size > bars:
            sheet.add(
                f"return_{bars}", f"{word} return", (close[-1] / close[-1 - bars] - 1) * 100, "%", src, day
            )
            findings.append(f"The {word} price return is {sheet.text(f'return_{bars}')}.")
    rets = ind.simple_returns(close)
    if rets.size >= 20:
        sheet.add(
            "volatility",
            "Annualised volatility",
            ind.volatility(rets, cfg.trading_days_per_year) * 100,
            "%",
            src,
            day,
        )
        sheet.add(
            "max_drawdown",
            "Max drawdown in the window",
            ind.max_drawdown(close).max_drawdown * 100,
            "%",
            src,
            day,
        )
        conf = float(cfg.var_confidence_percent) / 100
        sheet.add("var_confidence", "VaR confidence", cfg.var_confidence_percent, "%", "config", places=0)
        sheet.add("var_1d", "One-day historical VaR", ind.historical_var(rets, conf) * 100, "%", src, day)
        findings.append(f"Annualised volatility is {sheet.text('volatility')}; the largest fall from a peak in "
                        f"this window is {sheet.text('max_drawdown')}.")  # fmt: skip
        findings.append(f"At {sheet.text('var_confidence')} confidence, the one-day historical loss did not exceed "
                        f"{sheet.text('var_1d')}.")  # fmt: skip
    if benchmark is not None:
        common = {x.day for x in c} & {x.day for x in benchmark.candles}
        if len(common) >= 30:
            a = ind.as_array([x.close for x in c if x.day in common])
            b = ind.as_array([x.close for x in benchmark.candles if x.day in common])
            sheet.add(
                "beta",
                f"Beta vs {benchmark.instrument.symbol}",
                ind.beta(ind.simple_returns(a), ind.simple_returns(b)),
                "",
                src,
                day,
            )
            findings.append(f"Beta against {benchmark.instrument.symbol} is {sheet.text('beta')}.")
    if not findings:
        return _unavailable("quantitative", "Quantitative", "Fewer than 21 bars imported.")
    return AnalystSection(
        analyst="quantitative", title="Quantitative", status="ok", findings=findings, sources=[src]
    )


def risk_analyst(series: Series, holding: HoldingView | None, sheet: FactSheet) -> AnalystSection:
    c = series.candles
    findings: list[str] = []
    high, low, close = (ind.as_array([getattr(x, f) for x in c]) for f in ("high", "low", "close"))
    atr = ind.last(ind.atr(high, low, close, 14))
    if atr is not None:
        sheet.add("atr_14", "ATR (14)", atr, "INR", series.source, c[-1].day)
        sheet.add(
            "atr_percent", "ATR as % of close", atr / float(c[-1].close) * 100, "%", series.source, c[-1].day
        )
        findings.append(
            f"A typical daily range (ATR) is {sheet.text('atr_14')}, {sheet.text('atr_percent')} of the price."
        )
    if sheet.has("volatility"):
        vol = sheet.get("volatility").value
        level = "high" if vol > 40 else "moderate" if vol > 20 else "low"
        findings.append(f"Volatility of {sheet.text('volatility')} is {level} for a single stock.")
    if holding is not None and holding.weight_percent is not None:
        sheet.add("weight", "Weight in your priced portfolio", holding.weight_percent, "%", holding.source)
        findings.append(f"It is {sheet.text('weight')} of your priced portfolio.")
    if not findings:
        return _unavailable("risk", "Risk", "Not enough history for risk measures.")
    findings.append("Prices can fall further than past data shows.")
    return AnalystSection(
        analyst="risk", title="Risk", status="ok", findings=findings, sources=[series.source]
    )


def portfolio_manager(sheet: FactSheet, holding: HoldingView | None) -> AnalystSection:
    up = down = 0
    for key in ("sma_50", "sma_20"):
        if sheet.has(key):
            above = sheet.get("close").value > sheet.get(key).value
            up, down = up + above, down + (not above)
    if sheet.has("return_63"):
        positive = sheet.get("return_63").value > 0
        up, down = up + positive, down + (not positive)
    sheet.add("signals_up", "Signals pointing up", up, "", "computed", places=0)
    sheet.add("signals_down", "Signals pointing down", down, "", "computed", places=0)
    findings = [f"Of the trend and momentum signals, {sheet.text('signals_up')} point up and "
                f"{sheet.text('signals_down')} point down."]  # fmt: skip
    if holding is not None:
        whole = holding.quantity == holding.quantity.to_integral_value()
        sheet.add(
            "held_qty",
            "Shares you hold",
            holding.quantity,
            "shares",
            holding.source,
            places=0 if whole else 4,
        )
        findings.append(f"You hold {sheet.text('held_qty')} shares.")
        if holding.value is not None and holding.pnl is not None:
            sheet.add(
                "held_value",
                "Value of your holding",
                holding.value,
                "INR",
                holding.price_source or holding.source,
            )
            sheet.add(
                "held_pnl", "Unrealised P&L", holding.pnl, "INR", holding.price_source or holding.source
            )
            findings.append(
                f"Your holding is worth {sheet.text('held_value')} with unrealised P&L of {sheet.text('held_pnl')}."
            )
    findings.append("ZORO does not recommend buying or selling; signals describe the past, not the future.")
    return AnalystSection(analyst="portfolio_manager", title="Portfolio manager", status="ok", findings=findings,
                          sources=["computed from the sections above"])  # fmt: skip


def verification_analyst(
    sections: list[AnalystSection], sheet: FactSheet
) -> tuple[AnalystSection, VerificationReport]:
    report = verify_texts([f for s in sections for f in s.findings], sheet)
    for s in sections:
        section_report = verify_texts(s.findings, sheet)
        if not section_report.passed:
            s.status = "rejected"
            s.reason = "; ".join(section_report.problems + section_report.banned_phrases)[:300]
            s.findings = []
    sheet.add("numbers_checked", "Numbers checked", report.numbers_checked, "", "verification", places=0)
    sheet.add(
        "problems",
        "Problems",
        len(report.problems) + len(report.banned_phrases),
        "",
        "verification",
        places=0,
    )
    text = (f"Checked {sheet.text('numbers_checked')} numbers against the fact sheet; "
            f"{sheet.text('problems')} problems.")  # fmt: skip
    return (
        AnalystSection(analyst="verification", title="Independent verification", status="ok", findings=[text],
                       sources=["fact sheet"]),
        report,
    )  # fmt: skip


async def interpret(
    gateway: Any,
    sheet: FactSheet,
    sections: list[AnalystSection],
    *,
    privacy_mode: PrivacyMode,
    turn_id: str | None,
) -> Interpretation:
    """Optional model narrative over the fact sheet. Kept only if every number checks out."""
    from app.providers.types import ChatMessage, ChatRequest, NoPermittedModel, ProviderError

    if gateway is None:
        return Interpretation(status="unavailable", problems=["no model gateway"])
    facts = [{"label": f.label, "value": str(f.value), "unit": f.unit} for f in sheet.facts()]
    prompt = json.dumps({"facts": facts, "sections": [s.findings for s in sections]}, ensure_ascii=False)
    request = ChatRequest(
        task=TaskClass.FINANCIAL_INTERPRETATION,
        messages=(
            ChatMessage(role="system", content=(
                "Explain these computed stock facts in at most three plain sentences for a retail investor. "
                "Use only numbers that appear in the facts, written exactly. No advice, no predictions, "
                "no promises of returns.")),
            ChatMessage(role="user", content=prompt),
        ),
        data_classes=frozenset({DataClass.FINANCIAL}), privacy_mode=privacy_mode, agent=AgentId.INVESTMENT,
        turn_id=turn_id, max_output_tokens=300,
    )  # fmt: skip
    try:
        response = await gateway.chat(request)
    except NoPermittedModel:
        return Interpretation(status="not_permitted", problems=["no model may receive financial data"])
    except ProviderError as exc:
        return Interpretation(status="unavailable", problems=[exc.kind])
    text = (response.text or "").strip()
    report = verify_texts([text], sheet)
    if not text or not report.passed:
        return Interpretation(
            status="rejected", problems=report.problems + report.banned_phrases or ["empty reply"]
        )
    return Interpretation(status="accepted", text=text)


def freshness(last_bar: date | None, now: datetime) -> str:
    if last_bar is None:
        return "No price data imported."
    age = (now.astimezone(IST).date() - last_bar).days
    return f"Last daily bar {last_bar.isoformat()}, {age} day(s) old. Not live prices."
