"""Brokerage and statutory charges per order, and a capital-gains tax estimate.

Every line is computed in `Decimal` from `config/india_charges.yaml` and rounded half-even to the
paisa. GST applies to brokerage, the exchange transaction charge, the SEBI fee and the DP charge.
The DP charge is per scrip on a delivery sell. Brokers round some lines differently (STT to the
rupee, for instance), so the result is an estimate that matches a contract note to within paise.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from decimal import Decimal

from app.core.money import round_money
from app.investment.config import ChargesConfig, TaxConfig
from app.investment.schemas import ChargeBreakdown, Exchange, Product, Side, TaxEstimate

_HUNDRED = Decimal(100)
_CRORE = Decimal(10_000_000)
ZERO = Decimal("0.00")


def _pct(amount: Decimal, percent: Decimal) -> Decimal:
    return amount * percent / _HUNDRED


def order_charges(
    cfg: ChargesConfig,
    *,
    side: Side,
    quantity: Decimal | int,
    price: Decimal,
    product: Product = "delivery",
    exchange: Exchange = "NSE",
) -> ChargeBreakdown:
    qty = Decimal(quantity)
    if qty <= 0 or price <= 0:
        raise ValueError("quantity and price must be positive")
    turnover = qty * price
    rates = cfg.delivery if product == "delivery" else cfg.intraday
    brokerage = _pct(turnover, rates.brokerage_percent)
    if rates.brokerage_max_per_order is not None:
        brokerage = min(brokerage, rates.brokerage_max_per_order)
    stt = _pct(turnover, rates.stt_buy_percent if side == "buy" else rates.stt_sell_percent)
    txn_rate = cfg.exchange_transaction_percent.get(exchange)
    if txn_rate is None:
        raise ValueError(f"no exchange transaction rate configured for {exchange}")
    exchange_txn = _pct(turnover, txn_rate)
    sebi = turnover * cfg.sebi_fee_per_crore / _CRORE
    stamp = _pct(turnover, rates.stamp_duty_buy_percent) if side == "buy" else Decimal(0)
    dp = rates.dp_charge_per_scrip_sell if side == "sell" else Decimal(0)

    lines = {
        "brokerage": round_money(brokerage),
        "stt": round_money(stt),
        "exchange_transaction": round_money(exchange_txn),
        "sebi_fee": round_money(sebi),
        "stamp_duty": round_money(stamp),
        "dp_charge": round_money(dp),
    }
    taxable = lines["brokerage"] + lines["exchange_transaction"] + lines["sebi_fee"] + lines["dp_charge"]
    gst = round_money(_pct(taxable, cfg.gst_percent))
    total = sum(lines.values(), Decimal(0)) + gst
    return ChargeBreakdown(
        product=product,
        side=side,
        exchange=exchange,
        turnover=round_money(turnover),
        gst=gst,
        total=round_money(total),
        source=cfg.source,
        verified_on=cfg.verified_on,
        **lines,
    )


@dataclass(frozen=True)
class RealisedGain:
    bought_on: date
    sold_on: date
    gain: Decimal  # net of charges


def estimate_tax(cfg: TaxConfig, gains: list[RealisedGain]) -> TaxEstimate:
    """Equity capital-gains estimate for one financial year's realised gains.

    Losses offset gains within the same bucket only; LTCG gets the annual exemption. Cess,
    surcharge, carry-forward and cross-bucket set-off are not modelled.
    """
    short = sum(
        (g.gain for g in gains if (g.sold_on - g.bought_on).days <= cfg.long_term_after_days), Decimal(0)
    )
    long_ = sum(
        (g.gain for g in gains if (g.sold_on - g.bought_on).days > cfg.long_term_after_days), Decimal(0)
    )
    stcg_tax = round_money(_pct(max(short, Decimal(0)), cfg.stcg_percent))
    ltcg_taxable = max(long_ - cfg.ltcg_annual_exemption, Decimal(0))
    ltcg_tax = round_money(_pct(ltcg_taxable, cfg.ltcg_percent))
    return TaxEstimate(
        short_term_gain=round_money(short),
        long_term_gain=round_money(long_),
        stcg_tax=stcg_tax,
        ltcg_tax=ltcg_tax,
        total_tax=stcg_tax + ltcg_tax,
        basis=(
            f"Estimate: STCG {cfg.stcg_percent}%, LTCG {cfg.ltcg_percent}% above "
            f"Rs {cfg.ltcg_annual_exemption} (rates checked {cfg.verified_on}, {cfg.verification}). "
            "Cess, surcharge and loss set-off are not included."
        ),
    )
