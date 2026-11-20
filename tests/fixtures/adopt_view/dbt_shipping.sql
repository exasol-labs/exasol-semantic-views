/* {"app": "dbt", "dbt_version": "1.12.6", "profile_name": "exasol_starter_kit", "target_name": "dev", "node_id": "model.adopt_fixtures.shipping"} */

CREATE OR REPLACE VIEW DBT_adopt_fixtures.shipping
        
(
  
            "SHIP_MODE" COMMENT IS 'How the order shipped',
            "ORDER_STATUS" COMMENT IS '',
            "FREIGHT" COMMENT IS 'Total freight, in EUR',
            "ORDER_COUNT" COMMENT IS 'Distinct orders'
)
AS 
(
    -- shipping metrics, one row per mode and status
    select
        o.ship_mode,
        o.order_status,
        sum(o.freight_amount)        as freight,
        count(distinct o.order_id)   as order_count
    from DBT_adopt_fixtures.orders o
    group by o.ship_mode, o.order_status
)
COMMENT IS 'Freight by ship mode and status. It''s documented.'