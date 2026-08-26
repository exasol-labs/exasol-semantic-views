-- SQL-native authoring example for a semantic object's interior.
--
-- One statement per concept set. Each REPLACE block decides the object's
-- membership for that kind, and the blocks compose: a single statement may carry
-- dimensions, facts and metrics together, validated once and rolled back as one.
--
-- This covers everything inside a semantic object. The object itself, its
-- entities, relationships, keys and the fusion layer are graph operations with
-- ordering constraints an ALTER on one object cannot express -- those are the
-- SEMANTIC_ADMIN scripts (see sql/examples/sales_model_seed.sql).
--
-- This file is intentionally not part of the legacy smoke seed yet.

EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();

-- Dimensions: what the object can be grouped by. Same clauses as a fact, plus
-- FORMAT; PRIVATE hides one from discovery (the catalog spells it IS_HIDDEN).
--
-- These four are the declarative equivalent of the four ADD_DIMENSION calls in
-- sales_model_seed.sql -- same expressions, types and format hints.
ALTER SEMANTIC VIEW sales.SALES
REPLACE DIMENSIONS (
  DIMENSION customer_region
    ON ENTITY customer
    AS c.region
    RETURNS VARCHAR(100)
    DISPLAY 'Customer Region'
    COMMENT 'Commercial region assigned to the customer'
    CERTIFIED,

  DIMENSION order_month
    ON ENTITY "order"
    AS DATE_TRUNC('month', o.order_date)
    RETURNS DATE
    DISPLAY 'Order Month'
    COMMENT 'Calendar month of the order date'
    FORMAT 'month'
    CERTIFIED,

  DIMENSION order_status
    ON ENTITY "order"
    AS o.order_status
    RETURNS VARCHAR(32)
    DISPLAY 'Order Status'
    COMMENT 'Lifecycle status of the order'
    CERTIFIED,

  DIMENSION product_category
    ON ENTITY product
    AS p.category
    RETURNS VARCHAR(100)
    DISPLAY 'Product Category'
    COMMENT 'Commercial product category'
    CERTIFIED
);

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
