"""Local intent router: scores the registered `IntentSpec`s with plain code (no model).

A candidate needs a keyword hit and slots from the intent's own extractor. Confidence grows with
the number and length of matched phrases; phrases in the detected language count in full, others
slightly less (people mix). A compound request ("... and ...", "... aur ...", "... और ...") is
split on conjunctions and used only when every part routes confidently on its own.
"""

from __future__ import annotations

import logging
import re
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Any

from app.orchestrator.language import tokens
from app.tools.intents import IntentContext, IntentRegistry, IntentSpec
from app.tools.registry import ToolRegistry

log = logging.getLogger(__name__)

CONFIDENT = 0.6
_OTHER_LANGUAGE_WEIGHT = 0.8
_FOLLOW_UP_BONUS = 0.1
_CONJUNCTIONS = re.compile(
    r"\s+(?:and then|and also|and|then|also|aur phir|aur fir|aur|phir|fir|saath hi|और फिर|और|फिर|तथा|साथ ही)\s+|\s*;\s*",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class Candidate:
    intent: IntentSpec
    slots: dict[str, Any]
    confidence: float
    text: str  # the part of the utterance this candidate answers
    matched: tuple[str, ...] = ()


@dataclass(frozen=True)
class LocalRoute:
    steps: tuple[Candidate, ...] = ()
    confidence: float = 0.0
    reason: str = "no_intent_matched"
    best: Candidate | None = field(default=None, compare=False)  # top candidate even when not confident

    @property
    def confident(self) -> bool:
        return bool(self.steps) and self.confidence >= CONFIDENT


def split_compound(text: str) -> list[str]:
    parts = [part.strip(" ,.!?।") for part in _CONJUNCTIONS.split(text)]
    return [part for part in parts if part]


def _contains(haystack: Sequence[str], needle: Sequence[str]) -> bool:
    if not needle or len(needle) > len(haystack):
        return False
    first = needle[0]
    span = len(needle)
    return any(
        haystack[i] == first and list(haystack[i : i + span]) == list(needle)
        for i in range(len(haystack) - span + 1)
    )


class IntentRouter:
    def __init__(self, intents: IntentRegistry, tools: ToolRegistry, *, threshold: float = CONFIDENT) -> None:
        self._intents = intents
        self._tools = tools
        self._threshold = threshold

    def candidates(self, text: str, ctx: IntentContext) -> list[Candidate]:
        """Every intent that matches `text`, best first."""
        words = tokens(text)
        found: list[Candidate] = []
        for spec in self._intents.all():
            tool = self._tools.get(spec.tool)
            if tool is None or spec.agent not in tool.agents:
                continue  # an intent for a tool that is not loaded cannot be answered
            score = 0.0
            matched: list[str] = []
            for lang, phrases in spec.keywords.items():
                weight = 1.0 if lang == ctx.lang else _OTHER_LANGUAGE_WEIGHT
                for phrase in phrases:
                    needle = tokens(phrase)
                    if phrase not in matched and _contains(words, needle):
                        matched.append(phrase)
                        score += weight * (1 + 0.5 * (len(needle) - 1))
            if not matched:
                continue
            try:
                slots = spec.extract(text, ctx)
            except Exception as exc:  # a broken extractor must not break routing
                log.error(
                    "intent extractor failed", extra={"intent": spec.name, "error_type": type(exc).__name__}
                )
                continue
            if slots is None:
                continue
            confidence = min(1.0, 0.35 + 0.25 * score)
            if ctx.last_agent is not None and spec.agent == ctx.last_agent:
                confidence = min(1.0, confidence + _FOLLOW_UP_BONUS)
            found.append(Candidate(spec, dict(slots), round(confidence, 3), text, tuple(matched)))
        found.sort(key=lambda c: (-c.confidence, -c.intent.priority, c.intent.name))
        return found

    def route(self, text: str, ctx: IntentContext) -> LocalRoute:
        parts = split_compound(text)
        if len(parts) >= 2:
            picks: list[Candidate] = []
            for part in parts:
                ranked = self.candidates(part, ctx)
                if not ranked or ranked[0].confidence < self._threshold:
                    picks = []
                    break
                if all((ranked[0].intent.name, ranked[0].slots) != (p.intent.name, p.slots) for p in picks):
                    picks.append(ranked[0])
            if len(picks) >= 2:
                names = ", ".join(pick.intent.name for pick in picks)
                return LocalRoute(
                    tuple(picks),
                    min(pick.confidence for pick in picks),
                    f"compound request: {names}",
                    picks[0],
                )
        ranked = self.candidates(text, ctx)
        if not ranked:
            return LocalRoute()
        best = ranked[0]
        if best.confidence >= self._threshold:
            return LocalRoute((best,), best.confidence, f"intent {best.intent.name}", best)
        return LocalRoute((), best.confidence, f"low confidence for {best.intent.name}", best)
