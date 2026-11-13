"""Numeric normalization and row comparison for live fuzz oracles."""

from __future__ import annotations

from decimal import Decimal
import re
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


def compare_typed_rows(a: list[tuple], b: list[tuple], *, ordered: bool = False) -> str | None:
    """Compare exact non-numeric cells and numeric cells with explicit tolerance."""
    if len(a) != len(b):
        return f"row count differs: left={len(a)} right={len(b)}"
    left = a if ordered else sorted(a, key=lambda row: tuple(str(c) for c in row))
    right = b if ordered else sorted(b, key=lambda row: tuple(str(c) for c in row))
    for index, (lrow, rrow) in enumerate(zip(left, right, strict=True)):
        if len(lrow) != len(rrow):
            return f"row {index} width differs: left={lrow!r} right={rrow!r}"
        for column, (lvalue, rvalue) in enumerate(zip(lrow, rrow, strict=True)):
            lnumber, rnumber = _number(lvalue), _number(rvalue)
            if lnumber is not None and rnumber is not None:
                delta = abs(lnumber - rnumber)
                threshold = max(Decimal("0.000001"),
                                max(abs(lnumber), abs(rnumber)) * Decimal("0.000000001"))
                equal = delta <= threshold
            else:
                equal = lvalue == rvalue
            if not equal:
                return (f"row {index} column {column}: left={lvalue!r} "
                        f"right={rvalue!r}")
    return None


def _number(value: Any) -> Decimal | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float, Decimal)):
        return Decimal(str(value))
    if isinstance(value, str) and re.fullmatch(r"[+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?", value):
        return Decimal(value)
    return None


