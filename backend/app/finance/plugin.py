"""Registers the finance package: services, tools, intents, router, permissions, capabilities.

Services: ``finance_categories`` (CategoryConfigSource), ``finance_imports`` (ImportService),
``finance_analytics`` (FinanceAnalytics), ``finance_insights`` (FinanceInsights),
``finance_gmail`` (GmailReceiptConnector), ``finance_account_aggregator`` (unavailable interface).
The Gmail client is read lazily: service ``gmail_client`` when one is provided, else the
communications package's ``gmail`` service behind `gmail_adapter.CommunicationsGmail`.
"""

from __future__ import annotations

import importlib
from pathlib import Path
from typing import Any

from app.finance.analytics import FinanceAnalytics
from app.finance.categories import CATEGORIES_FILE, CategoryConfigSource
from app.finance.connectors import (
    GMAIL_SERVICE,
    GmailClient,
    GmailReceiptConnector,
    UnavailableAccountAggregator,
    static_capabilities,
)
from app.finance.importer import ImportService
from app.finance.insights import FinanceInsights
from app.finance.intents import build_intents
from app.finance.tools import READ, WRITE, FinanceServices, build_tools

_REPO_CONFIG = Path(__file__).resolve().parents[3] / "config"


def categories_path(settings: Any) -> Path:
    configured = getattr(settings, "config_dir", None)
    candidate = Path(configured) / CATEGORIES_FILE if configured else None
    return candidate if candidate is not None and candidate.exists() else _REPO_CONFIG / CATEGORIES_FILE


def register(reg: Any) -> None:
    require_device = importlib.import_module("app.api.deps").require_device
    from app.finance.api import build_router

    session_factory = reg.service("session_factory")
    clock = reg.service("clock")
    categories = CategoryConfigSource(categories_path(reg.service("settings")))
    imports = ImportService(session_factory, categories, clock)
    analytics = FinanceAnalytics(session_factory, categories)
    insights = FinanceInsights(session_factory, categories, analytics, clock)

    def gmail_client() -> GmailClient | None:
        """Looked up on every use: an explicit ``gmail_client`` service, else the communications
        package's Gmail client (service ``gmail``) behind an adapter. Load order does not matter."""
        if reg.has_service(GMAIL_SERVICE):
            client = reg.service(GMAIL_SERVICE)
            return client if isinstance(client, GmailClient) else None
        if reg.has_service("gmail"):
            from app.finance.gmail_adapter import CommunicationsGmail

            return CommunicationsGmail(reg.service("gmail"))
        return None

    gmail = GmailReceiptConnector(gmail_client, session_factory, categories, clock)

    for name, obj in {
        "finance_categories": categories,
        "finance_imports": imports,
        "finance_analytics": analytics,
        "finance_insights": insights,
        "finance_gmail": gmail,
        "finance_account_aggregator": UnavailableAccountAggregator(),
    }.items():
        reg.provide(name, obj)

    reg.add_permission(READ, "Read your imported bank and UPI transactions", True)
    reg.add_permission(
        WRITE, "Import statements, set budgets and change categories (never touches an account)", True
    )
    for spec in build_tools(FinanceServices(analytics, insights, categories)):
        reg.add_tool(spec)
    for intent in build_intents(categories):
        reg.add_intent(intent)
    for cap in static_capabilities():
        reg.add_capability(cap)
    reg.add_capability(gmail.capability)
    reg.add_router(build_router(reg, require_device))
