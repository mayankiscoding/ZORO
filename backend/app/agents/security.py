"""The security agent: explains what the policy engine decided. It reads decisions and never
makes or changes one. Its two tools are LOW risk and read-only (no rate-limit token is consumed:
they call `PolicyEngine.gate` and the pure `risk_rule`, not `evaluate`)."""

from __future__ import annotations

from types import SimpleNamespace
from typing import Any

from pydantic import BaseModel, Field

from app.core.types import AgentId, ApprovalLevel, DataClass, PrivacyMode, RiskLevel
from app.security.egress import DEFAULT_EXTERNAL_CLASSES
from app.security.policy import risk_rule
from app.tools.intents import IntentContext, IntentSpec
from app.tools.spec import ToolContext, ToolSpec

# reason code -> (en, hi, hinglish). Codes are the ones PolicyEngine and the executor produce.
_REASONS: dict[str, tuple[str, str, str]] = {
    "low_risk": (
        "This only reads or shows information, so it runs without asking you.",
        "यह सिर्फ़ जानकारी पढ़ता या दिखाता है, इसलिए बिना पूछे चलता है।",
        "Yeh sirf jaankari padhta ya dikhata hai, isliye bina pooche chalta hai.",
    ),
    "medium_user_initiated": (
        "You asked for this yourself in this request, so it runs without a confirmation.",
        "आपने इसी अनुरोध में ख़ुद यह करने को कहा, इसलिए पुष्टि के बिना चलता है।",
        "Aapne isi request mein khud yeh karne ko kaha, isliye confirmation ke bina chalta hai.",
    ),
    "medium_tainted": (
        "This request read content from outside, such as a web page, email or document, "
        "so I ask you to confirm before changing anything.",
        "इस अनुरोध में बाहर की सामग्री पढ़ी गई, जैसे वेब पेज, ईमेल या दस्तावेज़, इसलिए कुछ बदलने से पहले आपकी पुष्टि चाहिए।",
        "Is request mein bahar ka content padha gaya, jaise web page, email ya document, "
        "isliye kuch badalne se pehle aapka confirmation chahiye.",
    ),
    "medium_not_user_initiated": (
        "You did not ask for this action directly, so I ask you to confirm it first.",
        "आपने यह काम सीधे नहीं कहा था, इसलिए पहले आपकी पुष्टि चाहिए।",
        "Aapne yeh kaam seedha nahi kaha tha, isliye pehle aapka confirmation chahiye.",
    ),
    "high_risk": (
        "This is a high-risk action, like sending a message, so it always needs your confirmation "
        "and shows exactly what will happen.",
        "यह ज़्यादा जोखिम वाला काम है, जैसे संदेश भेजना, इसलिए हमेशा आपकी पुष्टि चाहिए "
        "और ठीक वही दिखाया जाता है जो होगा।",
        "Yeh high-risk kaam hai, jaise message bhejna, isliye hamesha aapka confirmation chahiye "
        "aur exactly wahi dikhaya jaata hai jo hoga.",
    ),
    "high_tainted": (
        "This is a high-risk action and this request read content from outside, "
        "so it needs Face ID or Touch ID.",
        "यह ज़्यादा जोखिम वाला काम है और इस अनुरोध में बाहर की सामग्री पढ़ी गई, इसलिए फ़ेस आईडी या टच आईडी चाहिए।",
        "Yeh high-risk kaam hai aur is request mein bahar ka content padha gaya, "
        "isliye Face ID ya Touch ID chahiye.",
    ),
    "high_biometric_setting": (
        "You turned on Face ID for high-risk actions, so this needs Face ID or Touch ID.",
        "आपने ज़्यादा जोखिम वाले कामों के लिए फ़ेस आईडी चालू की है, इसलिए फ़ेस आईडी या टच आईडी चाहिए।",
        "Aapne high-risk kaamon ke liye Face ID on kiya hai, isliye Face ID ya Touch ID chahiye.",
    ),
    "critical_risk": (
        "Critical actions always need Face ID or Touch ID, and the request expires quickly.",
        "बहुत गंभीर कामों के लिए हमेशा फ़ेस आईडी या टच आईडी चाहिए, और अनुरोध जल्दी समाप्त हो जाता है।",
        "Critical kaamon ke liye hamesha Face ID ya Touch ID chahiye, aur request jaldi expire ho jaati hai.",
    ),
    "kill_switch": (
        "The kill switch is on, so nothing runs until you turn it off in Security and privacy.",
        "किल स्विच चालू है, इसलिए जब तक आप उसे सुरक्षा और गोपनीयता में बंद नहीं करते, कुछ नहीं चलेगा।",
        "Kill switch on hai, isliye jab tak aap use Security and privacy mein band nahi karte, kuch nahi chalega.",
    ),
    "device_revoked": (
        "This device was revoked. Pair it again to continue.",
        "यह डिवाइस हटा दिया गया था। जारी रखने के लिए इसे फिर से जोड़ें।",
        "Yeh device revoke ho chuka hai. Continue karne ke liye ise dobara pair karein.",
    ),
    "device_unknown": (
        "This device is not paired with your ZORO server.",
        "यह डिवाइस आपके ज़ोरो सर्वर से जुड़ा नहीं है।",
        "Yeh device aapke ZORO server se paired nahi hai.",
    ),
    "agent_not_allowed": (
        "That specialist is not allowed to use this tool.",
        "उस विशेषज्ञ को यह टूल इस्तेमाल करने की अनुमति नहीं है।",
        "Us specialist ko yeh tool use karne ki permission nahi hai.",
    ),
    "permission_not_granted": (
        "You have not granted the permission this needs. You can turn it on in Security and privacy.",
        "इसके लिए ज़रूरी अनुमति आपने नहीं दी है। आप इसे सुरक्षा और गोपनीयता में चालू कर सकते हैं।",
        "Iske liye zaroori permission aapne nahi di hai. Aap ise Security and privacy mein on kar sakte hain.",
    ),
    "rate_limited": (
        "That was asked too many times in a short while. Try again in a moment.",
        "यह थोड़ी देर में बहुत बार माँगा गया। कुछ देर बाद फिर कोशिश करें।",
        "Yeh thodi der mein bahut baar maanga gaya. Thodi der baad phir try karein.",
    ),
    "unknown_tool": (
        "I do not have a tool by that name.",
        "इस नाम का कोई टूल मेरे पास नहीं है।",
        "Is naam ka koi tool mere paas nahi hai.",
    ),
    "approval_declined": (
        "Okay, I did not do that.",
        "ठीक है, मैंने वह नहीं किया।",
        "Theek hai, maine woh nahi kiya.",
    ),
    "approval_expired": (
        "The approval request expired, so I did not do that. Ask again to get a new one.",
        "अनुमति का अनुरोध समाप्त हो गया, इसलिए मैंने वह नहीं किया। नया अनुरोध पाने के लिए फिर कहें।",
        "Approval request expire ho gayi, isliye maine woh nahi kiya. Nayi request ke liye phir kahein.",
    ),
    "approval_replayed": (
        "That approval was already answered, so I did not run it again.",
        "उस अनुमति का जवाब पहले ही दिया जा चुका था, इसलिए मैंने उसे दोबारा नहीं चलाया।",
        "Us approval ka jawab pehle hi diya ja chuka tha, isliye maine use dobara nahi chalaya.",
    ),
    "invalid_signature": (
        "The approval signature did not match this device's key, so nothing was done.",
        "अनुमति का हस्ताक्षर इस डिवाइस की कुंजी से मेल नहीं खाया, इसलिए कुछ नहीं किया गया।",
        "Approval signature is device ki key se match nahi hua, isliye kuch nahi kiya gaya.",
    ),
    "risk_table": (
        "Reading runs freely. Small changes you ask for run directly. Sending messages needs your "
        "confirmation, and critical actions need Face ID or Touch ID.",
        "पढ़ना बिना पूछे चलता है। आपके कहे छोटे बदलाव सीधे होते हैं। संदेश भेजने के लिए आपकी पुष्टि "
        "चाहिए, और बहुत गंभीर कामों के लिए फ़ेस आईडी या टच आईडी।",
        "Padhna bina pooche chalta hai. Aapke kahe chhote badlaav seedhe hote hain. Message bhejne ke liye "
        "aapka confirmation chahiye, aur critical kaamon ke liye Face ID ya Touch ID.",
    ),
}
_DEFAULT = (
    "The security policy did not allow that.",
    "सुरक्षा नीति ने इसकी अनुमति नहीं दी।",
    "Security policy ne iski permission nahi di.",
)
_LANG_INDEX = {"en": 0, "hi": 1, "hinglish": 2}


def pick(lang: str, texts: tuple[str, str, str]) -> str:
    return texts[_LANG_INDEX.get(lang, 0)]


def explain_reason(reason: str, lang: str) -> str:
    """One speakable sentence for a policy reason or denial code, in the owner's language."""
    key = reason.split(":", 1)[0]
    return pick(lang, _REASONS.get(key, _DEFAULT))


# ---------------------------------------------------------------- tools


class ExplainApprovalIn(BaseModel):
    tool: str | None = Field(default=None, description="Registered tool name to explain, if known.")


class ApprovalExplanation(BaseModel):
    tool: str | None = None
    risk: RiskLevel | None = None
    decision: str  # allow | approval | deny | general
    level: ApprovalLevel = ApprovalLevel.NONE
    reason: str  # the policy engine's reason code


class ExplainModeIn(BaseModel):
    pass


class PrivacyModeExplanation(BaseModel):
    mode: PrivacyMode
    kill_switch: bool
    external_classes: list[DataClass]  # what approved cloud models may receive right now


def _summarize_approval(result: ApprovalExplanation, lang: str) -> str:
    return explain_reason(result.reason, lang)


def _summarize_mode(result: PrivacyModeExplanation, lang: str) -> str:
    if result.kill_switch:
        return explain_reason("kill_switch", lang)
    classes = ", ".join(c.value for c in result.external_classes)
    if not result.external_classes:
        return pick(
            lang,
            (
                "Private mode is on: nothing is sent to cloud models, and I answer with tools on your own server.",
                "प्राइवेट मोड चालू है: क्लाउड मॉडल को कुछ नहीं भेजा जाता, और मैं आपके अपने सर्वर के टूल से जवाब देता हूँ।",
                "Private mode on hai: cloud models ko kuch nahi bheja jaata, aur main aapke apne server ke tools se jawab deta hoon.",
            ),
        )
    if result.mode is PrivacyMode.STRICT_PRIVATE:
        return pick(
            lang,
            (
                f"Private mode is on. Only {classes} content may go to a cloud model, because you allowed that.",
                f"प्राइवेट मोड चालू है। सिर्फ़ {classes} सामग्री क्लाउड मॉडल को जा सकती है, क्योंकि आपने इसकी अनुमति दी है।",
                f"Private mode on hai. Sirf {classes} content cloud model ko ja sakta hai, kyunki aapne allow kiya hai.",
            ),
        )
    return pick(
        lang,
        (
            f"Cloud intelligence is on. Approved cloud models may receive {classes} data, redacted first.",
            f"क्लाउड इंटेलिजेंस चालू है। स्वीकृत क्लाउड मॉडल को {classes} डेटा भेजा जा सकता है, पहले संवेदनशील हिस्से हटाकर।",
            f"Cloud intelligence on hai. Approved cloud models ko {classes} data bheja ja sakta hai, pehle redact karke.",
        ),
    )


def build_security_tools(reg: Any) -> tuple[list[ToolSpec], list[IntentSpec]]:
    async def explain_approval(ctx: ToolContext, args: ExplainApprovalIn) -> ApprovalExplanation:
        if args.tool is None:
            return ApprovalExplanation(decision="general", reason="risk_table")
        spec = reg.tools.get(args.tool)
        if spec is None:
            return ApprovalExplanation(tool=args.tool, decision="deny", reason="unknown_tool")
        policy = reg.service("policy")
        subject = SimpleNamespace(
            agent=sorted(spec.agents)[0] if spec.agents else ctx.agent,
            device_id=ctx.device_id,
            tainted=ctx.tainted,
            user_initiated=True,
        )
        decision = await policy.gate(spec, subject)
        if not decision.denied:
            decision = risk_rule(spec.risk, user_initiated=True, tainted=ctx.tainted, config=policy.config)
        return ApprovalExplanation(
            tool=spec.name,
            risk=spec.risk,
            decision=decision.kind,
            level=decision.level,
            reason=decision.reason,
        )

    async def explain_mode(ctx: ToolContext, args: ExplainModeIn) -> PrivacyModeExplanation:
        privacy = reg.service("privacy_state")
        mode = await privacy.get_mode()
        killed = bool(await reg.service("kill_switch").is_on())
        strict_public, granted = await privacy.egress_overrides()
        if killed:
            classes: frozenset[DataClass] = frozenset()
        elif mode is PrivacyMode.STRICT_PRIVATE:
            classes = frozenset({DataClass.PUBLIC}) if strict_public else frozenset()
        else:
            classes = DEFAULT_EXTERNAL_CLASSES | frozenset(granted)
        return PrivacyModeExplanation(
            mode=mode, kill_switch=killed, external_classes=sorted(classes, key=lambda c: (c.rank, c.value))
        )

    def extract_tool(text: str, _ctx: IntentContext) -> dict[str, Any] | None:
        lowered = text.lower()
        named = next((spec.name for spec in reg.tools.all() if spec.name.lower() in lowered), None)
        return {"tool": named}

    common: dict[str, Any] = {
        "risk": RiskLevel.LOW,
        "data_classes": frozenset({DataClass.PERSONAL}),
        "permission": None,
        "agents": frozenset({AgentId.SECURITY}),
        "mcp_group": "security-mcp",
    }
    tools = [
        ToolSpec(
            name="security.explain_approval",
            description="Explain why an action needs the owner's approval (or runs without one). Read-only.",
            input_model=ExplainApprovalIn,
            output_model=ApprovalExplanation,
            handler=explain_approval,
            summarizer=_summarize_approval,
            **common,
        ),
        ToolSpec(
            name="security.explain_privacy_mode",
            description="Explain the current privacy mode and what may be sent to cloud models. Read-only.",
            input_model=ExplainModeIn,
            output_model=PrivacyModeExplanation,
            handler=explain_mode,
            summarizer=_summarize_mode,
            **common,
        ),
    ]
    intents = [
        IntentSpec(
            name="security.explain_approval",
            agent=AgentId.SECURITY,
            tool="security.explain_approval",
            keywords={
                "en": [
                    "why approval",
                    "need approval",
                    "need my approval",
                    "why face id",
                    "why confirm",
                    "why do you ask",
                    "why permission",
                ],
                "hi": ["अनुमति क्यों", "मंज़ूरी क्यों", "फेस आईडी क्यों", "फ़ेस आईडी क्यों", "पुष्टि क्यों"],
                "hinglish": [
                    "approval kyun",
                    "approval kyu",
                    "permission kyun",
                    "permission kyu",
                    "face id kyun",
                    "confirm kyun",
                    "kyun pooch",
                ],
            },
            extract=extract_tool,
            examples=("Why do you need my approval to send an email?", "Approval kyun chahiye?"),
        ),
        IntentSpec(
            name="security.explain_privacy_mode",
            agent=AgentId.SECURITY,
            tool="security.explain_privacy_mode",
            keywords={
                "en": [
                    "privacy mode",
                    "private mode",
                    "cloud mode",
                    "leaves my",
                    "leave my",
                    "sent to the cloud",
                ],
                "hi": ["प्राइवेसी मोड", "प्राइवेट मोड", "निजी मोड", "गोपनीयता मोड", "क्लाउड मोड"],
                "hinglish": ["privacy mode", "private mode", "cloud mode", "data bahar", "cloud ko"],
            },
            extract=lambda _text, _ctx: {},
            examples=("What does private mode allow?", "Private mode mein kya hota hai?"),
        ),
    ]
    return tools, intents
