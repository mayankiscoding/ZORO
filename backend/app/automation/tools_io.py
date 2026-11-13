"""Tool input and output models for the automation tools."""

from __future__ import annotations

from typing import Annotated

from pydantic import Field

from app.automation.schemas import AModel, RoutineIn, RoutineOut, RunOut


class ListIn(AModel):
    include_disabled: bool = True


class ListOut(AModel):
    routines: list[RoutineOut]


class RunToolIn(AModel):
    routine: Annotated[str, Field(min_length=1, max_length=80, description="Routine id or name.")]
    params: dict[str, str | int | float | bool] = Field(default_factory=dict, max_length=20)


class RunToolOut(RunOut):
    pass


class SaveIn(RoutineIn):
    pass


class SaveOut(AModel):
    routine: RoutineOut
