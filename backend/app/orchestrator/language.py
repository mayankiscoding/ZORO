"""Language id for en / hi / hinglish: script first, then a small romanised-Hindi lexicon.

Plain code, no model: Devanagari letters mean Hindi; Latin text is Hinglish when enough of its
words are romanised Hindi function words, otherwise English.
"""

from __future__ import annotations

import unicodedata

LANGUAGES = ("en", "hi", "hinglish")

# Romanised Hindi words that are not also common English words ("do", "to", "par", "me", "is",
# "main", "the", "hum", "bus", "band", "mat", "din", "ho" are left out on purpose).
_HINGLISH_WORDS = """
hai hain hoga hogi honge tha thi hua hui kya kyun kyu kyon kaise kaisa kaisi kitna kitni
kitne kab kahan kaun kaunsa kisko kiska mera meri mere mujhe mujhko humein hamara hamari tum
tumhara aap aapka aapki aapke uska uski unka yeh ye woh wo yahan wahan abhi aaj kal parso
subah shaam raat hafta mahina saal aur lekin magar phir fir toh bhi nahi nahin haan ji
ka ki ke ko se mein tak liye wala wali wale karo kar karna kiya karke kardo karde batao
bata bataiye dikhao dikha chalao chala bajao baja lagao laga bhejo bhej dijiye dedo dena lena
chahiye chahta chahti raha rahi rahe gaya gayi gaye paisa paise kharcha kharch rupaye rupay
kuch bahut zyada kam thoda accha acha theek thik sahi doosra dusra pehla teesra yaad dilao
dilana sunao suna gaana gaane khareedo kharido mangao mangwao chalu shuru khatam
"""
_HINGLISH = frozenset(_HINGLISH_WORDS.split())


def tokens(text: str) -> list[str]:
    """Lower-cased word tokens. Combining marks stay inside the word (Devanagari matras)."""
    out: list[str] = []
    current: list[str] = []
    for ch in unicodedata.normalize("NFC", text).lower():
        if ch.isalnum() or unicodedata.category(ch).startswith("M"):
            current.append(ch)
        elif current:
            out.append("".join(current))
            current = []
    if current:
        out.append("".join(current))
    return out


def _is_devanagari(ch: str) -> bool:
    return "ऀ" <= ch <= "ॿ"


def detect_language(text: str, hint: str | None = None) -> str:
    """Return "en", "hi" or "hinglish". `hint` (from the device) breaks ties only: the script
    of what the owner actually said wins."""
    hint = hint if hint in LANGUAGES else None
    letters = [ch for ch in text if ch.isalpha()]
    if not letters:
        return hint or "en"
    devanagari = sum(1 for ch in letters if _is_devanagari(ch))
    if devanagari * 2 >= len(letters):
        return "hi"
    words = [word for word in tokens(text) if word.isascii() and word.isalpha()]
    hits = sum(1 for word in words if word in _HINGLISH)
    if devanagari and hits == 0 and hint == "hi":
        return "hi"
    if hits >= 2 or (hits == 1 and (len(words) <= 4 or hint == "hinglish")):
        return "hinglish"
    return "en"
