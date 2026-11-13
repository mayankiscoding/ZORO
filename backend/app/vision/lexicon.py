"""Colour, object and hint words for photo queries in English, Hindi and Hinglish.

Words are written naturally and normalised with `norm` when the tables are built, so the same
normalisation (lower case, Devanagari digits to ASCII, nukta removed, punctuation to spaces) applies to
the owner's sentence and to these entries. Matching is on whole words and phrases.
"""

from __future__ import annotations

import re
import string
import unicodedata

_DIGITS = str.maketrans("०१२३४५६७८९", "0123456789")
_PUNCT = str.maketrans({c: " " for c in string.punctuation + "।॥…“”‘’"})


def norm(text: str) -> str:
    """Normalised text padded with a space on each side, so phrases match as ` word word `."""
    text = unicodedata.normalize("NFC", text).lower().translate(_DIGITS)
    text = unicodedata.normalize("NFD", text).replace("़", "")  # nukta: ज़ -> ज, ड़ -> ड
    text = unicodedata.normalize("NFC", text).translate(_PUNCT)
    return " " + re.sub(r"\s+", " ", text).strip() + " "


def has_phrase(padded: str, phrase: str) -> bool:
    return f" {norm(phrase).strip()} " in padded


def find_phrase(padded: str, phrases: tuple[str, ...]) -> tuple[int, int] | None:
    """Span of the earliest phrase from `phrases` in `padded`."""
    best: tuple[int, int] | None = None
    for phrase in phrases:
        needle = f" {norm(phrase).strip()} "
        index = padded.find(needle)
        if index != -1 and (best is None or index < best[0]):
            best = (index, index + len(needle) - 1)  # keep the trailing space for the next phrase
    return best


def _words(raw: str) -> tuple[str, ...]:
    return tuple(w.strip() for w in raw.split("|") if w.strip())


COLORS: dict[str, tuple[str, ...]] = {
    "red": _words("red|crimson|scarlet|maroon|laal|lal|लाल"),
    "orange": _words("orange|narangi|kesariya|saffron|नारंगी|केसरिया"),
    "yellow": _words("yellow|golden|gold|peela|peeli|peele|पीला|पीली|पीले|सुनहरा|सुनहरी|सुनहरे"),
    "green": _words("green|hara|hari|hare|हरा|हरी|हरे"),
    "blue": _words("blue|navy|cyan|sky blue|neela|neeli|neele|nila|nili|aasmani|नीला|नीली|नीले|आसमानी"),
    "purple": _words("purple|violet|lavender|baingani|jamuni|बैंगनी|जामुनी"),
    "pink": _words("pink|gulabi|गुलाबी"),
    "brown": _words("brown|bhura|bhuri|bhure|भूरा|भूरी|भूरे"),
    "black": _words("black|kala|kali|kale|काला|काली|काले"),
    "white": _words("white|safed|safaid|सफेद|सफ़ेद"),
    "gray": _words("gray|grey|silver|slaty|dhusar|स्लेटी|धूसर|चांदी"),
    "beige": _words("beige|cream|tan|khaki"),
}

# canonical -> (labels sent to the device, words)
OBJECTS: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {
    "cap": (("cap", "hat"), _words("cap|caps|hat|hats|topi|topiyan|टोपी|टोपियां|टोपियाँ")),
    "dog": (("dog", "puppy"), _words("dog|dogs|puppy|puppies|kutta|kutte|kuttay|कुत्ता|कुत्ते|पिल्ला|पिल्ले")),
    "cat": (("cat", "kitten"), _words("cat|cats|kitten|billi|billiyan|बिल्ली|बिल्लियां")),
    "car": (("car", "vehicle"), _words("car|cars|gaadi|gadi|gaadiyan|गाड़ी|गाड़ियां|कार")),
    "motorbike": (("motorcycle", "bike", "scooter"), _words("bike|bikes|motorcycle|scooter|बाइक|स्कूटर|स्कूटी")),
    "bicycle": (("bicycle",), _words("bicycle|cycle|साइकिल|cycle")),
    "shoes": (
        ("shoe", "sneaker", "footwear"),
        _words("shoe|shoes|sneakers|joote|joota|jute|jooti|जूते|जूता|जूती|चप्पल|chappal|sandal"),
    ),
    "shirt": (
        ("shirt", "t-shirt", "clothing"),
        _words("shirt|shirts|tshirt|t shirt|kameez|शर्ट|टीशर्ट|कमीज़|कमीज"),
    ),
    "dress": (("dress", "clothing"), _words("dress|saree|sari|kurta|ड्रेस|साड़ी|कुर्ता")),
    "watch": (("watch", "wristwatch"), _words("watch|watches|ghadi|घड़ी")),
    "bag": (("bag", "backpack", "handbag"), _words("bag|bags|backpack|handbag|purse|baig|thaila|बैग|थैला")),
    "phone": (("phone", "cell phone"), _words("phone|mobile|smartphone|फोन|मोबाइल")),
    "laptop": (("laptop", "computer"), _words("laptop|computer|लैपटॉप|कंप्यूटर")),
    "glasses": (("glasses", "sunglasses"), _words("glasses|sunglasses|specs|chashma|चश्मा")),
    "bottle": (("bottle",), _words("bottle|botal|बोतल")),
    "book": (("book",), _words("book|books|kitab|kitaab|किताब|किताबें")),
    "food": (
        ("food", "meal", "dish"),
        _words("food|meal|dinner|lunch|breakfast|khana|khaana|nashta|खाना|नाश्ता"),
    ),
    "pizza": (("pizza", "food"), _words("pizza|पिज़्ज़ा|पिज्जा")),
    "cake": (("cake", "dessert"), _words("cake|केक")),
    "tea": (("tea", "cup", "drink"), _words("tea|chai|चाय")),
    "beach": (("beach", "sea", "sand"), _words("beach|sea|ocean|samundar|samudra|समुद्र|समंदर|बीच")),
    "mountain": (
        ("mountain", "hill", "landscape"),
        _words("mountain|mountains|hills|pahad|pahaad|पहाड़|पहाड़ों"),
    ),
    "flower": (("flower", "plant"), _words("flower|flowers|phool|फूल|फूलों")),
    "tree": (("tree", "plant"), _words("tree|trees|ped|पेड़|पेड़ों")),
    "sunset": (("sunset", "sky"), _words("sunset|sunrise|suryast|suryoday|सूर्यास्त|सूर्योदय")),
    "sky": (("sky", "cloud"), _words("sky|clouds|aasman|आसमान|बादल")),
    "baby": (("baby", "child"), _words("baby|kid|kids|child|children|bachcha|bachche|baccha|बच्चा|बच्चे|बच्चों")),
    "selfie": (("selfie", "person", "face"), _words("selfie|selfies|सेल्फी")),
    "person": (("person", "people"), _words("person|people|man|woman|aadmi|log|आदमी|औरत|लोग")),
    "family": (("people", "family"), _words("family|parivar|परिवार")),
    "friends": (("people", "friends"), _words("friends|friend|dost|doston|दोस्त|दोस्तों")),
    "wedding": (("wedding", "bride", "groom"), _words("wedding|shaadi|shadi|शादी|विवाह")),
    "temple": (("temple", "building", "statue"), _words("temple|mandir|मंदिर")),
    "house": (("house", "building"), _words("house|home|building|ghar|घर|इमारत")),
}

# document hints: words -> labels
DOCUMENTS: tuple[tuple[tuple[str, ...], tuple[str, ...]], ...] = (
    (_words("receipt|receipts|bill|bills|invoice|invoices|rasid|रसीद|बिल"), ("document", "receipt")),
    (
        _words("id card|aadhaar|aadhar|passport|licence|license|pan card|आधार|पासपोर्ट"),
        ("document", "id card"),
    ),
    (
        _words("document|documents|scan|scanned|paper|papers|form|dastavez|kagaz|दस्तावेज़|दस्तावेज|कागज़|कागज"),
        ("document",),
    ),
)
SCREENSHOT_WORDS = _words(
    "screenshot|screenshots|screen shot|screen shots|screen capture|skreenshot|स्क्रीनशॉट|स्क्रीन शॉट|स्क्रीनशाट"
)
NOT_SCREENSHOT_WORDS = _words(
    "not screenshots|not screenshot|no screenshots|without screenshots|except screenshots|"
    "screenshot nahi|screenshots nahi|screenshot ke bina|स्क्रीनशॉट नहीं|स्क्रीनशॉट के बिना|स्क्रीनशॉट को छोड़कर"
)
PHOTO_WORDS = _words(
    "photo|photos|picture|pictures|pic|pics|image|images|snap|snaps|selfie|selfies|tasveer|tasveeren|tasvir|"
    "फोटो|फ़ोटो|फोटोज़|फोटोज|तस्वीर|तस्वीरें|तस्वीरों|चित्र|सेल्फी"
)
