"""Plain-text extraction from fetched pages (standard library only). The text is untrusted data."""

from __future__ import annotations

import json
import re
from html.parser import HTMLParser

_SKIP = frozenset({"script", "style", "noscript", "svg", "template", "iframe", "object", "head"})
_BLOCK = frozenset(
    {
        "p",
        "div",
        "br",
        "li",
        "ul",
        "ol",
        "tr",
        "table",
        "section",
        "article",
        "header",
        "footer",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "blockquote",
        "pre",
        "dt",
        "dd",
        "td",
        "th",
    }
)


class _TextParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.title = ""
        self._skip_depth = 0
        self._in_title = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "title":
            self._in_title = True
        elif tag in _SKIP:
            self._skip_depth += 1
        elif tag in _BLOCK:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self._in_title = False
        elif tag in _SKIP and self._skip_depth:
            self._skip_depth -= 1
        elif tag in _BLOCK:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self.title += data
        elif not self._skip_depth:
            self.parts.append(data)


def _tidy(text: str) -> str:
    lines = (re.sub(r"[ \t\r\f\v]+", " ", line).strip() for line in text.split("\n"))
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


def extract_text(body: str, content_type: str) -> tuple[str, str]:
    """(title, text) for HTML, JSON or plain text."""
    if content_type in ("text/html", "application/xhtml+xml"):
        parser = _TextParser()
        parser.feed(body)
        parser.close()
        return _tidy(parser.title)[:300], _tidy("".join(parser.parts))
    if content_type in ("application/json", "application/ld+json"):
        try:
            return "", json.dumps(json.loads(body), ensure_ascii=False, indent=1)
        except ValueError:
            return "", _tidy(body)
    return "", _tidy(body)
