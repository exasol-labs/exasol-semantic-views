/* {"app": "dbt", "dbt_version": "1.12.6", "profile_name": "exasol_starter_kit", "target_name": "dev", "node_id": "model.adopt_fixtures.quoted"} */

CREATE OR REPLACE VIEW DBT_adopt_fixtures.quoted
AS 
(
    SELECT "SHIP_MODE" AS "Ship Mode", COUNT(*) AS n_orders,
           SUM(freight_amount) / NULLIF(COUNT(*), 0) AS freight_per_order
    FROM DBT_adopt_fixtures.orders AS ord
    GROUP BY "SHIP_MODE"
)