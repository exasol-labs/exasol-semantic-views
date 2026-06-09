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
- `sql/examples/sales_osi.yaml`
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

## OSI Import And Export

`sql/examples/sales_osi.yaml` is the generated Open Semantic Interchange
representation of the sales model. It is meant for documentation, fixture drift
checks, and simple interoperability import/export trials.

Validate the example offline:

```sh
python3 tools/osi.py validate sql/examples/sales_osi.yaml
```

Export the published sales object for a generic OSI consumer:

```sh
python3 tools/osi.py export \
  --model sales \
  --object SALES \
  --profile interoperability \
  --format yaml \
  --output /tmp/sales_osi.yaml \
  --warnings-output /tmp/sales_osi_warnings.json
```

Export the full model for Exasol-to-Exasol round trips:

```sh
python3 tools/osi.py export \
  --model sales \
  --profile lossless \
  --format json \
  --output /tmp/sales_osi_lossless.json \
  --warnings-output /tmp/sales_osi_lossless_warnings.json
```

Plan an import without connecting to Exasol:

```sh
python3 tools/osi.py import \
  --dry-run \
  --strict \
  --target-model sales_osi_import \
  --output /tmp/sales_osi_import_plan.json \
  sql/examples/sales_osi.yaml
```

Apply a simple interoperability import through the public admin helper surface:

```sh
python3 tools/osi.py import \
  --apply \
  --target-model sales_osi_import \
  --collision-policy replace_draft \
  --apply-mode script \
  --output /tmp/sales_osi_import_result.json \
  sql/examples/sales_osi.yaml
```

Use batch apply for lossless Exasol-to-Exasol imports:

```sh
python3 tools/osi.py import \
  --apply \
  --strict \
  --target-model sales_osi_roundtrip \
  --collision-policy replace_draft \
  --apply-mode batch \
  --output /tmp/sales_osi_roundtrip_result.json \
  /tmp/sales_osi_lossless.json
```

Run the live round-trip verifier against Nano when you need to confirm the full
lossless path:

```sh
python3 tools/verify_osi_roundtrip.py
```

YAML input and output require PyYAML. JSON validation and JSON import planning
work without optional YAML dependencies. See [OSI import and export
format](osi-format.md) for profile guidance, limitations, and upstream converter
plans.
