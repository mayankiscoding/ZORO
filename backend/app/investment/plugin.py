"""Registers the investment package: services, tools, intents, router, permissions, capabilities.

Services: ``investment`` (InvestmentServices), ``investment_store`` (InvestmentStore),
``investment_config`` (InvestmentConfigSource). Broker adapters are read-only and are created
whatever the credentials; without them they report "requires_credentials" (never a startup error).
"""

from __future__ import annotations

import importlib
import os
from collections.abc import Mapping
from typing import Any

import httpx

from app.investment.config import InvestmentConfigSource, config_path
from app.investment.intents import build_intents
from app.investment.orders import capabilities
from app.investment.providers.csv_provider import CsvProvider
from app.investment.providers.dhan import DhanAdapter
from app.investment.providers.kite import KiteAdapter
from app.investment.services import InvestmentServices
from app.investment.store import InvestmentStore
from app.investment.tools import ORDER, READ, WRITE, build_tools


def build_services(
    reg: Any,
    *,
    config: InvestmentConfigSource | None = None,
    env: Mapping[str, str] | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
) -> InvestmentServices:
    env = os.environ if env is None else env
    config = config or InvestmentConfigSource(config_path(reg.service("settings")))
    clock = reg.service("clock")
    secrets = reg.service("secrets")
    store = InvestmentStore(reg.service("session_factory"), clock)
    brokers: dict[str, Any] = {}
    providers = config.current().providers
    if "kite" in providers:
        brokers["kite"] = KiteAdapter(providers["kite"], secrets, clock, env, transport)
    if "dhan" in providers:
        brokers["dhan"] = DhanAdapter(providers["dhan"], secrets, clock, env, transport)
    return InvestmentServices(store=store, config=config, csv=CsvProvider(store), brokers=brokers)


def register(
    reg: Any, *, env: Mapping[str, str] | None = None, transport: httpx.AsyncBaseTransport | None = None
) -> None:
    require_device = importlib.import_module("app.api.deps").require_device
    from app.investment.api import build_router

    svc = build_services(reg, env=env, transport=transport)
    environ = os.environ if env is None else env
    reg.provide("investment", svc)
    reg.provide("investment_store", svc.store)
    reg.provide("investment_config", svc.config)

    reg.add_permission(READ, "Read your holdings, watchlists and investment analysis", True)
    reg.add_permission(WRITE, "Import holdings and prices, edit watchlists and record paper trades", True)
    reg.add_permission(ORDER, "Prepare order tickets you place yourself (always asks for Face ID)", True)
    for spec in build_tools(svc):
        reg.add_tool(spec)
    for intent in build_intents():
        reg.add_intent(intent)
    reg.add_capability(lambda: capabilities(svc.config.current(), environ))
    reg.add_router(build_router(reg, svc, require_device))
