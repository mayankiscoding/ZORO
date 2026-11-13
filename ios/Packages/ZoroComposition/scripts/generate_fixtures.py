"""Writes ZoroComposition's JSON fixtures from the real backend Pydantic models.

Run from backend/:  PYTHONPATH=. uv run --no-sync python ../ios/Packages/ZoroComposition/scripts/generate_fixtures.py
The basket fixtures are copied from ZoroCommerce's generated set (same models).
"""

from __future__ import annotations

import datetime as dt
import json
from pathlib import Path

from app.schemas.turns import ApprovalDecisionResult, ApprovalRequest

OUT = Path(__file__).resolve().parent.parent / "Tests" / "ZoroCompositionTests" / "Fixtures"


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    automation = ApprovalDecisionResult(
        approval_id="apr_1", owner="automation", approved=True, status="running", run_id="run_7", result={"queued": True}
    )
    (OUT / "approval_decision_result_automation.json").write_text(automation.model_dump_json(indent=1))
    turn = ApprovalDecisionResult(
        approval_id="apr_2",
        owner="turn",
        approved=False,
        status="completed",
        turn_id="turn_9",
        events=[{"type": "turn_completed", "turn_id": "turn_9"}],
    )
    (OUT / "approval_decision_result_turn.json").write_text(turn.model_dump_json(indent=1))
    request = ApprovalRequest(
        approval_id="apr_1",
        tool="automation.run_routine",
        risk="high",
        level="confirm",
        title="Run the evening routine",
        summary="Turn off the lights and lock the door.",
        details=[{"label": "Routine", "value": "Evening"}],
        action_digest="d" * 64,
        expires_at=dt.datetime(2030, 1, 1, tzinfo=dt.UTC),
        tainted=True,
    )
    frame = {"type": "approval_required", "approval": json.loads(request.model_dump_json())}
    (OUT / "approval_required_frame.json").write_text(json.dumps(frame, indent=1))


if __name__ == "__main__":
    main()
