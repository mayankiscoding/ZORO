"""`config/india_charges.yaml`: charges, tax estimate rates, analytics thresholds, broker endpoints.

Every number is parsed as `Decimal` from a string; a float in the file is refused. The file is
re-read when its modification time changes. A missing or malformed file is a configuration error
for the cost model (charges are never guessed).
"""

from __future__ import annotations

from decimal import Decimal
from pathlib import Path
from typing import Any

import yaml
from pydantic import BaseModel, ConfigDict, field_validator

from app.core.errors import ConfigError

CHARGES_FILE = "india_charges.yaml"
_REPO_CONFIG = Path(__file__).resolve().parents[3] / "config"


class _Strict(BaseModel):
    model_config = ConfigDict(frozen=True, extra="ignore")

    @field_validator("*", mode="before")
    @classmethod
    def _no_floats(cls, value: Any) -> Any:
        if isinstance(value, float):
            raise ValueError("write numbers as quoted decimal strings, not floats")
        return value


class ProductCharges(_Strict):
    brokerage_percent: Decimal
    brokerage_max_per_order: Decimal | None = None
    stt_buy_percent: Decimal
    stt_sell_percent: Decimal
    stamp_duty_buy_percent: Decimal
    dp_charge_per_scrip_sell: Decimal = Decimal(0)


class ChargesConfig(_Strict):
    verified_on: str
    source: str
    verification: str = "unverified"
    note: str = ""
    gst_percent: Decimal
    sebi_fee_per_crore: Decimal
    exchange_transaction_percent: dict[str, Decimal]
    delivery: ProductCharges
    intraday: ProductCharges


class TaxConfig(_Strict):
    verified_on: str
    source: str
    verification: str = "unverified"
    note: str = ""
    stcg_percent: Decimal
    ltcg_percent: Decimal
    ltcg_annual_exemption: Decimal
    long_term_after_days: int = 365


class AnalyticsConfig(_Strict):
    trading_days_per_year: int = 252
    risk_free_rate_percent: Decimal = Decimal(0)
    unusual_window: int = 20
    unusual_return_z: Decimal = Decimal("2.5")
    unusual_volume_z: Decimal = Decimal("3.0")
    concentration_single_percent: Decimal = Decimal(20)
    var_confidence_percent: Decimal = Decimal(95)


class BrokerConfig(_Strict):
    title: str
    api_base_url: str
    handoff_url: str
    docs_url: str = ""
    login_url: str = ""
    key_env: str = ""
    secret_env: str = ""
    client_id_env: str = ""
    token_env: str = ""


class InvestmentConfig(_Strict):
    version: int = 1
    charges: ChargesConfig
    tax: TaxConfig
    analytics: AnalyticsConfig = AnalyticsConfig()
    providers: dict[str, BrokerConfig] = {}


def config_path(settings: Any) -> Path:
    configured = getattr(settings, "config_dir", None)
    candidate = Path(configured) / CHARGES_FILE if configured else None
    return candidate if candidate is not None and candidate.exists() else _REPO_CONFIG / CHARGES_FILE


def parse_config(text: str) -> InvestmentConfig:
    try:
        raw = yaml.safe_load(text)
        return InvestmentConfig.model_validate(raw)
    except (yaml.YAMLError, ValueError) as exc:
        raise ConfigError(f"{CHARGES_FILE} is not valid: {exc}") from exc


class InvestmentConfigSource:
    """Registered as service ``investment_config``."""

    def __init__(self, path: Path) -> None:
        self._path = path
        self._mtime: float | None = None
        self._config: InvestmentConfig | None = None

    @property
    def path(self) -> Path:
        return self._path

    def current(self) -> InvestmentConfig:
        try:
            mtime = self._path.stat().st_mtime
        except OSError as exc:
            if self._config is not None:
                return self._config
            raise ConfigError(f"{self._path} is missing") from exc
        if self._config is None or mtime != self._mtime:
            self._config = parse_config(self._path.read_text(encoding="utf-8"))
            self._mtime = mtime
        return self._config


class StaticConfigSource(InvestmentConfigSource):
    """A fixed config (tests, replays)."""

    def __init__(self, config: InvestmentConfig) -> None:
        super().__init__(Path("<static>"))
        self._config = config

    def current(self) -> InvestmentConfig:
        assert self._config is not None
        return self._config
