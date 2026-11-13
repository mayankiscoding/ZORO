"""config/integrations.yaml and config/orchestrator.yaml through the app/core loader."""

from __future__ import annotations

import dataclasses
import os
from pathlib import Path

import pytest
from pydantic import ValidationError

from app.core import runtime_config as rc
from app.core.settings import Settings

REPO_CONFIG = Path(__file__).resolve().parents[4] / "config"


@pytest.fixture(autouse=True)
def _fresh_cache() -> None:
    rc.clear_cache()


def test_repo_integrations_parse_and_are_https() -> None:
    names = set(rc.load_integrations(REPO_CONFIG).integrations)
    assert {"spotify", "google", "strava"} <= names
    for name in names:
        assert all(u.startswith("https://") for u in rc.integration_urls(name, REPO_CONFIG).values())


def test_config_matches_the_package_endpoint_shapes() -> None:
    """The call-site change (`XEndpoints(**integration_urls(...))`) must construct the same objects."""
    from app.communications.google.endpoints import SCOPES as GOOGLE_SCOPES
    from app.communications.google.endpoints import GoogleEndpoints
    from app.music.endpoints import SCOPES as SPOTIFY_SCOPES
    from app.music.endpoints import SpotifyEndpoints

    assert SpotifyEndpoints(**rc.integration_urls("spotify", REPO_CONFIG)) == SpotifyEndpoints()
    assert GoogleEndpoints(**rc.integration_urls("google", REPO_CONFIG)) == GoogleEndpoints()
    assert rc.integration_scopes("spotify", REPO_CONFIG) == SPOTIFY_SCOPES
    assert rc.integration_scopes("google", REPO_CONFIG) == GOOGLE_SCOPES
    assert {f.name for f in dataclasses.fields(SpotifyEndpoints)} == set(
        rc.integration_urls("spotify", REPO_CONFIG)
    )


def test_strava_urls_match_package_constants() -> None:
    from app.fitness import strava

    urls = rc.integration_urls("strava", REPO_CONFIG)
    assert (urls["api"], urls["authorize"], urls["token"]) == (
        strava.API_BASE,
        strava.AUTHORIZE_URL,
        strava.TOKEN_URL,
    )


def test_unknown_integration_is_a_lookup_error() -> None:
    with pytest.raises(rc.IntegrationNotConfigured):
        rc.integration("nope", REPO_CONFIG)


def test_plain_http_url_is_rejected(tmp_path: Path) -> None:
    (tmp_path / rc.INTEGRATIONS_FILE).write_text(
        "integrations:\n  x:\n    title: X\n    urls: {api: 'http://insecure.test'}\n", encoding="utf-8"
    )
    with pytest.raises(ValidationError):
        rc.load_integrations(tmp_path)


def test_orchestrator_defaults_match_code_defaults() -> None:
    from app.orchestrator.router import CONFIDENT
    from app.orchestrator.state import TurnLimits

    cfg = rc.orchestrator_config(REPO_CONFIG)
    assert TurnLimits(**cfg.turn_limits_kwargs()) == TurnLimits()
    assert cfg.routing.confidence_threshold == CONFIDENT


def test_orchestrator_missing_or_malformed_falls_back(tmp_path: Path) -> None:
    assert rc.orchestrator_config(tmp_path) == rc.OrchestratorConfig()
    (tmp_path / rc.ORCHESTRATOR_FILE).write_text("turn_limits: {max_tool_calls: -3}\n", encoding="utf-8")
    assert rc.orchestrator_config(tmp_path) == rc.OrchestratorConfig()


def test_orchestrator_reloads_on_change(tmp_path: Path) -> None:
    path = tmp_path / rc.ORCHESTRATOR_FILE
    path.write_text("turn_limits: {max_tool_calls: 10}\n", encoding="utf-8")
    assert rc.orchestrator_config(tmp_path).turn_limits.max_tool_calls == 10
    path.write_text("turn_limits: {max_tool_calls: 12}\n", encoding="utf-8")
    stat = path.stat()
    os.utime(path, (stat.st_atime, stat.st_mtime + 5))
    assert rc.orchestrator_config(tmp_path).turn_limits.max_tool_calls == 12


def test_settings_read_minio_variables(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("ZORO_OBJECT_STORE", "minio")
    monkeypatch.setenv("ZORO_MINIO_ENDPOINT", "127.0.0.1:9000")
    monkeypatch.setenv("ZORO_MINIO_ACCESS_KEY", "minio-user")
    monkeypatch.setenv("ZORO_MINIO_SECRET_KEY", "minio-pass-123")
    monkeypatch.setenv("ZORO_MINIO_BUCKET", "zoro-test")
    monkeypatch.setenv("ZORO_MINIO_SECURE", "true")
    s = Settings(_env_file=None, env="test")
    assert s.object_store == "minio" and s.minio_endpoint == "127.0.0.1:9000"
    assert s.minio_access_key is not None and s.minio_access_key.get_secret_value() == "minio-user"
    assert s.minio_secret_key is not None and s.minio_bucket == "zoro-test" and s.minio_secure is True


def test_env_example_lists_every_variable_the_code_reads() -> None:
    import re

    env_example = (REPO_CONFIG.parent / ".env.example").read_text(encoding="utf-8")
    declared = set(re.findall(r"^([A-Z][A-Z0-9_]+)=", env_example, flags=re.M))
    app_dir = Path(__file__).resolve().parents[3] / "app"
    source = "\n".join(p.read_text(encoding="utf-8") for p in app_dir.rglob("*.py"))
    named = set(
        re.findall(r"\"((?:[A-Z][A-Z0-9]*_)+(?:KEY|TOKEN|SECRET|ID|URL|ENTITIES|SCHEDULER))\"", source)
    )
    named |= {f"ZORO_{f.upper()}" for f in Settings.model_fields}
    for yml in REPO_CONFIG.glob("*.yaml"):
        text = yml.read_text(encoding="utf-8")
        named |= set(re.findall(r"\b\w*_env:\s*([A-Z][A-Z0-9_]+)\b", text))
        for listed in re.findall(r"credentials_env:\s*\[([^\]]*)\]", text):
            named |= {n.strip() for n in listed.split(",") if n.strip()}
    missing = sorted(n for n in named if n not in declared)
    assert missing == [], f".env.example is missing: {missing}"
    # Every settings value must parse from .env.example as written (empty means "default").
    values = dict(re.findall(r"^(ZORO_[A-Z0-9_]+)=(.*)$", env_example, flags=re.M))
    overrides = {k[5:].lower(): v for k, v in values.items() if v and k[5:].lower() in Settings.model_fields}
    Settings(_env_file=None, **overrides)
