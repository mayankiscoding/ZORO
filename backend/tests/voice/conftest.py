from __future__ import annotations

from collections.abc import Callable, Iterator, Sequence

import httpx
import pytest

from tests.voice import harness


@pytest.fixture
def plugin_modules() -> Sequence[str]:
    return ("tests.voice.harness",)


@pytest.fixture(autouse=True)
def reset_harness() -> Iterator[None]:
    harness.ENV.clear()
    harness.SEEN.clear()
    harness.HANDLER.clear()
    yield
    harness.ENV.clear()


@pytest.fixture
def env() -> dict[str, str]:
    return harness.ENV


@pytest.fixture
def seen() -> list[httpx.Request]:
    return harness.SEEN


@pytest.fixture
def respond() -> Callable[[Callable[[httpx.Request], httpx.Response]], None]:
    def _set(fn: Callable[[httpx.Request], httpx.Response]) -> None:
        harness.HANDLER["fn"] = fn

    return _set
