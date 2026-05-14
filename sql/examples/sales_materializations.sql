DROP TABLE IF EXISTS MART.SALES_REVENUE_BY_REGION;

CREATE TABLE MART.SALES_REVENUE_BY_REGION AS
SELECT
  c.region AS customer_region,
  SUM(ol.quantity * ol.net_unit_price) AS total_revenue
FROM MART.ORDER_LINES ol
LEFT JOIN MART.ORDERS o
  ON ol.order_id = o.order_id
LEFT JOIN MART.CUSTOMERS c
  ON o.customer_id = c.customer_id
GROUP BY c.region;

EXECUTE SCRIPT SEMANTIC_ADMIN.REGISTER_MATERIALIZATION(
  'sales',
  'sales_revenue_by_region',
  'MART',
  'SALES_REVENUE_BY_REGION',
  'AGGREGATE',
  'MANUAL'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_MATERIALIZATION_COLUMN(
  'sales',
  'sales_revenue_by_region',
  'DIMENSION',
  'customer_region',
  'CUSTOMER_REGION',
  'DIRECT'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_MATERIALIZATION_COLUMN(
  'sales',
  'sales_revenue_by_region',
  'METRIC',
  'total_revenue',
  'TOTAL_REVENUE',
  'SUM'
);
