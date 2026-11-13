"""Deterministic text understanding for memory: explicit "remember ..." requests in English, Hindi
and Hinglish, category and sensitivity heuristics, secret detection, ordinals and tokenising."""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

from app.core.types import DataClass, MemoryCategory
from app.security.redaction import redact_text

# ---------------------------------------------------------------- tokens

_WORD = re.compile(r"[\wऀ-ॿ]+", re.UNICODE)
_STOP = frozenset(
    [
        "a",
        "an",
        "the",
        "is",
        "are",
        "was",
        "were",
        "am",
        "be",
        "to",
        "of",
        "in",
        "on",
        "at",
        "for",
        "and",
        "or",
        "my",
        "me",
        "i",
        "you",
        "it",
        "this",
        "that",
        "what",
        "which",
        "do",
        "does",
        "did",
        "your",
        "about",
        "with",
        "from",
        "have",
        "has",
        "had",
        "tell",
        "say",
        "said",
        "mera",
        "meri",
        "mere",
        "hai",
        "hain",
        "ka",
        "ki",
        "ke",
        "ko",
        "se",
        "me",
        "mein",
        "aur",
        "kya",
        "tum",
        "tumhe",
        "main",
        "है",
        "हैं",
        "का",
        "की",
        "के",
        "को",
        "से",
        "में",
        "और",
        "क्या",
        "तुम",
        "मेरा",
        "मेरी",
        "मेरे",
        "मैं",
    ]
)


def tokens(text: str) -> list[str]:
    norm = unicodedata.normalize("NFKC", text).casefold()
    return [t for t in _WORD.findall(norm) if t not in _STOP and (len(t) > 1 or t.isdigit())]


def normalise(text: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", text).casefold().split()).strip(" .,!?;:")


def keyword_score(query_tokens: list[str], text: str) -> float:
    """Share of the query's words found in the text (a word also matches a longer word it prefixes)."""
    if not query_tokens:
        return 0.0
    words = set(tokens(text))
    hit = 0
    for q in query_tokens:
        if q in words or (
            len(q) >= 4 and any(w.startswith(q) or q.startswith(w) for w in words if len(w) >= 4)
        ):
            hit += 1
    return hit / len(query_tokens)


# ---------------------------------------------------------------- secrets

_SECRET = re.compile(
    r"(?i)\b(?:password|passcode|passwd|cvv|cvc|otp|one[- ]time (?:password|code)|api[ _-]?key|"
    r"secret[ _-]?key|private key|seed phrase|mpin|(?:upi|atm|debit|card|bank)\s+pin|"
    r"pin\s*(?:is|number|no\.?|=|:))\b"
    r"|पासवर्ड|ओटीपी|सीवीवी|यूपीआई पिन|एटीएम पिन"
)


def looks_like_secret(text: str) -> bool:
    """Credentials are never stored in memory (CLAUDE.md rule 5)."""
    return _SECRET.search(text) is not None


# ---------------------------------------------------------------- sensitivity and category

_HEALTH = re.compile(
    r"(?i)\b(?:allerg\w*|diabet\w*|medicine|medication|blood pressure|\bbp\b|sugar level|asthma|"
    r"surgery|doctor|prescription|dawai|dawa|bimari|insulin|thyroid|cholesterol)\b|एलर्जी|दवाई|दवा|बीमारी|डायबिटीज"
)
_FINANCIAL = re.compile(
    r"(?i)(?:₹|\brs\.?\s?\d|\brupees?\b|\binr\b|\bsalary\b|\bbank\b|\bloan\b|\bemi\b|\bsip\b|\bmutual fund|"
    r"\bcredit card|\bdebit card|\binvest\w*|\bportfolio\b|\bnet worth\b|\btaxes?\b|\bkharcha\b|\btankhwah\b|"
    r"\bpaise\b)|तनख्वाह|वेतन|सैलरी|बैंक|लोन|पैसे|रुपये|निवेश"
)
_IDENTITY = re.compile(
    r"(?i)\b(?:aadhaar|aadhar|passport|driving licen[cs]e|voter id|pan card)\b|आधार|पासपोर्ट"
)
_FITNESS = re.compile(
    r"(?i)\b(?:weight|kg|workout|gym|run|running|steps|calories|diet|protein|yoga|cardio|vajan|kasrat|"
    r"marathon|cycling|swim\w*|exercise)\b|वजन|कसरत|योग|व्यायाम"
)
_VISUAL = re.compile(r"(?i)\b(?:photo|photos|picture|pictures|selfie|screenshot|tasveer|image)\b|फोटो|तस्वीर")
_EPISODE = re.compile(
    r"(?i)\b(?:yesterday|today|tomorrow|last (?:week|month|year|night)|on (?:monday|tuesday|wednesday|thursday|"
    r"friday|saturday|sunday)|kal|parso|pichhle|went to|met|visited)\b|कल|परसों|पिछले"
)
_FIRST_PERSON = re.compile(
    r"(?i)^\s*(?:my|i|i'm|i am|i've|mera|meri|mere|main|mai|hamara|hamari)\b|^\s*(?:मेरा|मेरी|मेरे|मैं|हमारा|हमारी)"
)
_REDACTION_SENSITIVE = {"aadhaar", "pan", "card", "bank_account", "ifsc", "upi"}


@dataclass(frozen=True)
class Classified:
    category: MemoryCategory
    sensitivity: DataClass


def detect_sensitivity(text: str) -> DataClass:
    if looks_like_secret(text):
        return DataClass.SECRET
    counts = redact_text(text).counts
    if _IDENTITY.search(text) or _REDACTION_SENSITIVE & set(counts):
        return (
            DataClass.FINANCIAL
            if (set(counts) & {"card", "bank_account", "ifsc", "upi"})
            else DataClass.SENSITIVE
        )
    if _HEALTH.search(text):
        return DataClass.HEALTH
    if _FINANCIAL.search(text):
        return DataClass.FINANCIAL
    if counts:  # phone, email: personal contact details
        return DataClass.SENSITIVE
    return DataClass.PERSONAL


def classify(text: str) -> Classified:
    """Best-effort category and the minimum sensitivity the text calls for. The owner or a tool may
    raise the sensitivity, never lower it below this."""
    sensitivity = detect_sensitivity(text)
    if _FINANCIAL.search(text) and sensitivity in (DataClass.FINANCIAL, DataClass.PERSONAL):
        category = MemoryCategory.FINANCIAL
        sensitivity = max(sensitivity, DataClass.FINANCIAL, key=lambda d: d.rank)
    elif _HEALTH.search(text) and _FIRST_PERSON.search(text):
        category = MemoryCategory.PROFILE
    elif _FITNESS.search(text):
        category = MemoryCategory.FITNESS
    elif _VISUAL.search(text):
        category = MemoryCategory.VISUAL
    elif _EPISODE.search(text):
        category = MemoryCategory.EPISODIC
    elif _FIRST_PERSON.search(text):
        category = MemoryCategory.PROFILE
    else:
        category = MemoryCategory.KNOWLEDGE
    return Classified(category, sensitivity)


def max_sensitivity(a: DataClass, b: DataClass) -> DataClass:
    return a if a.rank >= b.rank else b


# ---------------------------------------------------------------- explicit "remember ..." requests

_EN_PREFIX = re.compile(
    r"(?is)^\s*(?:(?:hey\s+)?zoro[,:]?\s*)?(?:please\s+|pls\s+|can you\s+|could you\s+)?"
    r"(?:remember|note down|note|keep in mind|save)\b(?!\s+to\b)(?:\s+(?:that|this|it))?[\s,:]+(?P<t>.+)$"
)
_HING_PREFIX = re.compile(
    r"(?is)^\s*(?:zoro[,:]?\s*)?(?:yaad\s+(?:rakhna|rakho|rakhiye|rakhein)|याद\s+(?:रखना|रखो|रखें|रखिए))"
    r"(?:\s+(?:ki|ke|कि))?[\s,:]+(?P<t>.+)$"
)
_SUFFIX = re.compile(
    r"(?is)^(?P<t>.+?)[\s,.;:]+(?:(?:ye|yeh|ise|isse|is baat ko|यह|ये|इसे)\s+)?"
    r"(?:yaad\s+(?:rakhna|rakho|rakhiye|rakhein|rakh\s+lena|rakh\s+le)|याद\s+(?:रखना|रखो|रखें|रखिए|रख\s+लेना))[\s.!]*$"
)
_NEGATED_TAIL = re.compile(r"(?i)\b(?:mat|nahi|nahin|na)\s*$|(?:मत|नहीं)\s*$")
_LEAD_IN = re.compile(r"(?i)^(?:that|ki|ke|कि)\s+")
_QUESTION = re.compile(
    r"(?i)^(?:what|when|who|where|how|which|why|if|whether|kya|kab|kaun|kahan|kaise|kyun)\b|^(?:क्या|कब|कौन|कहाँ|कैसे|क्यों)"
)


def parse_explicit(text: str) -> str | None:
    """The content of an explicit request to remember something, or None.

    Handles "remember that I like tea", "yaad rakhna ki mera birthday 5 May hai", "मेरा नाम राज है याद रखना".
    "Remember to <do something>" is a reminder (another package), and negations are not requests.
    """
    stripped = text.strip()
    for pattern in (_EN_PREFIX, _HING_PREFIX, _SUFFIX):
        match = pattern.match(stripped)
        if match:
            content = _LEAD_IN.sub("", match.group("t").strip()).strip(" .,!;:")
            if content and not _NEGATED_TAIL.search(content) and not _QUESTION.match(content):
                return content
    return None


# ---------------------------------------------------------------- ordinals ("the second one")

_ORDINALS: dict[str, int] = {
    **{w: 0 for w in ("first", "1st", "one", "pehla", "pehli", "pehle", "पहला", "पहली", "पहले")},
    **{w: 1 for w in ("second", "2nd", "two", "dusra", "doosra", "dusri", "doosri", "दूसरा", "दूसरी", "दूसरे")},
    **{w: 2 for w in ("third", "3rd", "three", "teesra", "tisra", "teesri", "तीसरा", "तीसरी")},
    **{w: 3 for w in ("fourth", "4th", "four", "chautha", "chauthi", "चौथा", "चौथी")},
    **{w: -1 for w in ("last", "final", "aakhri", "akhri", "आखिरी", "अंतिम")},
}


def ordinal_index(text: str) -> int | None:
    """0-based index (-1 = last) of an ordinal word in the utterance, or None."""
    for word in _WORD.findall(unicodedata.normalize("NFKC", text).casefold()):
        if word in _ORDINALS:
            return _ORDINALS[word]
    return None
