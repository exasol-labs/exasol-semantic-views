# Examples

The first example model is a sales semantic model.

Physical entities:

- `order_line`
- `order`
- `customer`
- `product`

Semantic fields:

- Dimensions: `customer_region`, `order_month`, `order_status`,
  `product_category`
- Facts: `net_revenue`, `net_cost`, `quantity`
- Metrics: `total_revenue`, `total_cost`, `gross_margin`,
  `gross_margin_pct`, `completed_revenue`

Runnable example files:

- `sql/examples/sales_physical_model.sql`
- `sql/examples/sales_model_seed.sql`
- `sql/examples/sales_semantic_queries.sql`

After installation, publish and query the example through the semantic layer:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales');
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();

SELECT customer_region, total_revenue
FROM SEMANTIC_SALES.SALES
GROUP BY customer_region
ORDER BY total_revenue DESC;
```

Agents should compile the same request through
`SEMANTIC_ADMIN.COMPILE_REQUEST_JSON` instead of writing physical joins.
