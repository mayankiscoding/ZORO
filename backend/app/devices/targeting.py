"""Which device runs a device tool. The rule lives in the kernel (`app.tools.targeting`) so the
executor and the hub pick the same device; this module keeps the devices package's import path."""

from __future__ import annotations

from app.tools.targeting import Problem, Reason, TargetChoice, select_target, supports

__all__ = ["Problem", "Reason", "TargetChoice", "select_target", "supports"]
