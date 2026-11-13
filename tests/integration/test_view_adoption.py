"""An aggregate view over one table is adopted as a semantic view.

ADOPT_VIEW reads what Exasol stores for the view -- its text, its columns'
names, types and comments, its comment, and its table's columns and comment --
and expands into CREATE_MODEL, ADD_ENTITY, ADD_SEMANTIC_OBJECT and Semantic DDL.
The semantic view must answer exactly what the view answers at the view's own
grain, and what plain SQL answers at any coarser one, including for COUNT
(DISTINCT), AVG and ratios, which do not add up from the finer rows. Running
it again follows the view, and a refusal leaves nothing behind.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "view_adoption"
OTHER_MODEL = "view_adoption_new"
SRC = "VIEWADOPT_SRC"

# Column comments in the column list and the view comment after the query:
# the DDL dbt writes for a view model with persist_docs.
SHIPPING = f"""
CREATE OR REPLACE VIEW {SRC}.SHIPPING (
    SHIP_MODE COMMENT IS 'How the order shipped',
    ORDER_STATUS COMMENT IS '',
    FREIGHT COMMENT IS 'Total freight, in EUR',
    ORDER_COUNT COMMENT IS 'Distinct orders',
    AVG_FREIGHT,
    FREIGHT_PER_ORDER,
    LINE_COUNT
) AS (
    SELECT
        l.ship_mode,
        l.order_status,
        SUM(l.freight_amount)                                           AS freight,
        COUNT(DISTINCT l.order_id)                                      AS order_count,
        AVG(l.freight_amount)                                           AS avg_freight,
        SUM(l.freight_amount) / NULLIF(COUNT(DISTINCT l.order_id), 0)   AS freight_per_order,
        COUNT(*)                                                        AS line_count
    FROM {SRC}.ORDER_LINES l
    GROUP BY l.ship_mode, l.order_status
) COMMENT IS 'Freight by ship mode and status'
"""

# A dbt model as most are written: no alias, bare columns, GROUP BY position.
EXTREMES = f"""
CREATE OR REPLACE VIEW {SRC}.EXTREMES AS
SELECT ship_mode, MAX(freight_amount) AS max_freight, MIN(freight_amount) AS min_freight
FROM {SRC}.order_lines
GROUP BY 1
"""

METRIC_TABLES = ("METRICS", "FACTS", "DIMENSIONS", "ENTITIES", "SEMANTIC_OBJECTS")


def teardown(con: Any) -> None:
    for model in (MODEL, OTHER_MODEL):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL_IF_EXISTS('{model}')")
    con.execute(f"DROP SCHEMA IF EXISTS {SRC} CASCADE")
    con.commit()


def adopt(con: Any, view: str, model: str = MODEL) -> dict[str, Any]:
    row = support.named_row(con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.ADOPT_VIEW('{model}', '{SRC}', '{view}')"))
    con.commit()
    assert row is not None
    return row


def refusal(con: Any, view: str, model: str = MODEL) -> str:
    with pytest.raises(Exception) as refused:
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.ADOPT_VIEW('{model}', '{SRC}', '{view}')")
    con.rollback()
    return str(refused.value)


def rows(con: Any, sql: str) -> list[tuple[Any, ...]]:
    def value(cell: Any) -> Any:
        return round(float(cell), 6) if isinstance(cell, (int, float)) or (
            isinstance(cell, str) and cell.replace(".", "", 1).lstrip("-").isdigit()) else cell
    return sorted(tuple(value(cell) for cell in row) for row in con.execute(sql).fetchall())


def answer(con: Any, view: str, dimensions: list[str], metrics: list[str],
           model: str = MODEL) -> list[tuple[Any, ...]]:
    con.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")
    compiled = support.compile_request(con, {"model": model, "object": view,
                                             "dimensions": dimensions, "metrics": metrics})
    assert compiled["status"] == "OK", compiled["error_message"]
    return rows(con, compiled["generated_sql"])


def catalog(con: Any, model: str = MODEL) -> dict[str, list[tuple[Any, ...]]]:
    """Every row the model has in the tables an adoption writes, by name and status."""
    state = {}
    for table in METRIC_TABLES:
        name = {"METRICS": "METRIC_NAME", "FACTS": "FACT_NAME",
                "DIMENSIONS": "DIMENSION_NAME", "ENTITIES": "ENTITY_NAME",
                "SEMANTIC_OBJECTS": "OBJECT_NAME"}[table]
        state[table] = con.execute(
            f"SELECT t.{name}, t.STATUS FROM SYS_SEMANTIC.{table} t"
            " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = t.MODEL_ID"
            f" WHERE m.MODEL_NAME = '{model}' ORDER BY 1").fetchall()
    state["OBJECT_COLUMNS"] = con.execute(
        "SELECT so.OBJECT_NAME, oc.COLUMN_NAME FROM SYS_SEMANTIC.OBJECT_COLUMNS oc"
        " JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so ON so.OBJECT_ID = oc.OBJECT_ID"
        " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = so.MODEL_ID"
        f" WHERE m.MODEL_NAME = '{model}' ORDER BY 1, 2").fetchall()
    return state


def status(con: Any, table: str, name: str) -> str | None:
    column = {"METRICS": "METRIC_NAME", "FACTS": "FACT_NAME"}[table]
    row = con.execute(
        f"SELECT t.STATUS FROM SYS_SEMANTIC.{table} t"
        " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = t.MODEL_ID"
        f" WHERE m.MODEL_NAME = '{MODEL}' AND t.{column} = '{name}'").fetchone()
    return None if row is None else str(row[0])


@pytest.fixture
def source(con: Any) -> Iterator[Any]:
    teardown(con)
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDER_LINES (ORDER_ID DECIMAL(18,0),"
                " SHIP_MODE VARCHAR(20), ORDER_STATUS VARCHAR(20) COMMENT IS 'Where the order is',"
                " FREIGHT_AMOUNT DECIMAL(18,2)) COMMENT IS 'One row per order line'")
    # Orders 1 and 3 have two lines each, and order 1's are in two statuses: so
    # at ship_mode, COUNT(DISTINCT) is not the sum of the view's rows, and the
    # per-order ratio is not what the lines add up to.
    con.execute(f"INSERT INTO {SRC}.ORDER_LINES VALUES"
                " (1, 'AIR', 'OPEN', 10), (1, 'AIR', 'SHIPPED', 5), (2, 'AIR', 'SHIPPED', 20),"
                " (3, 'SEA', 'OPEN', 4), (3, 'SEA', 'OPEN', 6), (4, 'SEA', 'SHIPPED', 30),"
                " (5, 'AIR', 'SHIPPED', 1)")
    con.execute(SHIPPING)
    con.execute(EXTREMES)
    con.commit()
    try:
        yield con
    finally:
        teardown(con)


@pytest.fixture
def adopted(source: Any) -> Any:
    adopt(source, "SHIPPING")
    return source


# ---- adopting -----------------------------------------------------------

def test_adopting_creates_the_model_and_publishes_it(source: Any) -> None:
    result = adopt(source, "SHIPPING")
    assert (result["model_name"], result["object_name"], result["dimensions"],
            result["metrics"], result["status"]) == (MODEL, "SHIPPING", 2, 5, "OK")
    model = source.execute("SELECT PUBLISHED_SCHEMA, STATUS FROM SYS_SEMANTIC.MODELS"
                           f" WHERE MODEL_NAME = '{MODEL}'").fetchone()
    assert tuple(model) == (f"SEMANTIC_{MODEL.upper()}", "PUBLISHED")
    published = source.execute("SELECT COUNT(*) FROM SYS.EXA_ALL_VIEWS"
                               f" WHERE VIEW_SCHEMA = '{model[0]}' AND VIEW_NAME = 'SHIPPING'")
    assert published.fetchone()[0] == 1
    assert not support.blocking_issues(support.validate_model(source, MODEL))


def test_the_result_carries_the_statements_it_ran(source: Any) -> None:
    ddl = adopt(source, "SHIPPING")["ddl"]
    for statement in ("SEMANTIC_ADMIN.CREATE_MODEL('view_adoption'",
                      "SEMANTIC_ADMIN.ADD_ENTITY('view_adoption', 'order_lines'",
                      "SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('view_adoption', 'SHIPPING'",
                      "ALTER SEMANTIC VIEW view_adoption.SHIPPING",
                      "SEMANTIC_ADMIN.PUBLISH_MODEL('view_adoption')"):
        assert statement in ddl


def test_descriptions_come_from_comments(adopted: Any) -> None:
    def description(table: str, column: str, name: str) -> Any:
        return adopted.execute(
            f"SELECT t.DESCRIPTION FROM SYS_SEMANTIC.{table} t"
            " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = t.MODEL_ID"
            f" WHERE m.MODEL_NAME = '{MODEL}' AND t.{column} = '{name}'").fetchone()[0]
    assert description("SEMANTIC_OBJECTS", "OBJECT_NAME", "SHIPPING") \
        == "Freight by ship mode and status"
    assert description("ENTITIES", "ENTITY_NAME", "order_lines") == "One row per order line"
    assert description("DIMENSIONS", "DIMENSION_NAME", "ship_mode") == "How the order shipped"
    # COMMENT IS '' is no comment: the table column's comment is used instead.
    assert description("DIMENSIONS", "DIMENSION_NAME", "order_status") == "Where the order is"
    assert description("METRICS", "METRIC_NAME", "freight") == "Total freight, in EUR"


def test_an_unqualified_dbt_style_view_is_qualified(source: Any) -> None:
    result = adopt(source, "EXTREMES")
    assert (result["dimensions"], result["metrics"]) == (1, 2)
    expression = source.execute(
        "SELECT f.EXPRESSION FROM SYS_SEMANTIC.FACTS f"
        " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = f.MODEL_ID"
        f" WHERE m.MODEL_NAME = '{MODEL}' AND f.FACT_NAME = 'extremes__max_freight_1'"
    ).fetchone()[0]
    assert expression == "order_lines.freight_amount"


# ---- the numbers ----------------------------------------------------------

SHIPPING_METRICS = ["freight", "order_count", "avg_freight", "freight_per_order", "line_count"]


def test_the_views_own_grain_answers_what_the_view_does(adopted: Any) -> None:
    assert answer(adopted, "SHIPPING", ["ship_mode", "order_status"], SHIPPING_METRICS) \
        == rows(adopted, f"SELECT * FROM {SRC}.SHIPPING")


@pytest.mark.parametrize("dimensions, group_by", [(["ship_mode"], "GROUP BY ship_mode"),
                                                  ([], "")])
def test_a_coarser_grain_answers_what_plain_sql_does(adopted: Any, dimensions: list[str],
                                                     group_by: str) -> None:
    select = ", ".join(dimensions + [
        "SUM(freight_amount)", "COUNT(DISTINCT order_id)", "AVG(freight_amount)",
        "SUM(freight_amount) / NULLIF(COUNT(DISTINCT order_id), 0)", "COUNT(*)"])
    expected = rows(adopted, f"SELECT {select} FROM {SRC}.ORDER_LINES {group_by}")
    assert answer(adopted, "SHIPPING", dimensions, SHIPPING_METRICS) == expected


def test_the_data_makes_regrouping_matter(adopted: Any) -> None:
    """Re-adding the view's rows would get the distinct count wrong."""
    naive = rows(adopted, f"SELECT ship_mode, SUM(order_count) FROM {SRC}.SHIPPING"
                          " GROUP BY ship_mode")
    right = rows(adopted, f"SELECT ship_mode, COUNT(DISTINCT order_id) FROM {SRC}.ORDER_LINES"
                          " GROUP BY ship_mode")
    assert naive != right


def test_min_and_max_regroup_from_an_unqualified_view(source: Any) -> None:
    adopt(source, "EXTREMES")
    assert answer(source, "EXTREMES", ["ship_mode"], ["max_freight", "min_freight"]) \
        == rows(source, f"SELECT * FROM {SRC}.EXTREMES")
    assert answer(source, "EXTREMES", [], ["max_freight", "min_freight"]) \
        == rows(source, f"SELECT MAX(freight_amount), MIN(freight_amount) FROM {SRC}.ORDER_LINES")


# ---- following the view ------------------------------------------------------

def test_adopting_again_changes_nothing(adopted: Any) -> None:
    before = catalog(adopted)
    again = adopt(adopted, "SHIPPING")
    assert again["status"] == "OK"
    assert catalog(adopted) == before


def test_a_column_removed_from_the_view_takes_its_metric_and_facts(adopted: Any) -> None:
    adopted.execute(f"CREATE OR REPLACE VIEW {SRC}.SHIPPING AS SELECT l.ship_mode,"
                    " l.order_status, SUM(l.freight_amount) AS freight"
                    f" FROM {SRC}.ORDER_LINES l GROUP BY l.ship_mode, l.order_status")
    adopted.commit()
    result = adopt(adopted, "SHIPPING")
    assert result["metrics"] == 1
    assert status(adopted, "METRICS", "order_count") == "INACTIVE"
    assert status(adopted, "FACTS", "shipping__order_count_1") == "INACTIVE"
    assert status(adopted, "FACTS", "shipping__freight_1") == "ACTIVE"
    assert not support.blocking_issues(support.validate_model(adopted, MODEL))
    # The name is free for another view of the model.
    adopted.execute(f"CREATE VIEW {SRC}.BY_STATUS AS SELECT order_status,"
                    f" COUNT(DISTINCT order_id) AS order_count FROM {SRC}.ORDER_LINES"
                    " GROUP BY order_status")
    adopted.commit()
    assert adopt(adopted, "BY_STATUS")["status"] == "OK"


def test_two_views_over_one_table_share_its_entity_and_dimensions(adopted: Any) -> None:
    adopt(adopted, "EXTREMES")
    state = catalog(adopted)
    assert state["ENTITIES"] == [("order_lines", "ACTIVE")]
    assert ("EXTREMES", "ship_mode") in state["OBJECT_COLUMNS"]
    assert ("SHIPPING", "ship_mode") in state["OBJECT_COLUMNS"]
    assert [row for row in state["DIMENSIONS"] if row[0] == "ship_mode"] \
        == [("ship_mode", "ACTIVE")]
    assert answer(adopted, "EXTREMES", ["ship_mode"], ["max_freight"]) \
        == rows(adopted, f"SELECT ship_mode, max_freight FROM {SRC}.EXTREMES")


# ---- refusals -----------------------------------------------------------------

def test_a_refusal_into_a_new_model_leaves_no_model(source: Any) -> None:
    source.execute(f"CREATE VIEW {SRC}.FILTERED AS SELECT ship_mode, SUM(freight_amount) AS f"
                   f" FROM {SRC}.ORDER_LINES WHERE order_status = 'OPEN' GROUP BY ship_mode")
    source.commit()
    assert "SEMANTIC_ADMIN_229" in refusal(source, "FILTERED", OTHER_MODEL)
    assert source.execute("SELECT COUNT(*) FROM SYS_SEMANTIC.MODELS"
                          f" WHERE MODEL_NAME = '{OTHER_MODEL}'").fetchone()[0] == 0


def test_a_refusal_late_in_the_adoption_leaves_the_model_as_it_was(adopted: Any) -> None:
    # Refused by the definition apply, after the semantic view was added: its
    # metric name is SHIPPING's.
    adopted.execute(f"CREATE VIEW {SRC}.CLASH AS SELECT order_status, SUM(freight_amount)"
                    f" AS freight FROM {SRC}.ORDER_LINES GROUP BY order_status")
    adopted.commit()
    before = catalog(adopted)
    assert "SEMANTIC_DDL_095" in refusal(adopted, "CLASH")
    assert catalog(adopted) == before
    assert not support.blocking_issues(support.validate_model(adopted, MODEL))
    assert answer(adopted, "SHIPPING", ["ship_mode"], ["freight"]) \
        == rows(adopted, f"SELECT ship_mode, SUM(freight_amount) FROM {SRC}.ORDER_LINES"
                         " GROUP BY ship_mode")


@pytest.mark.parametrize("view, ddl, code", [
    ("NOPE", None, "SEMANTIC_ADMIN_228"),
    ("JOINED", f"SELECT a.ship_mode, SUM(b.freight_amount) AS f FROM {SRC}.ORDER_LINES a"
               f" JOIN {SRC}.ORDER_LINES b ON a.order_id = b.order_id GROUP BY a.ship_mode",
     "SEMANTIC_ADMIN_229"),
    ("FINER", f"SELECT ship_mode, SUM(freight_amount) AS f FROM {SRC}.ORDER_LINES"
              " GROUP BY ship_mode, order_status", "SEMANTIC_ADMIN_229"),
    ("SPACED", f'SELECT ship_mode AS "Ship Mode", SUM(freight_amount) AS f'
               f" FROM {SRC}.ORDER_LINES GROUP BY ship_mode", "SEMANTIC_ADMIN_232"),
])
def test_a_view_it_cannot_adopt_is_refused_by_code(adopted: Any, view: str, ddl: str | None,
                                                   code: str) -> None:
    if ddl is not None:
        adopted.execute(f"CREATE VIEW {SRC}.{view} AS {ddl}")
        adopted.commit()
    before = catalog(adopted)
    assert code in refusal(adopted, view)
    assert catalog(adopted) == before


def test_a_view_whose_table_changed_is_refused(adopted: Any) -> None:
    adopted.execute(f"CREATE TABLE {SRC}.ORDER_LINES_V2 AS SELECT * FROM {SRC}.ORDER_LINES")
    adopted.execute(SHIPPING.replace(f"{SRC}.ORDER_LINES l", f"{SRC}.ORDER_LINES_V2 l"))
    adopted.commit()
    before = catalog(adopted)
    message = refusal(adopted, "SHIPPING")
    assert "SEMANTIC_ADMIN_230" in message
    assert "REMOVE_SEMANTIC_OBJECT('view_adoption', 'SHIPPING')" in message
    assert catalog(adopted) == before


def test_an_entity_named_for_another_table_is_refused(source: Any) -> None:
    source.execute(f"CREATE TABLE {SRC}.OTHER (ORDER_ID DECIMAL(18,0))")
    source.commit()
    m = f"'{OTHER_MODEL}'"
    for statement in (f"CREATE_MODEL({m}, 'SEMANTIC_{OTHER_MODEL.upper()}', NULL, NULL)",
                      f"ADD_ENTITY({m}, 'order_lines', '{SRC}', 'OTHER', 'x', NULL, NULL,"
                      " NULL)"):
        source.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    source.commit()
    assert "SEMANTIC_ADMIN_231" in refusal(source, "SHIPPING", OTHER_MODEL)
