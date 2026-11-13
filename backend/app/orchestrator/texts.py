"""Deterministic sentences the supervisor says itself, in en / hi (Devanagari) / hinglish."""

from __future__ import annotations

from typing import Any

from app.agents.security import explain_reason, pick

_T = tuple[str, str, str]

DONE: _T = ("Done.", "हो गया।", "Ho gaya.")
NOTHING_MATCHED: _T = (
    "I could not match that to anything I can do without a model, and no model may see this in the "
    "current privacy mode.",
    "मैं इसे ऐसे किसी काम से नहीं जोड़ पाया जो बिना मॉडल के हो सके, और मौजूदा प्राइवेसी मोड में कोई मॉडल इसे नहीं देख सकता।",
    "Main ise aise kisi kaam se match nahi kar paaya jo bina model ke ho sake, aur current privacy mode "
    "mein koi model ise nahi dekh sakta.",
)
MODEL_TROUBLE: _T = (
    "The model did not answer, so I could not finish that. Please try again.",
    "मॉडल ने जवाब नहीं दिया, इसलिए मैं यह पूरा नहीं कर पाया। कृपया फिर कोशिश करें।",
    "Model ne jawab nahi diya, isliye main yeh poora nahi kar paaya. Please phir try karein.",
)
CANCELLED: _T = ("Stopped.", "रोक दिया।", "Rok diya.")

_FAILURES: dict[str, _T] = {
    "timeout": (
        "That took too long and was stopped. Please try again.",
        "इसमें बहुत समय लगा और इसे रोक दिया गया। कृपया फिर कोशिश करें।",
        "Isme bahut time laga aur ise rok diya gaya. Please phir try karein.",
    ),
    "device_offline": (
        "The device that has to do this is not connected right now.",
        "जिस डिवाइस को यह करना है वह अभी जुड़ा नहीं है।",
        "Jis device ko yeh karna hai woh abhi connected nahi hai.",
    ),
    "device_unavailable": (
        "None of your paired devices can do this.",
        "आपका कोई भी जुड़ा हुआ डिवाइस यह नहीं कर सकता।",
        "Aapka koi bhi paired device yeh nahi kar sakta.",
    ),
    "device_action_expired": (
        "The device did not answer in time, so this was not done.",
        "डिवाइस ने समय पर जवाब नहीं दिया, इसलिए यह नहीं हुआ।",
        "Device ne time par jawab nahi diya, isliye yeh nahi hua.",
    ),
    "invalid_arguments": (
        "I did not have the details needed to do that. Please say it again with the details.",
        "मेरे पास यह करने के लिए ज़रूरी जानकारी नहीं थी। कृपया पूरी जानकारी के साथ फिर कहें।",
        "Mere paas yeh karne ke liye zaroori details nahi thi. Please details ke saath phir kahein.",
    ),
    "unavailable": (
        "That source is unavailable right now.",
        "वह स्रोत अभी उपलब्ध नहीं है।",
        "Woh source abhi available nahi hai.",
    ),
    "permission_denied": (
        "The device has not been given permission for that.",
        "डिवाइस को इसकी अनुमति नहीं दी गई है।",
        "Device ko iski permission nahi di gayi hai.",
    ),
    "user_cancelled": (
        "You cancelled that on the device.",
        "आपने डिवाइस पर इसे रद्द कर दिया।",
        "Aapne device par ise cancel kar diya.",
    ),
    "unsupported": (
        "This device does not support that.",
        "यह डिवाइस इसे सपोर्ट नहीं करता।",
        "Yeh device ise support nahi karta.",
    ),
}
_FAILURE_DEFAULT: _T = (
    "That did not work. Nothing was changed.",
    "यह नहीं हो पाया। कुछ भी बदला नहीं गया।",
    "Yeh nahi ho paaya. Kuch bhi change nahi hua.",
)

_BUDGETS: dict[str, _T] = {
    "tool_calls": (
        "I stopped because this request needed more steps than I am allowed in one turn.",
        "मैं रुक गया क्योंकि इस अनुरोध में एक बार में तय सीमा से ज़्यादा क़दम लग रहे थे।",
        "Main ruk gaya kyunki is request mein ek turn ki limit se zyada steps lag rahe the.",
    ),
    "tokens": (
        "I stopped because this request used up the model budget for one turn.",
        "मैं रुक गया क्योंकि इस अनुरोध ने एक बार का मॉडल बजट पूरा कर दिया।",
        "Main ruk gaya kyunki is request ne ek turn ka model budget poora kar diya.",
    ),
    "wall_clock": (
        "I stopped because this request was taking too long.",
        "मैं रुक गया क्योंकि इस अनुरोध में बहुत समय लग रहा था।",
        "Main ruk gaya kyunki is request mein bahut time lag raha tha.",
    ),
    "agent_timeout": (
        "I stopped because one part of this request took too long.",
        "मैं रुक गया क्योंकि इस अनुरोध के एक हिस्से में बहुत समय लगा।",
        "Main ruk gaya kyunki is request ke ek hisse mein bahut time laga.",
    ),
    "recursion_limit": (
        "I stopped because this request needed too many steps. Try asking for one thing at a time.",
        "मैं रुक गया क्योंकि इस अनुरोध में बहुत ज़्यादा क़दम लग रहे थे। एक बार में एक चीज़ पूछकर देखें।",
        "Main ruk gaya kyunki is request mein bahut zyada steps lag rahe the. Ek baar mein ek cheez poochh kar dekhein.",
    ),
}


def say(lang: str, texts: _T) -> str:
    return pick(lang, texts)


def budget_message(code: str, lang: str) -> str:
    return pick(lang, _BUDGETS.get(code, _BUDGETS["tool_calls"]))


def sentence_for(record: dict[str, Any], lang: str) -> str:
    """The deterministic sentence for one tool record: the tool's own summarizer when it ran,
    the security agent's explanation when policy said no, a plain failure line otherwise."""
    status = record.get("status")
    if status == "completed":
        return str(record.get("summary") or pick(lang, DONE))
    code = str(record.get("code") or "")
    if status == "denied":
        return explain_reason(code, lang)
    return pick(lang, _FAILURES.get(code, _FAILURE_DEFAULT))
