"""`/v1/finance` routes. Thin: every rule lives in the services. Device auth on everything, the
finance permission grants checked like the tools check them, secret-looking fields refused."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from datetime import date
from decimal import Decimal
from typing import Annotated, Any

from fastapi import APIRouter, Depends, File, Form, Query, UploadFile

from app.core.errors import Forbidden, NotFound, ValidationFailed, ZoroError
from app.core.money import to_paise
from app.finance.analytics import SearchFilters
from app.finance.connectors import ReceiptSyncResult
from app.finance.guard import reject_secret_fields
from app.finance.periods import Period, PeriodError, local_today, resolve_period
from app.finance.schemas import (
    AccountOut,
    AlertList,
    BudgetIn,
    BudgetStatus,
    CashflowForecast,
    CategoryBreakdown,
    CategoryOut,
    CategoryOverride,
    ChannelName,
    Direction,
    ImportStatus,
    IncomeExpense,
    MerchantReport,
    OcrImportRequest,
    RecurringReport,
    SpendingSummary,
    TransactionList,
    TransactionOut,
)
from app.finance.suggest import SuggestResult, suggest_categories
from app.schemas.security import Capability

MAX_UPLOAD_BYTES = 20 * 1024 * 1024


class PayloadTooLarge(ZoroError):
    code = "payload_too_large"
    status = 413
    default_message = "Statements up to 20 MB are accepted."


def build_router(reg: Any, require_device: Callable[..., Awaitable[Any]]) -> APIRouter:
    router = APIRouter(
        prefix="/finance", tags=["finance"],
        dependencies=[Depends(require_device), Depends(reject_secret_fields)],
    )  # fmt: skip

    def svc(name: str) -> Any:
        return reg.service(name)

    def grant(key: str) -> Callable[[], Awaitable[None]]:
        async def check() -> None:
            if not await svc("permissions").is_granted(key):
                raise Forbidden(
                    f"Allow '{key}' in Security and privacy first.", code=f"permission_not_granted:{key}"
                )

        return check

    can_read = [Depends(grant("finance.read"))]
    can_write = [Depends(grant("finance.write"))]

    def today() -> date:
        return local_today(svc("clock").now())

    def period_of(key: str | None, start: date | None = None, end: date | None = None) -> Period:
        try:
            if start is not None or end is not None:
                if start is None or end is None:
                    raise PeriodError("give both start and end")
                return resolve_period(f"{start.isoformat()}..{end.isoformat()}", today())
            return resolve_period(key, today())
        except PeriodError as exc:
            raise ValidationFailed(str(exc), code="invalid_period") from exc

    # ------------------------------------------------------------ imports

    @router.post("/imports", response_model=ImportStatus, dependencies=can_write)
    async def upload_statement(
        file: Annotated[UploadFile, File()], account_name: Annotated[str | None, Form(max_length=120)] = None
    ) -> ImportStatus:
        data = await file.read(MAX_UPLOAD_BYTES + 1)
        if len(data) > MAX_UPLOAD_BYTES:
            raise PayloadTooLarge()
        result: ImportStatus = await svc("finance_imports").import_file(
            file.filename or "statement", data, account_name=account_name
        )
        return result

    @router.post("/imports/ocr", response_model=ImportStatus, dependencies=can_write)
    async def import_ocr_text(body: OcrImportRequest) -> ImportStatus:
        result: ImportStatus = await svc("finance_imports").import_ocr_text(
            body.text, body.filename, account_name=body.account_name
        )
        return result

    @router.get("/imports", response_model=list[ImportStatus], dependencies=can_read)
    async def list_imports(limit: Annotated[int, Query(ge=1, le=200)] = 50) -> list[ImportStatus]:
        result: list[ImportStatus] = await svc("finance_imports").recent(limit)
        return result

    @router.get("/imports/{import_id}", response_model=ImportStatus, dependencies=can_read)
    async def import_status(import_id: str) -> ImportStatus:
        result: ImportStatus | None = await svc("finance_imports").status(import_id)
        if result is None:
            raise NotFound("No such import.", code="import_not_found")
        return result

    # ------------------------------------------------------------ records

    @router.get("/accounts", response_model=list[AccountOut], dependencies=can_read)
    async def accounts() -> list[AccountOut]:
        result: list[AccountOut] = await svc("finance_imports").accounts()
        return result

    @router.get("/transactions", response_model=TransactionList, dependencies=can_read)
    async def transactions(
        period: str = "last_30_days", start: date | None = None, end: date | None = None,
        category: str | None = None, merchant: str | None = None, direction: Direction | None = None,
        channel: ChannelName | None = None, account_id: str | None = None,
        q: Annotated[str | None, Query(max_length=100)] = None,
        min_amount: Decimal | None = None, max_amount: Decimal | None = None,
        include_duplicates: bool = False,
        cursor: Annotated[str | None, Query(pattern=r"^\d{1,7}$")] = None,
        limit: Annotated[int, Query(ge=1, le=200)] = 50,
    ) -> TransactionList:  # fmt: skip
        filters = SearchFilters(
            query=q, category=category, merchant=merchant, direction=direction, channel=channel,
            account_id=account_id, include_duplicates=include_duplicates,
            min_paise=to_paise(min_amount) if min_amount is not None else None,
            max_paise=to_paise(max_amount) if max_amount is not None else None,
        )  # fmt: skip
        result: TransactionList = await svc("finance_analytics").search(
            period_of(period, start, end), filters, limit=limit, offset=int(cursor or 0)
        )
        return result

    @router.put(
        "/transactions/{transaction_id}/category", response_model=TransactionOut, dependencies=can_write
    )
    async def override_category(transaction_id: str, body: CategoryOverride) -> TransactionOut:
        out, _changed = await svc("finance_insights").recategorize(
            transaction_id, body.category, apply_to_merchant=body.apply_to_merchant
        )
        result: TransactionOut = out
        return result

    # ------------------------------------------------------------ analytics

    @router.get("/summary", response_model=SpendingSummary, dependencies=can_read)
    async def summary(
        period: str = "this_month",
        start: date | None = None,
        end: date | None = None,
        category: str | None = None,
    ) -> SpendingSummary:
        result: SpendingSummary = await svc("finance_analytics").spending_summary(
            period_of(period, start, end), category
        )
        return result

    @router.get("/income-expense", response_model=IncomeExpense, dependencies=can_read)
    async def income_expense(period: str = "this_year") -> IncomeExpense:
        result: IncomeExpense = await svc("finance_analytics").income_expense(period_of(period))
        return result

    @router.get("/merchants", response_model=MerchantReport, dependencies=can_read)
    async def merchants(period: str = "this_month", merchant: str | None = None) -> MerchantReport:
        result: MerchantReport = await svc("finance_analytics").merchant_report(period_of(period), merchant)
        return result

    @router.get("/categories", response_model=list[CategoryOut], dependencies=can_read)
    async def categories() -> list[CategoryOut]:
        config = svc("finance_categories").current()
        return [
            CategoryOut(id=c.id, name=c.name("en"), name_hi=c.name("hi"), name_hinglish=c.name("hinglish"),
                        direction=c.direction)
            for c in config.categories
        ]  # fmt: skip

    @router.get("/categories/breakdown", response_model=CategoryBreakdown, dependencies=can_read)
    async def breakdown(period: str = "this_month", direction: Direction = "debit") -> CategoryBreakdown:
        result: CategoryBreakdown = await svc("finance_analytics").category_breakdown(
            period_of(period), direction
        )
        return result

    @router.post("/categories/suggest", response_model=SuggestResult, dependencies=can_write)
    async def suggest() -> SuggestResult:
        mode = await svc("privacy_state").get_mode()
        gateway = svc("gateway") if reg.has_service("gateway") else None
        return await suggest_categories(svc("session_factory"), svc("finance_categories"), gateway, mode)

    @router.get("/budgets", response_model=BudgetStatus, dependencies=can_read)
    async def budgets() -> BudgetStatus:
        result: BudgetStatus = await svc("finance_insights").budget_status(period_of("this_month"))
        return result

    @router.put("/budgets/{category}", response_model=BudgetStatus, dependencies=can_write)
    async def put_budget(category: str, body: BudgetIn) -> BudgetStatus:
        await svc("finance_insights").set_budget(category, body.limit)
        result: BudgetStatus = await svc("finance_insights").budget_status(period_of("this_month"), category)
        return result

    @router.get("/recurring", response_model=RecurringReport, dependencies=can_read)
    async def recurring() -> RecurringReport:
        result: RecurringReport = await svc("finance_insights").recurring(today())
        return result

    @router.get("/forecast", response_model=CashflowForecast, dependencies=can_read)
    async def forecast(horizon_days: Annotated[int, Query(ge=7, le=90)] = 30) -> CashflowForecast:
        result: CashflowForecast = await svc("finance_insights").forecast(today(), horizon_days)
        return result

    @router.get("/alerts", response_model=AlertList, dependencies=can_read)
    async def alerts() -> AlertList:
        result: AlertList = await svc("finance_insights").alerts(today(), period_of("this_month"))
        return result

    # ------------------------------------------------------------ connectors

    @router.get("/connectors", response_model=list[Capability], dependencies=can_read)
    async def connectors() -> list[Capability]:
        return svc("capabilities").all(domain="finance")  # type: ignore[no-any-return]

    @router.post("/connectors/gmail/sync", response_model=ReceiptSyncResult, dependencies=can_write)
    async def gmail_sync(days: Annotated[int, Query(ge=1, le=365)] = 30) -> ReceiptSyncResult:
        result: ReceiptSyncResult = await svc("finance_gmail").sync(days=days)
        return result

    return router
