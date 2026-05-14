EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON(
  '{
    "model": "sales",
    "object": "SALES",
    "metrics": ["total_revenue"],
    "dimensions": ["customer_region"],
    "order_by": [{"field": "total_revenue", "direction": "desc"}],
    "limit": 2,
    "purpose": "sql_smoke"
  }'
);
