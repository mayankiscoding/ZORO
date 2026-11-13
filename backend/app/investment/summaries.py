"""Speakable one-sentence summaries (en, hi in Devanagari, romanised Hinglish) and cards.

Every number in a sentence comes from the tool result it summarises.
"""

from __future__ import annotations

from typing import Any

from app.core.money import format_inr
from app.investment.backtest import BacktestResult
from app.investment.orders import OrderTicket
from app.investment.paper import PaperTradeOut
from app.investment.research import StockAnalysis
from app.investment.schemas import PortfolioSummary, TechnicalSnapshot
from app.investment.tool_models import UnusualMovementsOut, WatchlistAddOut, WatchlistOut
from app.schemas.common import UICard


def _say(lang: str, en: str, hi: str, hinglish: str) -> str:
    return hi if lang == "hi" else hinglish if lang == "hinglish" else en


def portfolio_summary(r: PortfolioSummary, lang: str) -> str:
    if r.priced_count == 0:
        return _say(lang, "No priced holdings yet: import your holdings and daily prices first.",
                    "अभी कोई क़ीमत वाली होल्डिंग नहीं है: पहले होल्डिंग्स और रोज़ की क़ीमतें इम्पोर्ट करें।",
                    "Abhi koi priced holding nahi hai: pehle holdings aur daily prices import karo.")  # fmt: skip
    value, pnl = format_inr(r.value), format_inr(r.pnl)
    pct = f" ({r.pnl_percent}%)" if r.pnl_percent is not None else ""
    n = r.priced_count
    return _say(lang, f"Your portfolio is worth {value} across {n} priced holdings, with P&L of {pnl}{pct}.",
                f"आपका पोर्टफोलियो {n} होल्डिंग्स में {value} का है, लाभ-हानि {pnl}{pct}।",
                f"Aapka portfolio {n} holdings mein {value} ka hai, P&L {pnl}{pct}.")  # fmt: skip


def unusual_summary(r: UnusualMovementsOut, lang: str) -> str:
    if not r.movements:
        return _say(lang, f"No unusual movements in the {r.checked} stocks checked.",
                    f"जाँचे गए {r.checked} शेयरों में कोई असामान्य हलचल नहीं है।",
                    f"Check kiye gaye {r.checked} stocks mein koi unusual movement nahi hai.")  # fmt: skip
    parts = [f"{m.symbol} {m.return_percent}%" for m in r.movements[:3]]
    listed = ", ".join(parts)
    n = len(r.movements)
    return _say(lang, f"{n} unusual movements: {listed}.", f"{n} असामान्य हलचलें: {listed}।",
                f"{n} unusual movements: {listed}.")  # fmt: skip


def analysis_summary(r: StockAnalysis, lang: str) -> str:
    close = next((f.value for f in r.facts if f.key == "close"), None)
    ok = sum(1 for s in r.sections if s.status == "ok" and s.analyst != "verification")
    day = r.last_bar.isoformat() if r.last_bar else ""
    if close is None:
        return _say(lang, f"No price data for {r.symbol}.", f"{r.symbol} का कोई क़ीमत डेटा नहीं है।",
                    f"{r.symbol} ka koi price data nahi hai.")  # fmt: skip
    price = format_inr(close)
    return _say(lang,
                f"{r.symbol} last closed at {price} on {day}; {ok} analyst sections had data. This is not investment advice.",
                f"{r.symbol} का आख़िरी क्लोज़ {price} ({day}) था; {ok} विश्लेषण हिस्सों में डेटा था। यह निवेश सलाह नहीं है।",
                f"{r.symbol} ka last close {price} ({day}) tha; {ok} analyst sections mein data tha. Yeh investment advice nahi hai.")  # fmt: skip


def technical_summary(r: TechnicalSnapshot, lang: str) -> str:
    price, day = format_inr(r.close), r.as_of.isoformat()
    rsi_en = f", RSI {r.rsi_14}" if r.rsi_14 is not None else ""
    return _say(lang, f"{r.symbol} closed at {price} on {day}{rsi_en}.",
                f"{r.symbol} {day} को {price} पर बंद हुआ{rsi_en}।",
                f"{r.symbol} {day} ko {price} par close hua{rsi_en}.")  # fmt: skip


def backtest_summary(r: BacktestResult, lang: str) -> str:
    a, b, c = format_inr(r.initial_capital), format_inr(r.final_equity), format_inr(r.total_costs)
    dd = r.metrics.max_drawdown_percent
    return _say(lang,
                f"In this backtest of {r.symbol}, {a} became {b} ({r.total_return_percent}%), worst drawdown {dd}%, costs {c}; past results do not predict future returns.",
                f"{r.symbol} के इस बैकटेस्ट में {a} से {b} ({r.total_return_percent}%) हुए, सबसे बड़ी गिरावट {dd}%, ख़र्च {c}; पिछले नतीजे भविष्य नहीं बताते।",
                f"{r.symbol} ke is backtest mein {a} se {b} ({r.total_return_percent}%) hue, sabse badi girawat {dd}%, kharch {c}; past results future nahi batate.")  # fmt: skip


def watchlist_summary(r: WatchlistOut, lang: str) -> str:
    if not r.items:
        return _say(lang, "Your watchlist is empty.", "आपकी वॉचलिस्ट ख़ाली है।", "Aapki watchlist khaali hai.")
    names = ", ".join(i.symbol for i in r.items[:5])
    n = len(r.items)
    return _say(lang, f"Your watchlist has {n} stocks: {names}.", f"आपकी वॉचलिस्ट में {n} शेयर हैं: {names}।",
                f"Aapki watchlist mein {n} stocks hain: {names}.")  # fmt: skip


def watchlist_add_summary(r: WatchlistAddOut, lang: str) -> str:
    if r.added:
        return _say(lang, f"Added {r.symbol} to your watchlist.", f"{r.symbol} को वॉचलिस्ट में जोड़ दिया।",
                    f"{r.symbol} ko watchlist mein add kar diya.")  # fmt: skip
    return _say(lang, f"{r.symbol} is already on your watchlist.", f"{r.symbol} पहले से वॉचलिस्ट में है।",
                f"{r.symbol} pehle se watchlist mein hai.")  # fmt: skip


def paper_summary(r: PaperTradeOut, lang: str) -> str:
    price, fees = format_inr(r.price), format_inr(r.charges)
    verb_en, verb_hi, verb_hl = ("bought", "ख़रीदे", "kharide") if r.side == "buy" else ("sold", "बेचे", "beche")
    return _say(lang, f"Paper trade: {verb_en} {r.quantity} {r.symbol} at {price}, charges {fees}; nothing went to a broker.",
                f"पेपर ट्रेड: {r.quantity} {r.symbol} {price} पर {verb_hi}, शुल्क {fees}; ब्रोकर को कुछ नहीं भेजा गया।",
                f"Paper trade: {r.quantity} {r.symbol} {price} par {verb_hl}, charges {fees}; broker ko kuch nahi gaya.")  # fmt: skip


def ticket_summary(r: OrderTicket, lang: str) -> str:
    side_en = r.side.upper()
    side_hi = "ख़रीद" if r.side == "buy" else "बिक्री"
    return _say(lang, f"Order ticket ready: {side_en} {r.quantity} {r.symbol}. Place it yourself in {r.handoff.title}; ZORO did not place it.",
                f"ऑर्डर टिकट तैयार: {r.quantity} {r.symbol} की {side_hi}। इसे {r.handoff.title} में ख़ुद लगाएँ; ZORO ने ऑर्डर नहीं लगाया।",
                f"Order ticket ready: {side_en} {r.quantity} {r.symbol}. Ise {r.handoff.title} mein khud place karo; ZORO ne order nahi lagaya.")  # fmt: skip


def portfolio_card(r: PortfolioSummary) -> UICard:
    payload: dict[str, Any] = r.model_dump(mode="json")
    return UICard(kind="portfolio", title="Portfolio", payload=payload)


def analysis_card(r: StockAnalysis) -> UICard:
    payload: dict[str, Any] = r.model_dump(mode="json")
    return UICard(kind="stock_analysis", title=f"{r.symbol} analysis", payload=payload)
