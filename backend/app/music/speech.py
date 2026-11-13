"""Spoken summaries (en, hi, hinglish) and cards for the music tools, built only from result values."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from app.music.schemas import MusicResult, MusicTrack, PlaylistOut, RecentOut, SearchOut
from app.schemas.common import UICard

Lines = tuple[str, str, str]


def pick(lang: str, lines: Lines) -> str:
    en, hi, hinglish = lines
    return {"hi": hi, "hinglish": hinglish}.get(lang, en)


def track_label(track: MusicTrack) -> str:
    return f"{track.title} - {', '.join(track.artists)}" if track.artists else track.title


def _wait(result: MusicResult, lang: str) -> str:
    n = result.retry_after_s
    if not n:
        return pick(
            lang,
            ("Try again shortly.", "थोड़ी देर में फिर कोशिश करें।", "Thodi der mein phir try karo."),
        )
    return pick(
        lang,
        (f"Try again in {n} seconds.", f"{n} सेकंड बाद फिर कोशिश करें।", f"{n} second baad phir try karo."),
    )


def _names(result: MusicResult) -> str:
    return ", ".join(d.name for d in result.devices)


def status_line(result: MusicResult, lang: str) -> str | None:
    """The sentence for any non-ok status, or None when the status is ok."""
    s = result.status
    if s == "not_connected":
        return pick(
            lang,
            (
                "Spotify is not connected. Connect it in Integrations.",
                "Spotify जुड़ा नहीं है। इंटीग्रेशन में जाकर जोड़ें।",
                "Spotify connect nahi hai. Integrations mein jaakar connect karo.",
            ),
        )
    if s == "not_configured":
        return pick(
            lang,
            (
                "Spotify is not set up on the server yet.",
                "सर्वर पर Spotify अभी सेट नहीं है।",
                "Server par Spotify abhi set up nahi hai.",
            ),
        )
    if s == "needs_reauth":
        return pick(
            lang,
            (
                "Spotify needs you to sign in again.",
                "Spotify में दोबारा साइन इन करना होगा।",
                "Spotify mein dobara sign in karna hoga.",
            ),
        )
    if s == "premium_required":
        return pick(
            lang,
            (
                "Spotify needs Premium to control playback.",
                "प्लेबैक कंट्रोल के लिए Spotify Premium चाहिए।",
                "Playback control ke liye Spotify Premium chahiye.",
            ),
        )
    if s == "not_allowed":
        return pick(
            lang,
            (
                "Spotify refused this. The account may not be on the app's allowed list.",
                "Spotify ने मना कर दिया। हो सकता है यह अकाउंट ऐप की अनुमत सूची में न हो।",
                "Spotify ne mana kar diya. Ho sakta hai ye account app ki allowed list mein na ho.",
            ),
        )
    if s == "no_active_device":
        return pick(
            lang,
            (
                "No Spotify device is active. Open Spotify somewhere, or say play on my Mac.",
                "कोई Spotify डिवाइस चालू नहीं है। कहीं Spotify खोलें, या कहें मेरे Mac पर चलाओ।",
                "Koi Spotify device active nahi hai. Kahin Spotify kholo, ya bolo mere Mac par chalao.",
            ),
        )
    if s == "choose_device":
        names = _names(result)
        return pick(
            lang,
            (
                f"More than one device fits: {names}. Which one?",
                f"एक से ज़्यादा डिवाइस मिले: {names}। कौन सा?",
                f"Ek se zyada device mile: {names}. Kaun sa?",
            ),
        )
    if s == "device_not_found":
        return pick(
            lang,
            (
                "I could not find that device in Spotify.",
                "वह डिवाइस Spotify में नहीं मिला।",
                "Wo device Spotify mein nahi mila.",
            ),
        )
    if s == "nothing_found":
        if result.message == "spotify_keeps_last_50":
            return pick(
                lang,
                (
                    "Nothing found. Spotify only keeps your last 50 plays.",
                    "कुछ नहीं मिला। Spotify सिर्फ़ आख़िरी 50 गाने याद रखता है।",
                    "Kuch nahi mila. Spotify sirf aakhri 50 gaane yaad rakhta hai.",
                ),
            )
        return pick(
            lang,
            ("I found nothing for that.", "इसके लिए कुछ नहीं मिला।", "Iske liye kuch nahi mila."),
        )
    if s == "rate_limited":
        return pick(
            lang,
            ("Spotify is busy. ", "Spotify अभी व्यस्त है। ", "Spotify abhi busy hai. "),
        ) + _wait(result, lang)
    if s == "unsupported":
        return pick(
            lang,
            (
                "Apple Music cannot do that here. Connect Spotify for it.",
                "Apple Music यहाँ यह नहीं कर सकता। इसके लिए Spotify जोड़ें।",
                "Apple Music yahan ye nahi kar sakta. Iske liye Spotify connect karo.",
            ),
        )
    if s == "unavailable":
        return pick(
            lang,
            (
                "Spotify is not answering right now.",
                "Spotify अभी जवाब नहीं दे रहा।",
                "Spotify abhi jawab nahi de raha.",
            ),
        )
    return None


_PLAN: dict[str, Lines] = {
    "play": (
        "I will resume music on your device.",
        "मैं आपके डिवाइस पर म्यूज़िक चालू करता हूँ।",
        "Main aapke device par music chalu karta hoon.",
    ),
    "search_play": (
        "I will ask your device to play that.",
        "मैं आपके डिवाइस से इसे चलवाता हूँ।",
        "Main aapke device se ye chalwata hoon.",
    ),
    "pause": (
        "I will pause music on your device.",
        "मैं डिवाइस पर म्यूज़िक रोकता हूँ।",
        "Main device par music rokta hoon.",
    ),
    "next": ("I will skip to the next song.", "मैं अगला गाना लगाता हूँ।", "Main agla gaana lagata hoon."),
    "previous": ("I will go back a song.", "मैं पिछला गाना लगाता हूँ।", "Main pichla gaana lagata hoon."),
}


def _plan_line(result: MusicResult, lang: str) -> str:
    action = result.follow_ups[0].args.get("action", "play") if result.follow_ups else "play"
    return pick(lang, _PLAN.get(str(action), _PLAN["play"]))


def play_summary(result: MusicResult, lang: str) -> str:
    if result.status == "device_plan":
        return _plan_line(result, lang)
    line = status_line(result, lang)
    if line is not None:
        return line
    where = f" {result.device.name}" if result.device else ""
    if result.track is not None:
        label = track_label(result.track)
        return pick(
            lang,
            (
                f"Playing {label}{' on' + where if where else ''}.",
                f"{label} चल रहा है{(', ' + result.device.name + ' पर') if result.device else ''}।",
                f"{label} chal raha hai{(', ' + result.device.name + ' par') if result.device else ''}.",
            ),
        )
    return pick(lang, ("Playing.", "चल रहा है।", "Chal raha hai."))


def _simple(ok: Lines) -> Callable[[Any, str], str]:
    def summarize(result: MusicResult, lang: str) -> str:
        if result.status == "device_plan":
            return _plan_line(result, lang)
        return status_line(result, lang) or pick(lang, ok)

    return summarize


pause_summary = _simple(("Paused.", "रोक दिया।", "Rok diya."))
skip_summary = _simple(("Done.", "हो गया।", "Ho gaya."))


def transfer_summary(result: MusicResult, lang: str) -> str:
    line = status_line(result, lang)
    if line is not None:
        return line
    name = result.device.name if result.device else ""
    return pick(
        lang,
        (f"Music moved to {name}.", f"म्यूज़िक {name} पर चला गया।", f"Music {name} par chala gaya."),
    )


def search_summary(result: SearchOut, lang: str) -> str:
    line = status_line(result, lang)
    if line is not None:
        return line
    first = track_label(result.tracks[0])
    n = len(result.tracks)
    if result.similar_to:
        return pick(
            lang,
            (
                f"Spotify no longer offers recommendations, so these {n} are search results for {result.query}. First: {first}.",
                f"Spotify अब सुझाव नहीं देता, इसलिए ये {n} नतीजे {result.query} की खोज से हैं। पहला: {first}।",
                f"Spotify ab recommendations nahi deta, isliye ye {n} results {result.query} ki search se hain. Pehla: {first}.",
            ),
        )
    return pick(
        lang,
        (
            f"I found {n} songs. First: {first}.",
            f"{n} गाने मिले। पहला: {first}।",
            f"{n} gaane mile. Pehla: {first}.",
        ),
    )


def recent_summary(result: RecentOut, lang: str) -> str:
    line = status_line(result, lang)
    if line is not None:
        return line
    first = track_label(result.tracks[0])
    n = len(result.tracks)
    return pick(
        lang,
        (
            f"You played {n} songs. The latest is {first}.",
            f"आपने {n} गाने सुने। सबसे नया: {first}।",
            f"Aapne {n} gaane sune. Sabse naya: {first}.",
        ),
    )


def playlist_summary(result: PlaylistOut, lang: str) -> str:
    line = status_line(result, lang)
    if line is not None:
        return line
    name, n = result.name, result.added
    return pick(
        lang,
        (
            f"Playlist {name} created with {n} songs.",
            f"प्लेलिस्ट {name} बन गई, उसमें {n} गाने हैं।",
            f"Playlist {name} ban gayi, usmein {n} gaane hain.",
        ),
    )


def music_card(result: Any) -> UICard | None:
    tracks = getattr(result, "tracks", None)
    track = getattr(result, "track", None)
    if tracks:
        return UICard(
            kind="music",
            title="Songs",
            payload={"tracks": [t.model_dump(mode="json") for t in tracks], "provider": result.provider},
        )
    if track is not None and result.status == "ok":
        return UICard(
            kind="music",
            title="Now playing",
            payload={"now_playing": track.model_dump(mode="json"), "provider": result.provider},
        )
    return None
