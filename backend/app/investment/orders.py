"""Order tickets and broker handoff. ZORO never places an order: the CRITICAL tool
`investment.prepare_order_ticket` needs a biometric approval and returns what the owner should
enter in the broker's own app. No code in this package calls a broker order endpoint."""

from __future__ import annotations

from collections.abc import Mapping
from datetime import datetime
from decimal import Decimal
from typing import Literal, Self

from pydantic import Field, field_validator, model_validator

from app.core.money import format_inr, round_money
from app.core.types import CapabilityStatus, IntegrationLevel
from app.investment.config import InvestmentConfig
from app.investment.costs import order_charges
from app.investment.schemas import (
    NOT_ADVICE,
    ChargeBreakdown,
    Exchange,
    Product,
    Quote,
    Side,
    normalise_symbol,
)
from app.schemas.common import LabelValue, ZModel
from app.schemas.security import Capability
from app.tools.spec import ApprovalView

ORDER_RULES = (
    "ZORO never places orders; you place them in your broker's app.",
    "Retail API order placement needs a broker-whitelisted static IP.",
    "Brokers cap API orders at 10 per second; above that the exchange requires algo registration.",
    "Broker API sessions need a fresh login with 2FA every day.",
)


class OrderTicketIn(ZModel):
    symbol: str
    exchange: Exchange = "NSE"
    side: Side
    quantity: int = Field(ge=1, le=1_000_000)
    order_type: Literal["market", "limit"] = "market"
    limit_price: Decimal | None = Field(default=None, gt=0)
    product: Product = "delivery"
    broker: Literal["kite", "dhan", "other"] = "kite"

    @field_validator("symbol")
    @classmethod
    def _symbol(cls, value: str) -> str:
        return normalise_symbol(value)

    @model_validator(mode="after")
    def _price(self) -> Self:
        if self.order_type == "limit" and self.limit_price is None:
            raise ValueError("a limit order needs limit_price")
        if self.order_type == "market" and self.limit_price is not None:
            raise ValueError("a market order takes no limit_price")
        return self


class BrokerHandoff(ZModel):
    broker: str
    title: str
    url: str | None
    steps: list[str]


class OrderTicket(ZModel):
    symbol: str
    exchange: Exchange
    side: Side
    quantity: int
    order_type: Literal["market", "limit"]
    limit_price: Decimal | None
    product: Product
    reference_price: Decimal | None
    reference_source: str | None
    reference_as_of: datetime | None
    estimated_value: Decimal | None
    estimated_charges: ChargeBreakdown | None
    handoff: BrokerHandoff
    placed_by_zoro: Literal[False] = False
    rules: list[str] = Field(default_factory=lambda: list(ORDER_RULES))
    disclaimer: str = NOT_ADVICE


def _order_line(args: OrderTicketIn) -> str:
    price = "at market" if args.limit_price is None else f"limit {format_inr(args.limit_price)}"
    product = "delivery" if args.product == "delivery" else "intraday"
    return f"{args.side.upper()} {args.quantity} {args.symbol} on {args.exchange}, {price}, {product}"


def approval_view(args: OrderTicketIn) -> ApprovalView:
    return ApprovalView(
        title=f"Prepare order ticket: {_order_line(args)}",
        summary="ZORO prepares the ticket only. You place the order yourself in your broker's app.",
        details=(
            LabelValue(label="Order", value=_order_line(args)),
            LabelValue(label="Broker", value=args.broker),
            LabelValue(label="Placed by ZORO", value="No"),
        ),
    )


def build_ticket(args: OrderTicketIn, quote: Quote | None, cfg: InvestmentConfig) -> OrderTicket:
    price = args.limit_price if args.limit_price is not None else (quote.last_price if quote else None)
    charges = None
    if price is not None:
        charges = order_charges(cfg.charges, side=args.side, quantity=args.quantity, price=price,
                                product=args.product, exchange=args.exchange)  # fmt: skip
    broker = cfg.providers.get(args.broker)
    title = broker.title if broker else "your broker"
    steps = [
        f"Open {title}.",
        f"Find {args.symbol} on {args.exchange}.",
        f"Enter: {_order_line(args)}.",
        "Check the quantity, price and charges, then place the order yourself.",
    ]
    return OrderTicket(
        symbol=args.symbol, exchange=args.exchange, side=args.side, quantity=args.quantity,
        order_type=args.order_type, limit_price=args.limit_price, product=args.product,
        reference_price=quote.last_price if quote else None, reference_source=quote.source if quote else None,
        reference_as_of=quote.as_of if quote else None,
        estimated_value=round_money(price * args.quantity) if price is not None else None,
        estimated_charges=charges,
        handoff=BrokerHandoff(broker=args.broker, title=title, url=broker.handoff_url if broker else None, steps=steps),
    )  # fmt: skip


def capabilities(cfg: InvestmentConfig, env: Mapping[str, str]) -> list[Capability]:
    caps = [
        Capability(id="investment.csv_import", title="Import holdings and daily prices from CSV", domain="investment",
                   status=CapabilityStatus.WORKING_LOCAL, integration_level=IntegrationLevel.MANUAL_FALLBACK,
                   note="Works with no credentials; prices are as of the imported dates."),
        Capability(id="investment.research", title="Stock analysis, backtests and paper trading", domain="investment",
                   status=CapabilityStatus.WORKING_LOCAL, integration_level=IntegrationLevel.FULLY_INTEGRATED,
                   note="Deterministic analytics on your data. Not investment advice."),
        Capability(id="investment.orders.handoff", title="Order ticket handed off to your broker app",
                   domain="investment", status=CapabilityStatus.MANUAL_USER_STEP,
                   integration_level=IntegrationLevel.DEEP_LINK_HANDOFF, note=" ".join(ORDER_RULES)),
        Capability(id="investment.orders.placement", title="Placing orders through a broker API", domain="investment",
                   status=CapabilityStatus.UNAVAILABLE, integration_level=IntegrationLevel.UNAVAILABLE,
                   note="Deliberately not built. " + " ".join(ORDER_RULES[1:])),
        Capability(id="investment.fundamentals", title="Company fundamentals", domain="investment",
                   status=CapabilityStatus.UNAVAILABLE, integration_level=IntegrationLevel.UNAVAILABLE,
                   note="No licensed fundamentals source is configured; exchange sites are not scraped."),
        Capability(id="investment.news", title="Stock news and sentiment", domain="investment",
                   status=CapabilityStatus.UNAVAILABLE, integration_level=IntegrationLevel.UNAVAILABLE,
                   note="No licensed news source is configured."),
    ]  # fmt: skip
    for name, broker in sorted(cfg.providers.items()):
        required = [e for e in (broker.key_env, broker.secret_env, broker.client_id_env) if e]
        present = all(env.get(e) for e in required)
        caps.append(
            Capability(
                id=f"investment.provider.{name}", title=f"{broker.title} (read-only)", domain="investment",
                status=CapabilityStatus.WORKING_INTEGRATION if present else CapabilityStatus.REQUIRES_CREDENTIALS,
                integration_level=IntegrationLevel.OFFICIAL_API, requires=required,
                note=("Credentials present; session state at /v1/investments/providers. " if present else "")
                + "Holdings, positions, quotes and daily candles only. Endpoint shapes not re-verified.",
            )
        )  # fmt: skip
    return caps
