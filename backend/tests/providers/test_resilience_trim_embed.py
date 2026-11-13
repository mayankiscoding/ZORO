from __future__ import annotations

import math
import os
import subprocess
import sys
from pathlib import Path

import pytest

from app.providers.embedding import LOCAL_HASH_DIMS, local_hash_embed, local_hash_embed_one
from app.providers.resilience import BreakerState, CircuitBreaker, RetryPolicy
from app.providers.trim import ContextOverflow, message_tokens, trim_messages
from app.providers.types import ChatMessage, ToolCall
from tests.providers.conftest import Clock

# ---- breaker / retry ----------------------------------------------------------------------------


def test_breaker_opens_half_opens_and_closes() -> None:
    clock = Clock()
    b = CircuitBreaker(failure_threshold=2, open_seconds=10, clock=clock)
    assert b.allow()
    b.record_failure()
    assert b.state is BreakerState.CLOSED
    b.record_failure()
    assert b.state is BreakerState.OPEN
    assert not b.allow()
    clock.now += 10
    assert b.state is BreakerState.HALF_OPEN
    assert b.allow()  # one trial
    assert not b.allow()  # only one at a time
    b.record_success()
    assert b.state is BreakerState.CLOSED


def test_half_open_failure_reopens() -> None:
    clock = Clock()
    b = CircuitBreaker(failure_threshold=1, open_seconds=5, clock=clock)
    b.record_failure()
    clock.now += 5
    assert b.allow()
    b.record_failure()
    assert b.state is BreakerState.OPEN
    clock.now += 4.9
    assert not b.allow()


def test_cooldown_blocks_without_counting_failure() -> None:
    clock = Clock()
    b = CircuitBreaker(failure_threshold=1, open_seconds=5, clock=clock)
    b.cool_down(20)
    assert not b.allow()
    assert b.state is BreakerState.CLOSED
    clock.now += 20
    assert b.allow()


def test_backoff_exponential_with_jitter_and_cap() -> None:
    p = RetryPolicy(base_delay_s=0.5, max_delay_s=3.0)
    assert p.backoff(0, 0.5) == pytest.approx(0.5)
    assert p.backoff(1, 0.5) == pytest.approx(1.0)
    assert p.backoff(1, 0.0) == pytest.approx(0.5)
    assert p.backoff(10, 0.5) == pytest.approx(3.0)


# ---- trimming -----------------------------------------------------------------------------------


def _conv() -> tuple[ChatMessage, ...]:
    call = ToolCall(id="c1", name="lookup", arguments={"q": "x"})
    return (
        ChatMessage(role="system", content="S" * 300),
        ChatMessage(role="user", content="old question " * 30),
        ChatMessage(role="assistant", content="", tool_calls=(call,)),
        ChatMessage(role="tool", content="result " * 30, tool_call_id="c1"),
        ChatMessage(role="assistant", content="old answer " * 30),
        ChatMessage(role="user", content="latest question"),
    )


def test_no_trim_when_it_fits() -> None:
    msgs = _conv()
    assert trim_messages(msgs, 10_000) == msgs


def test_trim_keeps_system_and_latest_user_and_tool_pairs() -> None:
    msgs = _conv()
    keep = message_tokens(msgs[0]) + message_tokens(msgs[4]) + message_tokens(msgs[5])
    out = trim_messages(msgs, keep)
    assert out[0].role == "system"
    assert out[-1].content == "latest question"
    assert all(m.role != "tool" for m in out)  # tool result dropped together with its call
    assert not any(m.tool_calls for m in out)
    assert out[1].content.startswith("old answer")


def test_trim_overflow_when_pinned_messages_do_not_fit() -> None:
    with pytest.raises(ContextOverflow):
        trim_messages(_conv(), 50)


# ---- hashing embedder ---------------------------------------------------------------------------


def test_hash_embedder_is_deterministic_and_normalised() -> None:
    a = local_hash_embed_one("Mera bijli ka bill kitna hai?")
    assert a == local_hash_embed_one("Mera bijli ka bill kitna hai?")
    assert len(a) == LOCAL_HASH_DIMS
    assert math.isclose(math.sqrt(sum(v * v for v in a)), 1.0, rel_tol=1e-9)


def test_hash_embedder_similarity_and_edge_cases() -> None:
    a, b, c, empty = local_hash_embed(
        ["electricity bill due", "Electricity  BILL due", "cricket score today", ""]
    )
    assert a == b  # case and whitespace normalised

    def cos(x: list[float], y: list[float]) -> float:
        return sum(p * q for p, q in zip(x, y, strict=True))

    assert cos(a, c) < 0.5
    assert empty == [0.0] * LOCAL_HASH_DIMS


def test_hash_embedder_is_stable_across_processes() -> None:
    # BLAKE2b, not hash(): a different PYTHONHASHSEED must give the same vector.
    code = "from app.providers.embedding import local_hash_embed_one as f; print(repr(f('zoro ज़ोरो')))"
    backend = Path(__file__).resolve().parents[2]
    env = {**os.environ, "PYTHONHASHSEED": "12345"}
    out = subprocess.run(  # noqa: S603 - fixed argv, test only
        [sys.executable, "-c", code], cwd=backend, env=env, capture_output=True, text=True, check=True
    )
    assert out.stdout.strip() == repr(local_hash_embed_one("zoro ज़ोरो"))
