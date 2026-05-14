EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL(
  'sales',
  'SEMANTIC_SALES',
  'Certified semantic sales model',
  'FINANCE_ANALYTICS'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(
  'sales',
  'order_line',
  'MART',
  'ORDER_LINES',
  'ol',
  'CAST(ol.order_id AS VARCHAR(36)) || ''-'' || CAST(ol.line_id AS VARCHAR(36))',
  'One row per order line',
  'Order line grain'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(
  'sales',
  'order',
  'MART',
  'ORDERS',
  'o',
  'o.order_id',
  'One row per order',
  'Order header grain'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(
  'sales',
  'customer',
  'MART',
  'CUSTOMERS',
  'c',
  'c.customer_id',
  'One row per customer',
  'Customer dimension'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(
  'sales',
  'product',
  'MART',
  'PRODUCTS',
  'p',
  'p.product_id',
  'One row per product',
  'Product dimension'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT(
  'sales',
  'SALES',
  'order_line',
  'Sales metrics and dimensions'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(
  'sales',
  'order_line_to_order',
  'order_line',
  'order',
  'ol.order_id = o.order_id',
  'MANY_TO_ONE',
  'LEFT',
  NULL
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(
  'sales',
  'order_to_customer',
  'order',
  'customer',
  'o.customer_id = c.customer_id',
  'MANY_TO_ONE',
  'LEFT',
  NULL
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(
  'sales',
  'order_line_to_product',
  'order_line',
  'product',
  'ol.product_id = p.product_id',
  'MANY_TO_ONE',
  'LEFT',
  NULL
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  'sales',
  'SALES',
  'customer',
  'customer_region',
  'c.region',
  'VARCHAR(100)',
  'Customer Region',
  'Commercial region assigned to the customer',
  NULL,
  TRUE
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  'sales',
  'SALES',
  'order',
  'order_month',
  'DATE_TRUNC(''month'', o.order_date)',
  'DATE',
  'Order Month',
  'Calendar month of the order date',
  'month',
  TRUE
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  'sales',
  'SALES',
  'order',
  'order_status',
  'o.order_status',
  'VARCHAR(32)',
  'Order Status',
  'Lifecycle status of the order',
  NULL,
  TRUE
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  'sales',
  'SALES',
  'product',
  'product_category',
  'p.category',
  'VARCHAR(100)',
  'Product Category',
  'Commercial product category',
  NULL,
  TRUE
);

EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  'ALTER SEMANTIC VIEW sales.SALES
REPLACE FACTS (
  FACT net_revenue
    ON ENTITY order_line
    AS ol.quantity * ol.net_unit_price
    RETURNS DECIMAL(18,2)
    ADDITIVE
    DISPLAY ''Net Revenue''
    COMMENT ''Net recognized revenue excluding tax''
    PUBLIC CERTIFIED,

  FACT net_cost
    ON ENTITY order_line
    AS ol.quantity * ol.unit_cost
    RETURNS DECIMAL(18,2)
    ADDITIVE
    DISPLAY ''Net Cost''
    COMMENT ''Cost recognized for sold units''
    PUBLIC CERTIFIED,

  FACT quantity
    ON ENTITY order_line
    AS ol.quantity
    RETURNS DECIMAL(18,0)
    ADDITIVE
    DISPLAY ''Quantity''
    COMMENT ''Number of units on the order line''
    PUBLIC CERTIFIED
)
REPLACE METRICS (
  METRIC total_revenue
    AS SUM(net_revenue)
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FORMAT ''currency''
    DISPLAY ''Total Revenue''
    COMMENT ''Net recognized revenue excluding tax''
    SYNONYMS (''revenue'', ''sales'')
    ADDITIVE PUBLIC CERTIFIED,

  METRIC total_cost
    AS SUM(net_cost)
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FORMAT ''currency''
    DISPLAY ''Total Cost''
    COMMENT ''Cost recognized for sold units''
    ADDITIVE PUBLIC CERTIFIED,

  METRIC gross_margin
    AS total_revenue - total_cost
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FORMAT ''currency''
    DISPLAY ''Gross Margin''
    COMMENT ''Total revenue minus total cost''
    DERIVED PUBLIC CERTIFIED,

  METRIC gross_margin_pct
    AS gross_margin / NULLIF(total_revenue, 0)
    ON ENTITY order_line
    RETURNS DECIMAL(18,6)
    FORMAT ''percentage''
    DISPLAY ''Gross Margin %''
    COMMENT ''Gross margin as a percentage of revenue''
    RATIO PUBLIC CERTIFIED,

  METRIC completed_revenue
    AS SUM(net_revenue)
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FILTER (WHERE order_status = ''COMPLETE'')
    FORMAT ''currency''
    DISPLAY ''Completed Revenue''
    COMMENT ''Net revenue for completed orders only''
    ADDITIVE PUBLIC CERTIFIED
)',
  FALSE
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM(
  'sales',
  'DIMENSION',
  'customer_region',
  'region',
  'MANUAL'
);
