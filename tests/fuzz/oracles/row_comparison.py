"""Numeric normalization and row comparison for live fuzz oracles."""

from __future__ import annotations

from decimal import Decimal
from typing import Any

def _normalize_cell(value: Any) -> Any:
    if isinstance(value, Decimal):
        return round(float(value), 6)
    if isinstance(value, float):
        return round(value, 6)
    return value


def _normalize_rows(rows: list[tuple]) -> list[tuple]:
    normalized = [tuple(_normalize_cell(c) for c in row) for row in rows]
    return sorted(normalized, key=lambda row: tuple(str(c) for c in row))


def compare_rows(a: list[tuple], b: list[tuple]) -> str | None:
    na, nb = _normalize_rows(a), _normalize_rows(b)
    if na == nb:
        return None
    if len(na) != len(nb):
        return f"row count differs: json={len(na)} sql={len(nb)}"
    for idx, (ra, rb) in enumerate(zip(na, nb, strict=True)):
        if ra != rb:
            return f"first diff at sorted-row {idx}: json={ra!r} sql={rb!r}"
    return "unknown diff"


