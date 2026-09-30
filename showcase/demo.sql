-- Databricks UCMV on Exasol — pure-SQL demo.
-- Paste this whole file into any SQL client (exapump, DbVisualizer, DBeaver) and
-- run it as ONE session: ENABLE_SEMANTIC_SQL() is session-scoped, so the queries
-- below must run in the same connection as the EXECUTE SCRIPT that enables it.
--
-- Prereq: the semantic layer + demo MART data are installed (showcase/run.sh
-- does this, or run sql/install/*.sql + sql/examples/sales_*.sql once).

-- 1) Import the Databricks Unity Catalog Metric View (UCMV) YAML, inline.
--    Translation runs in-database; this creates, validates, and publishes
--    SEMANTIC_SALES_DBX.SALES_DBX.
EXECUTE SCRIPT SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW('
# Databricks Unity Catalog Metric View (UCMV) written over this project''s demo
# MART tables, so it validates, compiles, and queries against real demo data.
# Imported with:
#   EXECUTE SCRIPT SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW(<yaml>, ''sales_dbx'', ''SEMANTIC_SALES_DBX'', TRUE);
version: 1.1
comment: |-
  Sales metric view imported from Databricks UCMV format.
  Order-line grain joined to orders, customers, and products.
source: mart.order_lines

joins:
  - name: orders
    source: mart.orders
    on: source.order_id = orders.order_id
    cardinality: many_to_one
    joins:
      - name: customers
        source: mart.customers
        on: orders.customer_id = customers.customer_id
        cardinality: many_to_one
  - name: products
    source: mart.products
    on: source.product_id = products.product_id
    cardinality: many_to_one

fields:
  - name: customer_region
    expr: customers.region
    display_name: Customer Region
    comment: Commercial region assigned to the customer
    synonyms: [region, territory]
  - name: order_month
    expr: DATE_TRUNC(''MONTH'', orders.order_date)
    display_name: Order Month
  - name: order_status
    expr: orders.order_status
    display_name: Order Status
  - name: product_category
    expr: products.category
    display_name: Product Category

measures:
  - name: total_revenue
    expr: SUM(net_unit_price * quantity)
    display_name: Total Revenue
    comment: Net recognized revenue excluding tax
    synonyms: [revenue, sales]
    format:
      type: currency
      currency_code: USD
  - name: total_cost
    expr: SUM(unit_cost * quantity)
    display_name: Total Cost
    format:
      type: currency
  - name: order_count
    expr: COUNT(DISTINCT order_id)
    display_name: Order Count
    format:
      type: number
  - name: line_count
    expr: COUNT(1)
    display_name: Line Count
  - name: completed_revenue
    expr: SUM(net_unit_price * quantity) FILTER (WHERE orders.order_status = ''COMPLETE'')
    display_name: Completed Revenue
    format:
      type: currency
  - name: avg_order_value
    expr: MEASURE(total_revenue) / MEASURE(order_count)
    display_name: Avg Order Value
    format:
      type: currency
', 'sales_dbx', 'SEMANTIC_SALES_DBX', TRUE);

-- 2) Turn on the Databricks query surface (MEASURE / agg / GROUP BY ALL).
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();

-- 3) Query it the Databricks way — these are the same idioms used on Databricks.

-- Revenue and order count by region (MEASURE + GROUP BY ALL):
SELECT customer_region,
       MEASURE(total_revenue)   AS total_revenue,
       MEASURE(order_count)     AS order_count,
       MEASURE(avg_order_value) AS aov
FROM SEMANTIC_SALES_DBX.SALES_DBX
GROUP BY ALL
HAVING MEASURE(total_revenue) > 0
ORDER BY total_revenue DESC;

-- Same shape using the agg() synonym for MEASURE():
SELECT product_category,
       agg(total_revenue) AS total_revenue,
       agg(line_count)    AS line_count
FROM SEMANTIC_SALES_DBX.SALES_DBX
GROUP BY ALL
ORDER BY total_revenue DESC;

-- A FILTER-ed measure carried straight over from the UCMV (completed_revenue):
SELECT customer_region,
       MEASURE(total_revenue)     AS total_revenue,
       MEASURE(completed_revenue) AS completed_revenue
FROM SEMANTIC_SALES_DBX.SALES_DBX
GROUP BY ALL
ORDER BY total_revenue DESC;
