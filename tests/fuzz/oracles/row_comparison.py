"""Numeric normalization and row comparison for live fuzz oracles."""

from __future__ import annotations

from decimal import Decimal
import re
from typing import Any, Collection

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


def compare_typed_rows(a: list[tuple], b: list[tuple], *, ordered: bool = False,
                       numeric_columns: Collection[int] = ()) -> str | None:
    """Compare text exactly and numeric cells with a fixed rounding tolerance.

    Only known numeric columns may coerce a driver's numeric strings. A text
    dimension such as '01' must remain distinct from '1'.
    """
    if len(a) != len(b):
        return f"row count differs: left={len(a)} right={len(b)}"
    left = a if ordered else sorted(a, key=lambda row: _row_sort_key(row, numeric_columns))
    right = b if ordered else sorted(b, key=lambda row: _row_sort_key(row, numeric_columns))
    for index, (lrow, rrow) in enumerate(zip(left, right, strict=True)):
        if len(lrow) != len(rrow):
            return f"row {index} width differs: left={lrow!r} right={rrow!r}"
        for column, (lvalue, rvalue) in enumerate(zip(lrow, rrow, strict=True)):
            lnumber = _number(lvalue, allow_text=column in numeric_columns)
            rnumber = _number(rvalue, allow_text=column in numeric_columns)
            if lnumber is not None and rnumber is not None:
                delta = abs(lnumber - rnumber)
                equal = delta <= Decimal("0.000001")
            else:
                equal = lvalue == rvalue
            if not equal:
                return (f"row {index} column {column}: left={lvalue!r} "
                        f"right={rvalue!r}")
    return None


def _row_sort_key(row: tuple, numeric_columns: Collection[int]) -> tuple:
    """Align numeric cells by value even when drivers render them differently."""
    return tuple((0, number) if (number := _number(cell, allow_text=index in numeric_columns))
                 is not None else (1, str(cell)) for index, cell in enumerate(row))


def _number(value: Any, *, allow_text: bool = False) -> Decimal | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float, Decimal)):
        return Decimal(str(value))
    if allow_text and isinstance(value, str) and re.fullmatch(
            r"[+-]?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?", value):
        return Decimal(value)
    return None


