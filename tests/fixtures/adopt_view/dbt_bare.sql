/* {"app": "dbt", "dbt_version": "1.12.6", "profile_name": "exasol_starter_kit", "target_name": "dev", "node_id": "model.adopt_fixtures.bare"} */

CREATE OR REPLACE VIEW DBT_adopt_fixtures.bare
AS 
(
    select ship_mode, sum(freight_amount) as freight, avg(freight_amount) as avg_freight
    from DBT_adopt_fixtures.orders
    group by 1
)