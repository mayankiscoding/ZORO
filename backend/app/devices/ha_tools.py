"""`homeassistant.call_service` (MEDIUM) and `homeassistant.get_state` (LOW, read-only)."""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Any, Literal

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field

from app.core.types import AgentId, DataClass, RiskLevel
from app.devices.contract import PERM_HOME
from app.devices.homeassistant import HomeAssistantClient
from app.devices.speech import pick
from app.schemas.common import LabelValue, UICard
from app.tools.spec import ApprovalView, ToolContext, ToolSpec

EntityId = Annotated[str, Field(pattern=r"^[a-z_]+\.[a-z0-9_]+$", max_length=120)]


class CallServiceIn(BaseModel):
    model_config = ConfigDict(extra="ignore")

    domain: Annotated[str, Field(pattern=r"^[a-z_]{2,40}$")]
    service: Annotated[str, Field(pattern=r"^[a-z_]{2,40}$")]
    entity_ids: list[EntityId] = Field(default_factory=list, max_length=20)
    brightness_pct: int | None = Field(default=None, ge=0, le=100)
    temperature: float | None = Field(default=None, ge=5, le=35)


class EntityState(BaseModel):
    entity_id: str
    state: str


class CallServiceOut(BaseModel):
    domain: str
    service: str
    entity_ids: list[str]
    names: list[str]
    changed: list[EntityState] = Field(default_factory=list)
    source: Literal["home_assistant"] = "home_assistant"
    executed_at: AwareDatetime


class GetStateIn(BaseModel):
    model_config = ConfigDict(extra="ignore")

    entity_id: EntityId


class GetStateOut(BaseModel):
    entity_id: str
    name: str
    state: str
    unit: str | None = None
    last_changed: AwareDatetime | None = None
    source: Literal["home_assistant"] = "home_assistant"
    retrieved_at: AwareDatetime


def _when(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        moment = datetime.fromisoformat(value)
    except ValueError:
        return None
    return moment if moment.tzinfo is not None else None


def _call_summary(result: CallServiceOut, lang: str) -> str:
    who = ", ".join(result.names)
    if result.service == "turn_on":
        return pick(lang, (f"Turned on {who}.", f"{who} चालू कर दिया।", f"{who} on kar diya."))
    if result.service == "turn_off":
        return pick(lang, (f"Turned off {who}.", f"{who} बंद कर दिया।", f"{who} band kar diya."))
    s = result.service.replace("_", " ")
    return pick(lang, (f"Done: {s} for {who}.", f"{who} के लिए {s} हो गया।", f"{who} ke liye {s} ho gaya."))


def _state_summary(result: GetStateOut, lang: str) -> str:
    value = f"{result.state} {result.unit}" if result.unit else result.state
    n = result.name
    return pick(lang, (f"{n} is {value}.", f"{n} अभी {value} है।", f"{n} abhi {value} hai."))


def _state_card(result: GetStateOut) -> UICard:
    return UICard(kind="home_state", title=result.name, payload=result.model_dump(mode="json"))


def _call_view(args: CallServiceIn) -> ApprovalView:
    targets = ", ".join(args.entity_ids) or "nothing"
    details = [
        LabelValue(label="Action", value=f"{args.domain}.{args.service}"),
        LabelValue(label="Devices", value=targets),
    ]
    if args.brightness_pct is not None:
        details.append(LabelValue(label="Brightness", value=f"{args.brightness_pct}%"))
    if args.temperature is not None:
        details.append(LabelValue(label="Temperature", value=str(args.temperature)))
    return ApprovalView(
        title=f"Home Assistant: {args.service.replace('_', ' ')} {targets}",
        summary=f"{args.domain}.{args.service} → {targets}",
        details=tuple(details),
    )


def home_assistant_specs(client: HomeAssistantClient) -> list[ToolSpec]:
    async def call_service(ctx: ToolContext, args: CallServiceIn) -> CallServiceOut:
        entities = client.require_allowed(list(args.entity_ids), args.domain)
        data: dict[str, Any] = {}
        if args.brightness_pct is not None and args.domain == "light" and args.service == "turn_on":
            data["brightness_pct"] = args.brightness_pct
        if args.temperature is not None and args.domain == "climate" and args.service == "set_temperature":
            data["temperature"] = args.temperature
        changed = await client.call_service(args.domain, args.service, list(args.entity_ids), data)
        return CallServiceOut(
            domain=args.domain,
            service=args.service,
            entity_ids=list(args.entity_ids),
            names=[e.name for e in entities],
            changed=[
                EntityState(entity_id=str(item.get("entity_id")), state=str(item.get("state")))
                for item in changed
                if item.get("entity_id") in args.entity_ids
            ],
            executed_at=ctx.now(),
        )

    async def get_state(ctx: ToolContext, args: GetStateIn) -> GetStateOut:
        data = await client.get_state(args.entity_id)
        entity = client.config.entity(args.entity_id)
        raw_attributes = data.get("attributes")
        attributes: dict[str, Any] = raw_attributes if isinstance(raw_attributes, dict) else {}
        unit = attributes.get("unit_of_measurement")
        return GetStateOut(
            entity_id=args.entity_id,
            name=entity.name if entity is not None else args.entity_id,
            state=str(data["state"])[:100],
            unit=str(unit)[:20] if unit else None,
            last_changed=_when(data.get("last_changed")),
            retrieved_at=ctx.now(),
        )

    agents = frozenset({AgentId.DEVICE_CONTROL, AgentId.AUTOMATION})
    return [
        ToolSpec(
            name="homeassistant.call_service",
            description="Call an allowlisted Home Assistant action (lights, switches, fans, scenes, covers).",
            input_model=CallServiceIn,
            output_model=CallServiceOut,
            handler=call_service,
            risk=RiskLevel.MEDIUM,
            data_classes=frozenset({DataClass.PERSONAL}),
            permission=PERM_HOME,
            agents=agents,
            mcp_group="home-assistant-mcp",
            timeout_s=15,
            summarizer=_call_summary,
            approval_view=_call_view,
        ),
        ToolSpec(
            name="homeassistant.get_state",
            description="Read the current state of an allowlisted Home Assistant entity.",
            input_model=GetStateIn,
            output_model=GetStateOut,
            handler=get_state,
            risk=RiskLevel.LOW,
            data_classes=frozenset({DataClass.PERSONAL}),
            permission=PERM_HOME,
            agents=agents,
            mcp_group="home-assistant-mcp",
            timeout_s=15,
            summarizer=_state_summary,
            card=_state_card,
        ),
    ]
