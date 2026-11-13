"""Investment intents for the local router (en / hi / hinglish), with slot extraction.

Symbols come from an upper-case ticker in the utterance, from the word after "analyse" / "of",
or from the instruments last shown ("the second one" / "doosra wala" / "दूसरा वाला").
"""

from __future__ import annotations

import re
from collections.abc import Callable, Mapping, Sequence
from typing import Any

from app.core.types import AgentId
from app.investment.tools import WORKING_SET
from app.tools.intents import IntentContext, IntentSpec

_STOP = {"I", "A", "RSI", "SMA", "EMA", "MACD", "ATR", "OBV", "PNL", "P", "L", "NSE", "BSE", "ZORO", "OK", "AND",
         "THE", "MY", "OF", "TO", "IN", "ME", "IS"}  # fmt: skip
_TICKER = re.compile(r"\b([A-Z][A-Z0-9&-]{1,19})\b")
_AFTER = re.compile(
    r"(?:analy[sz]e|analysis\s+of|analysis\s+for|report\s+on|technicals?\s+(?:of|for)|rsi\s+of|add|backtest)\s+"
    r"([a-z][a-z0-9&-]{1,19})", re.IGNORECASE,
)  # fmt: skip
_BEFORE = re.compile(r"([a-z][a-z0-9&-]{1,19})\s+(?:ka|ki|ko|का|की|को)\s", re.IGNORECASE)
_ORDINALS: dict[int, tuple[str, ...]] = {
    1: ("first", "pehla", "pehle", "pahla", "पहला", "पहले", "पहली"),
    2: ("second", "doosra", "dusra", "doosre", "dusre", "दूसरा", "दूसरे", "दूसरी"),
    3: ("third", "teesra", "tisra", "teesre", "तीसरा", "तीसरे", "तीसरी"),
    4: ("fourth", "chautha", "चौथा", "चौथे"),
    5: ("fifth", "paanchva", "पाँचवा", "पांचवा"),
}
_NOT_SYMBOLS = {"my", "the", "this", "that", "stock", "share", "portfolio", "watchlist", "mera", "meri", "is", "us",
                "it", "me", "to", "pehla", "doosra", "teesra", "first", "second", "third"}  # fmt: skip


def _norm(text: str) -> str:
    return " " + re.sub(r"\s+", " ", text.lower()).strip() + " "


def _has(text: str, words: Sequence[str]) -> bool:
    return any((f" {w} " in text or f" {w}?" in text) if w.isascii() else (w in text) for w in words)


def symbol_from(text: str, ctx: IntentContext) -> dict[str, Any] | None:
    lowered = _norm(text)
    for index, words in _ORDINALS.items():
        if _has(lowered, words):
            items = list(ctx.working_sets.get(WORKING_SET, []))
            if len(items) >= index:
                item = items[index - 1]
                return {"symbol": str(item["symbol"]), "exchange": str(item.get("exchange", "NSE"))}
    for match in _TICKER.finditer(text):
        if match.group(1) not in _STOP:
            return {"symbol": match.group(1)}
    for pattern in (_AFTER, _BEFORE):
        for match in pattern.finditer(text):
            word = match.group(1).lower()
            if word not in _NOT_SYMBOLS:
                return {"symbol": word.upper()}
    return None


def _keyword_intent(
    words: Mapping[str, Sequence[str]], slots: Callable[[str], dict[str, Any]] | None = None
) -> Callable[[str, IntentContext], dict[str, Any] | None]:
    flat = [w for group in words.values() for w in group]

    def extract(text: str, ctx: IntentContext) -> dict[str, Any] | None:
        if not _has(_norm(text), flat):
            return None
        return slots(text) if slots else {}

    return extract


def _with_symbol(
    words: Mapping[str, Sequence[str]], extra: dict[str, Any] | None = None
) -> Callable[[str, IntentContext], dict[str, Any] | None]:
    flat = [w for group in words.values() for w in group]

    def extract(text: str, ctx: IntentContext) -> dict[str, Any] | None:
        if not _has(_norm(text), flat):
            return None
        found = symbol_from(text, ctx)
        return None if found is None else {**found, **(extra or {})}

    return extract


PORTFOLIO = {
    "en": ("portfolio", "my holdings", "my investments", "my stocks"),
    "hi": ("पोर्टफोलियो", "मेरे शेयर", "मेरा निवेश", "होल्डिंग्स"),
    "hinglish": ("mera portfolio", "portfolio dikhao", "portfolio batao", "mere shares", "mera investment"),
}
UNUSUAL = {
    "en": ("unusual movements", "unusual movement", "unusual moves", "big movers", "unusual volume"),
    "hi": ("असामान्य हलचल", "असामान्य", "बड़ी हलचल"),
    "hinglish": ("unusual movement", "ajeeb movement", "bada movement", "unusual move", "asamanya"),
}
ANALYSIS = {
    "en": ("analyse", "analyze", "analysis", "research report"),
    "hi": ("विश्लेषण", "एनालिसिस"),
    "hinglish": ("analysis karo", "analysis do", "ka analysis", "vishleshan"),
}
TECHNICAL = {
    "en": ("technicals", "technical", "rsi", "macd", "moving average"),
    "hi": ("तकनीकी", "आरएसआई"),
    "hinglish": ("technical dikhao", "rsi batao", "technical batao"),
}
WATCHLIST = {
    "en": ("watchlist", "watch list"),
    "hi": ("वॉचलिस्ट", "वॉच लिस्ट"),
    "hinglish": ("watchlist dikhao", "meri watchlist", "watchlist batao"),
}
WATCH_ADD = {
    "en": ("to my watchlist", "to watchlist", "to the watchlist", "on my watchlist"),
    "hi": ("वॉचलिस्ट में जोड़", "वॉचलिस्ट में डाल"),
    "hinglish": ("watchlist mein add", "watchlist mein daalo", "watchlist me add", "watchlist mein dalo"),
}


def build_intents() -> list[IntentSpec]:
    agent = AgentId.INVESTMENT
    return [
        IntentSpec(name="investment.watchlist_add", agent=agent, tool="investment.watchlist_add",
                   keywords=WATCH_ADD, extract=_with_symbol(WATCH_ADD), priority=30,
                   examples=("add INFY to my watchlist", "TCS ko watchlist mein add karo", "INFY को वॉचलिस्ट में जोड़ो")),
        IntentSpec(name="investment.unusual_movements", agent=agent, tool="investment.unusual_movements",
                   keywords=UNUSUAL, extract=_keyword_intent(UNUSUAL), priority=20,
                   examples=("any unusual movements today?", "शेयरों में असामान्य हलचल", "koi unusual movement hai?")),
        IntentSpec(name="investment.stock_analysis", agent=agent, tool="investment.stock_analysis",
                   keywords=ANALYSIS, extract=_with_symbol(ANALYSIS), priority=15,
                   examples=("analyse INFY", "RELIANCE का विश्लेषण", "TCS ka analysis karo")),
        IntentSpec(name="investment.technical_snapshot", agent=agent, tool="investment.technical_snapshot",
                   keywords=TECHNICAL, extract=_with_symbol(TECHNICAL), priority=12,
                   examples=("RSI of INFY", "HDFCBANK का तकनीकी हाल", "TCS ka rsi batao")),
        IntentSpec(name="investment.watchlist_view", agent=agent, tool="investment.watchlist_view",
                   keywords=WATCHLIST, extract=_keyword_intent(WATCHLIST), priority=10,
                   examples=("show my watchlist", "मेरी वॉचलिस्ट दिखाओ", "watchlist dikhao")),
        IntentSpec(name="investment.portfolio_summary", agent=agent, tool="investment.portfolio_summary",
                   keywords=PORTFOLIO, extract=_keyword_intent(PORTFOLIO), priority=10,
                   examples=("check my portfolio", "मेरा पोर्टफोलियो कैसा है", "mera portfolio dikhao")),
    ]  # fmt: skip
