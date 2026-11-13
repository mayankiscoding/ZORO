"""`ToolSpec`s for every row of the device contract (executor "device", no handler)."""

from __future__ import annotations

from app.devices.contract import ROWS, DeviceToolRow
from app.devices.speech import APPROVAL_VIEWS, CARDS, SUMMARIZERS
from app.tools.spec import ToolSpec


def device_tool_spec(row: DeviceToolRow) -> ToolSpec:
    return ToolSpec(
        name=row.name,
        description=f"{row.description} Runs on the device ({row.native_api}).",
        input_model=row.input_model,
        output_model=row.output_model,
        handler=None,
        risk=row.risk,
        data_classes=frozenset({row.data_class}),
        permission=row.permission,
        agents=row.agents,
        mcp_group=row.mcp_group,
        executor="device",
        device_platforms=row.platforms,
        timeout_s=row.timeout_s,
        untrusted_output=row.untrusted_output,
        summarizer=SUMMARIZERS[row.name],
        card=CARDS.get(row.name),
        approval_view=APPROVAL_VIEWS.get(row.name),
    )


def device_tool_specs() -> list[ToolSpec]:
    return [device_tool_spec(row) for row in ROWS]
