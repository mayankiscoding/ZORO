from __future__ import annotations

import os
from decimal import Decimal
from pathlib import Path

import pytest
import yaml

from app.core.types import TaskClass
from app.providers.config import ConfigStore, load_config, parse_config, resolve_provider
from tests.providers.conftest import ENV, raw_config

REPO_CONFIG = Path(__file__).resolve().parents[3] / "config" / "models.yaml"


def _write(path: Path, raw: dict[str, object]) -> None:
    path.write_text(yaml.safe_dump(raw), encoding="utf-8")


def test_shipped_config_is_valid_and_gemini_first_on_cloud_routes() -> None:
    cfg = load_config(REPO_CONFIG)
    for task, ids in cfg.routes.items():
        assert ids, task
        first = cfg.model(ids[0])
        assert cfg.provider(first.provider).kind == "gemini", task
    for m in cfg.models:
        assert m.verified_on
        assert isinstance(m.price_in, Decimal)
    assert cfg.route(TaskClass.EMBEDDING)


def test_shipped_config_disables_everything_without_keys() -> None:
    cfg = load_config(REPO_CONFIG)
    assert all(not resolve_provider(p, {}).enabled for p in cfg.providers)


def test_prices_are_exact_decimals() -> None:
    raw = raw_config()
    raw["models"][0]["price_in"] = 0.1  # a YAML float
    cfg = parse_config(raw)
    assert cfg.model("g-flash").price_in == Decimal("0.1")


def test_missing_key_disables_provider() -> None:
    cfg = parse_config(raw_config())
    env = dict(ENV)
    del env["OAI_KEY"]
    rp = resolve_provider(cfg.provider("oai"), env)
    assert not rp.enabled
    assert rp.disabled_reason == "missing_env:OAI_KEY"
    assert resolve_provider(cfg.provider("gem"), env).enabled


def test_keyless_local_needs_its_base_url() -> None:
    cfg = parse_config(raw_config())
    assert resolve_provider(cfg.provider("local"), ENV).enabled
    assert not resolve_provider(cfg.provider("local"), {}).enabled


def test_keyless_is_ignored_for_external_providers() -> None:
    raw = raw_config()
    raw["providers"][1]["keyless"] = True
    cfg = parse_config(raw)
    assert not resolve_provider(cfg.provider("oai"), {}).enabled


def test_api_key_not_in_repr() -> None:
    cfg = parse_config(raw_config())
    rp = resolve_provider(cfg.provider("gem"), ENV)
    assert "test-gem-key" not in repr(rp)


def test_unknown_model_in_route_rejected() -> None:
    raw = raw_config()
    raw["routes"]["routine_chat"] = ["nope"]
    with pytest.raises(ValueError, match="unknown model"):
        parse_config(raw)


def test_reload_on_change_and_keep_last_good(tmp_path: Path) -> None:
    path = tmp_path / "models.yaml"
    _write(path, raw_config())
    store = ConfigStore(path, env=ENV)
    assert store.current().route(TaskClass.ROUTINE_CHAT)[0] == "g-flash"

    raw = raw_config()
    raw["routes"]["routine_chat"] = ["o-mini", "g-flash"]
    _write(path, raw)
    os.utime(path, ns=(1, 2_000_000_000_000_000_000))  # force a new mtime even on coarse clocks
    assert store.current().route(TaskClass.ROUTINE_CHAT)[0] == "o-mini"

    path.write_text("providers: [unclosed", encoding="utf-8")
    os.utime(path, ns=(1, 3_000_000_000_000_000_000))
    assert store.current().route(TaskClass.ROUTINE_CHAT)[0] == "o-mini"  # last good kept


def test_broken_file_at_startup_raises(tmp_path: Path) -> None:
    path = tmp_path / "models.yaml"
    path.write_text("routes: {routine_chat: [x]}\nproviders: []\nmodels: []\n", encoding="utf-8")
    with pytest.raises(ValueError):
        ConfigStore(path, env={})
