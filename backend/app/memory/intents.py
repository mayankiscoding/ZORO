"""Memory intents in English, Hindi and Hinglish: local routing without a model."""

from __future__ import annotations

import re
from typing import Any

from app.core.types import AgentId
from app.memory.classify import ordinal_index, parse_explicit
from app.memory.tools import WORKING_SET_KIND
from app.tools.intents import IntentContext, IntentSpec

_FORGET = re.compile(
    r"(?i)\bforget\b|\b(?:delete|remove|erase)\s+(?:the\s+|that\s+|this\s+|my\s+)?(?:memory|note)\b"
    r"|\b(?:bhool|bhul)\s+(?:jao|jana|ja)\b|\b(?:hata|mita)\s+do\b|\byaad\s+mat\s+rakh\w*"
    r"|भूल\s+(?:जाओ|जा)|(?:हटा|मिटा)\s+दो|याद\s+मत\s+रख\w*"
)
_FORGET_FILLER = frozenset(
    [
        "please",
        "forget",
        "delete",
        "remove",
        "erase",
        "about",
        "that",
        "this",
        "the",
        "my",
        "memory",
        "note",
        "one",
        "bhool",
        "bhul",
        "jao",
        "jana",
        "ja",
        "hata",
        "mita",
        "do",
        "yaad",
        "mat",
        "rakho",
        "rakhna",
        "rakhiye",
        "ye",
        "yeh",
        "is",
        "baat",
        "ko",
        "ki",
        "ke",
        "wala",
        "wali",
        "भूल",
        "जाओ",
        "जा",
        "हटा",
        "मिटा",
        "दो",
        "याद",
        "मत",
        "रखो",
        "रखना",
        "यह",
        "ये",
        "इस",
        "बात",
        "को",
        "कि",
        "के",
        "वाला",
        "वाली",
    ]
)
_SEARCH = re.compile(
    r"(?i)\b(?:do you|can you)\s+remember\b|\bwhat\s+(?:do|did)\s+you\s+(?:remember|know)\b"
    r"|\bwhat\s+did\s+i\s+(?:tell|say)\b|\btell me what you (?:remember|know)\b"
    r"|\byaad\s+hai\b|\bkya\s+yaad\b"
    r"|\bmaine\s+(?:tumhe\s+|aapko\s+)?kya\s+(?:bataya|kaha)\b"
    r"|याद\s+है|क्या\s+याद|मैंने\s+(?:तुम्हें\s+|आपको\s+)?क्या\s+(?:बताया|कहा)"
)
_SEARCH_FILLER = frozenset(
    [
        "do",
        "you",
        "can",
        "remember",
        "what",
        "did",
        "know",
        "about",
        "tell",
        "me",
        "i",
        "say",
        "the",
        "a",
        "my",
        "any",
        "anything",
        "tumhe",
        "tujhe",
        "aapko",
        "tumko",
        "kya",
        "yaad",
        "hai",
        "mujhe",
        "maine",
        "bataya",
        "kaha",
        "ke",
        "baare",
        "bare",
        "mein",
        "me",
        "ko",
        "क्या",
        "तुम्हें",
        "आपको",
        "तुझे",
        "याद",
        "है",
        "मैंने",
        "बताया",
        "कहा",
        "के",
        "बारे",
        "में",
        "मुझे",
        "मेरे",
    ]
)


def _leftover(text: str, filler: frozenset[str]) -> str:
    kept = [w for w in text.split() if w.strip(" .,?!;:\"'").casefold() not in filler]
    return " ".join(kept).strip(" .,?!;:")


def extract_remember(text: str, ctx: IntentContext) -> dict[str, Any] | None:
    content = parse_explicit(text)
    return {"text": content} if content else None


def extract_search(text: str, ctx: IntentContext) -> dict[str, Any] | None:
    if parse_explicit(text) is not None or not _SEARCH.search(text):
        return None
    topic = _leftover(text, _SEARCH_FILLER)
    return {"query": topic or text.strip()[:300]}


def extract_forget(text: str, ctx: IntentContext) -> dict[str, Any] | None:
    if not _FORGET.search(text):
        return None
    shown = ctx.working_sets.get(WORKING_SET_KIND, ())
    index = ordinal_index(text)
    if index is not None:  # "the second one": only resolvable against what was just shown
        try:
            memory_id = shown[index].get("id") if shown else None
        except IndexError:
            memory_id = None
        return {"memory_id": str(memory_id)} if memory_id else None
    topic = _leftover(text, _FORGET_FILLER)
    if not topic:
        return None
    return {"query": topic[:300]}


def build_intents() -> list[IntentSpec]:
    return [
        IntentSpec(
            name="memory.remember",
            agent=AgentId.MEMORY,
            tool="memory.remember",
            keywords={
                "en": ["remember that", "remember this", "keep in mind", "note that", "save this to memory"],
                "hi": ["याद रखना", "याद रखो", "याद रखें", "याद रखिए"],
                "hinglish": ["yaad rakhna", "yaad rakho", "yaad rakhiye", "yaad rakh lena"],
            },
            extract=extract_remember,
            examples=["remember that I like my tea without sugar", "yaad rakhna ki mera birthday 5 May hai"],
        ),
        IntentSpec(
            name="memory.search",
            agent=AgentId.MEMORY,
            tool="memory.search",
            keywords={
                "en": [
                    "what do you remember",
                    "do you remember",
                    "what did I tell you",
                    "what do you know about me",
                ],
                "hi": ["क्या तुम्हें याद है", "आपको याद है", "मैंने क्या बताया"],
                "hinglish": ["tumhe yaad hai", "kya yaad hai", "mujhe kya yaad hai", "maine kya bataya"],
            },
            extract=extract_search,
            examples=["what do you remember about my diet", "tumhe mera birthday yaad hai?"],
            priority=10,
        ),
        IntentSpec(
            name="memory.forget",
            agent=AgentId.MEMORY,
            tool="memory.forget",
            keywords={
                "en": ["forget that", "forget about", "delete that memory", "remove that memory"],
                "hi": ["भूल जाओ", "याद मत रखो", "यह मिटा दो"],
                "hinglish": ["bhool jao", "bhul jao", "yaad mat rakho", "ye hata do"],
            },
            extract=extract_forget,
            examples=["forget that I like tea", "forget the second one", "doosra wala bhool jao"],
            priority=20,
        ),
    ]
