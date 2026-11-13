from __future__ import annotations

from datetime import UTC, datetime
from decimal import Decimal

import httpx
import pytest

from app.finance.connectors import GmailMessage, GmailMessageRef, parse_receipt
from app.plugins import PluginRegistry
from tests.conftest import PairedDevice
from tests.finance.data import history_csv
from tests.finance.test_parsers import OCR_TEXT

D = Decimal


async def _upload(
    client: httpx.AsyncClient, device: PairedDevice, data: bytes, name: str = "h.csv"
) -> httpx.Response:
    return await client.post(
        "/v1/finance/imports", headers=device.headers,
        files={"file": (name, data, "text/csv")}, data={"account_name": "Main"},
    )  # fmt: skip


async def test_requires_a_signed_in_device(client: httpx.AsyncClient) -> None:
    response = await client.get("/v1/finance/summary")
    assert response.status_code == 401


async def test_upload_status_and_queries(client: httpx.AsyncClient, paired_device: PairedDevice) -> None:
    h = paired_device.headers
    first = await _upload(client, paired_device, history_csv())
    assert first.status_code == 200, first.text
    body = first.json()
    assert body["status"] == "completed" and body["account_name"] == "Main" and body["balance_check"] == "ok"
    again = (await _upload(client, paired_device, history_csv(), "copy.csv")).json()
    assert again["already_imported"] and again["id"] == body["id"]
    status = await client.get(f"/v1/finance/imports/{body['id']}", headers=h)
    assert status.json()["rows_imported"] == body["rows_imported"]
    assert (await client.get("/v1/finance/imports/nope", headers=h)).json()["code"] == "import_not_found"

    accounts = (await client.get("/v1/finance/accounts", headers=h)).json()
    assert accounts[0]["transactions"] == body["rows_imported"]

    summary = (await client.get("/v1/finance/summary", params={"period": "2026-11"}, headers=h)).json()
    assert summary["spent"] == "11693.25" and isinstance(summary["spent"], str)

    txns = (
        await client.get("/v1/finance/transactions", params={"period": "this_year", "limit": 5}, headers=h)
    ).json()
    assert len(txns["items"]) == 5 and txns["next_cursor"] == "5"
    more = (await client.get("/v1/finance/transactions",
                             params={"period": "this_year", "limit": 5, "cursor": "5"}, headers=h)).json()  # fmt: skip
    assert {t["id"] for t in more["items"]}.isdisjoint({t["id"] for t in txns["items"]})

    bad = await client.get("/v1/finance/summary", params={"period": "someday"}, headers=h)
    assert bad.status_code == 422 and bad.json()["code"] == "invalid_period"

    target = txns["items"][0]["id"]
    put = await client.put(f"/v1/finance/transactions/{target}/category", headers=h,
                           json={"category": "health", "apply_to_merchant": False})  # fmt: skip
    assert put.status_code == 200 and put.json()["category"] == "health"

    budget = await client.put("/v1/finance/budgets/food", headers=h, json={"limit": "1000.00"})
    assert budget.status_code == 200 and budget.json()["items"][0]["state"] == "exceeded"
    as_float = await client.put("/v1/finance/budgets/food", headers=h, json={"limit": 1000.5})
    assert as_float.status_code == 422

    for path in ("/recurring", "/forecast", "/alerts", "/categories", "/categories/breakdown", "/income-expense",
                 "/merchants", "/budgets"):  # fmt: skip
        assert (await client.get(f"/v1/finance{path}", headers=h)).status_code == 200, path


async def test_ocr_text_endpoint(client: httpx.AsyncClient, paired_device: PairedDevice) -> None:
    response = await client.post("/v1/finance/imports/ocr", headers=paired_device.headers,
                                 json={"text": OCR_TEXT, "filename": "scan.txt"})  # fmt: skip
    assert response.status_code == 200 and response.json()["rows_imported"] == 3


@pytest.mark.parametrize(
    "payload",
    [
        {"text": "x", "upi_pin": "1234"},
        {"text": "x", "meta": {"OTP": "123456"}},
        {"text": "x", "card": [{"cvv": "123"}]},
        {"text": "x", "bankPassword": "hunter2"},
    ],
)
async def test_secret_fields_are_refused(
    client: httpx.AsyncClient, paired_device: PairedDevice, payload: dict[str, object]
) -> None:
    response = await client.post("/v1/finance/imports/ocr", headers=paired_device.headers, json=payload)
    assert response.status_code == 400 and response.json()["code"] == "forbidden_field"
    assert "1234" not in response.text and "hunter2" not in response.text


async def test_secret_fields_refused_in_multipart_and_query(
    client: httpx.AsyncClient, paired_device: PairedDevice
) -> None:
    upload = await client.post("/v1/finance/imports", headers=paired_device.headers,
                               files={"file": ("h.csv", history_csv(), "text/csv")}, data={"mpin": "0000"})  # fmt: skip
    assert upload.status_code == 400 and upload.json()["code"] == "forbidden_field"
    query = await client.get("/v1/finance/summary", params={"password": "x"}, headers=paired_device.headers)
    assert query.status_code == 400


async def test_connectors_report_honest_status(
    client: httpx.AsyncClient, paired_device: PairedDevice, registry: PluginRegistry
) -> None:
    caps = {
        c["id"]: c for c in (await client.get("/v1/finance/connectors", headers=paired_device.headers)).json()
    }
    assert caps["finance.gmail_receipts"]["status"] == "requires_credentials"
    assert caps["finance.account_aggregator"]["status"] == "requires_partnership"
    assert "no OCR engine" in caps["finance.scanned_statement_ocr"]["note"]
    sync = await client.post("/v1/finance/connectors/gmail/sync", headers=paired_device.headers)
    assert sync.status_code == 503 and sync.json()["code"] == "requires_credentials"
    from app.core.errors import Unavailable

    with pytest.raises(Unavailable):
        await registry.service("finance_account_aggregator").fetch("consent")


class FakeGmail:
    def __init__(self, messages: list[GmailMessage]) -> None:
        self.messages = {m.id: m for m in messages}

    async def search(self, query: str, *, max_results: int = 50) -> list[GmailMessageRef]:
        return [GmailMessageRef(id=k) for k in self.messages]

    async def get(self, message_id: str) -> GmailMessage:
        return self.messages[message_id]


async def test_gmail_receipts_enrich_but_never_count(registry: PluginRegistry) -> None:
    from tests.finance.samples import generic_csv

    rows = [
        (
            datetime(2026, 11, 3).date(),
            "UPI/430612345611/Payment/9876543210@ybl/SBI",
            None,
            D("1299.00"),
            None,
        )
    ]
    await registry.service("finance_imports").import_file("b.csv", generic_csv(rows))
    mail = GmailMessage(id="m1", received_at=datetime(2026, 11, 3, 9, 0, tzinfo=UTC), sender="orders@nykaa.com",
                        subject="Your order is confirmed", text="Order ID: NYK12345\nOrder Total: ₹1,299.00")  # fmt: skip
    assert parse_receipt(mail) is not None
    registry.provide("gmail_client", FakeGmail([mail]))
    gmail = registry.service("finance_gmail")
    assert gmail.capability().status == "working_integration"
    result = await gmail.sync(days=30)
    assert (result.receipts, result.matched) == (1, 1)
    assert (await gmail.sync(days=30)).skipped_existing == 1
    from app.finance.analytics import SearchFilters
    from app.finance.periods import resolve_period

    found = await registry.service("finance_analytics").search(
        resolve_period("this_month", datetime(2026, 11, 13).date()), SearchFilters()
    )
    assert found.count == 1 and found.items[0].counterparty == "Nykaa" and found.total_debit == D("1299.00")
