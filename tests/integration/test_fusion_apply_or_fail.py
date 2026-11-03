"""A refused fusion document fails the statement when the caller asks it to.

APPLY_FUSION_DECLARATION reports a refusal as STATUS = 'ERROR' in its result
row. An orchestrator such as dbt counts a statement that returned rows as one
that succeeded, so a refused document left the run green over a model that was
never fused -- and the fusion tier has no other authoring surface.
APPLY_FUSION_DECLARATION_OR_FAIL raises instead, as
APPLY_SEMANTIC_DEFINITION_OR_FAIL already did for the DDL.

Applied to a model that does not exist, the document used to be blamed:
SEMANTIC_FUSION_012 "document.entities is required" for a typo in MODEL_NAME.
"""

from __future__ import annotations

from typing import Any

import pytest

import verify_support as support


def exported(con: Any) -> str:
    row = support.named_row(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_FUSION_DECLARATION('sales', NULL)"))
    assert row is not None
    document = next(value for value in row.values()
                    if isinstance(value, str) and value.startswith("{"))
    return str(document)


def test_a_missing_model_is_named_before_the_document(con: Any) -> None:
    row = support.named_row(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_FUSION_DECLARATION('nosuchmodel', '{}', FALSE)"))
    assert row is not None
    assert (row["status"], row["error_code"]) == ("ERROR", "SEMANTIC_FUSION_001"), row


@pytest.mark.parametrize("model, document, code", [
    ("nosuchmodel", "{}", "SEMANTIC_FUSION_001"),
    ("sales", "not json", "SEMANTIC_FUSION_010"),
    ("sales", '{"entities": {"no_such_entity": {}}}', "SEMANTIC_FUSION_018"),
])
def test_or_fail_raises_the_refusal(con: Any, model: str, document: str, code: str) -> None:
    with pytest.raises(Exception, match=code):
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_FUSION_DECLARATION_OR_FAIL("
                    f"'{model}', {support.sql_string(document)}, FALSE)")


def test_or_fail_returns_the_row_when_the_document_applies(con: Any) -> None:
    row = support.named_row(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_FUSION_DECLARATION_OR_FAIL("
        f"'sales', {support.sql_string(exported(con))}, TRUE)"))
    assert row is not None and row["status"] in ("DRY_RUN", "OK"), row
