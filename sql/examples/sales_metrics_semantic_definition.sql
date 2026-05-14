-- SQL-native metric authoring example.
--
-- This file is intentionally not part of the legacy smoke seed yet. It is the
-- target Semantic SQL surface implemented by the definition runtime and
-- preprocessor.

EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();

ALTER SEMANTIC VIEW sales.SALES
REPLACE FACTS (
  FACT net_revenue
    ON ENTITY order_line
    AS ol.quantity * ol.net_unit_price
    RETURNS DECIMAL(18,2)
    ADDITIVE
    DISPLAY 'Net Revenue'
    COMMENT 'Net recognized revenue excluding tax'
    PUBLIC CERTIFIED,

  FACT net_cost
    ON ENTITY order_line
    AS ol.quantity * ol.unit_cost
    RETURNS DECIMAL(18,2)
    ADDITIVE
    DISPLAY 'Net Cost'
    COMMENT 'Cost recognized for sold units'
    PUBLIC CERTIFIED,

  FACT quantity
    ON ENTITY order_line
    AS ol.quantity
    RETURNS DECIMAL(18,0)
    ADDITIVE
    DISPLAY 'Quantity'
    COMMENT 'Number of units on the order line'
    PUBLIC CERTIFIED
)
REPLACE METRICS (
  METRIC total_revenue
    AS SUM(net_revenue)
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FORMAT 'currency'
    DISPLAY 'Total Revenue'
    COMMENT 'Net recognized revenue excluding tax'
    SYNONYMS ('revenue', 'sales')
    ADDITIVE PUBLIC CERTIFIED,

  METRIC total_cost
    AS SUM(net_cost)
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FORMAT 'currency'
    DISPLAY 'Total Cost'
    COMMENT 'Cost recognized for sold units'
    ADDITIVE PUBLIC CERTIFIED,

  METRIC gross_margin
    AS total_revenue - total_cost
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FORMAT 'currency'
    DISPLAY 'Gross Margin'
    COMMENT 'Total revenue minus total cost'
    DERIVED PUBLIC CERTIFIED,

  METRIC gross_margin_pct
    AS gross_margin / NULLIF(total_revenue, 0)
    ON ENTITY order_line
    RETURNS DECIMAL(18,6)
    FORMAT 'percentage'
    DISPLAY 'Gross Margin %'
    COMMENT 'Gross margin as a percentage of revenue'
    RATIO PUBLIC CERTIFIED,

  METRIC completed_revenue
    AS SUM(net_revenue)
    FILTER (WHERE order_status = 'COMPLETE')
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FORMAT 'currency'
    DISPLAY 'Completed Revenue'
    COMMENT 'Net revenue for completed orders only'
    ADDITIVE PUBLIC CERTIFIED
);

SHOW SEMANTIC METRICS IN sales.SALES;
DESCRIBE SEMANTIC METRIC sales.SALES.total_revenue;
SHOW SEMANTIC DIMENSIONS FOR METRIC sales.SALES.total_revenue;
