/*
Portfolio SQL sample
Project: Fleet Cost Balance Analytics
File: benchmark_rates_by_lane_month_sanitized.sql

Explanation:
- This query represents one of multiple analytical transformation layers used in the original reporting solution.
- The final dashboard model was built using multiple benchmark, tendering, carrier performance, and financial calculation datasets.

Purpose:
Calculates average historical transportation rates for comparable freight orders by lane, shipping month, and number of unloading stops.
The output provides spot and non-spot benchmark rates used as alternative cost references in the Cost Balance calculation.

Notes:
- Source table names, organization IDs, carrier IDs, server names, and internal system fields were anonymized.
- The structure keeps the original analytical logic: tendering type classification, currency normalization, grouped benchmark rates, and FULL OUTER JOIN between spot and non-spot averages.
- This is a portfolio-safe version and is not intended to run against the original production environment.

Parameterization notes:

- The original enterprise reporting solution used dynamic parameters for years, market organizations, and excluded document types.
- In this portfolio version, simplified placeholder values are intentionally used to improve readability and demonstrate the underlying business logic more clearly.
*/

WITH tendering_changes AS (
    SELECT
        o.order_id,
        cl.change_description,
        cl.change_date,
        cl.change_time,
        ROW_NUMBER() OVER (
            PARTITION BY o.order_id
            ORDER BY
                cl.change_date DESC,
                cl.change_time DESC
        ) AS row_number_desc
    FROM source_schema.transport_orders AS o
    LEFT JOIN source_schema.transport_order_change_log AS cl
        ON o.order_node_key = cl.parent_key
    WHERE o.market_org IN ('MARKET_01', 'MARKET_02', 'MARKET_03')
        AND o.document_category IN ('TRANSPORT_ORDER', 'BOOKING_ORDER')
        AND EXTRACT(YEAR FROM o.created_timestamp) IN (2023, 2024, 2025, 2026)
        AND o.order_id IS NOT NULL
        AND o.lifecycle_status <> 'CANCELLED'
        AND o.document_type NOT IN ('EXCLUDED_TYPE')
        AND cl.change_description LIKE '%TENDERING TYPE : %'
),

latest_spot_tendering_orders AS (
    SELECT
        order_id
    FROM tendering_changes
    WHERE row_number_desc = 1
        AND (
            change_description LIKE '%TENDERING TYPE : SPOT_BID%'
            OR change_description LIKE '%TENDERING TYPE : SPOT_FORWARD%'
        )
),

latest_non_spot_tendering_orders AS (
    SELECT
        order_id
    FROM tendering_changes
    WHERE row_number_desc = 1
        AND (
            change_description LIKE '%TENDERING TYPE : CONTRACT_PRIMARY%'
            OR change_description LIKE '%TENDERING TYPE : CONTRACT_BACKUP%'
        )
),

base_freight_orders AS (
    SELECT DISTINCT
        o.order_id AS freight_order_number,
        o.ship_date,
        TO_CHAR(o.ship_date, 'YYYY-MM') AS ship_month,
        o.source_location_id,
        o.source_location_name,
        o.destination_location_id,
        o.destination_location_name,
        o.unloading_stop_count,
        o.total_distance_km,
        s.created_timestamp AS spend_created_timestamp,
        s.transportation_mode,
        s.delivery_mode,
        s.transport_mode_detail,
        s.document_currency,
        s.carrier_id,
        s.charge_amount * 10000 AS charged_amount_local,

        CASE
            WHEN s.document_currency = 'EUR' THEN s.charge_amount * 10000
            WHEN s.document_currency = 'PLN' THEN s.charge_amount * 10000 * 0.22
            WHEN s.document_currency = 'CHF' THEN s.charge_amount * 10000 * 0.95
            WHEN s.document_currency = 'GBP' THEN s.charge_amount * 10000 * 1.15
            ELSE NULL
        END AS target_amount_eur
    FROM source_schema.transport_orders AS o
    LEFT JOIN source_schema.freight_order_charges AS s
        ON o.order_id = s.freight_order_number
    WHERE o.market_org IN ('MARKET_01', 'MARKET_02', 'MARKET_03')
        AND o.document_category IN ('TRANSPORT_ORDER', 'BOOKING_ORDER')
        AND EXTRACT(YEAR FROM o.created_timestamp) IN (2023, 2024, 2025, 2026)
        AND o.ship_date < CURRENT_DATE
        AND o.order_id IS NOT NULL
        AND o.lifecycle_status <> 'CANCELLED'
        AND o.document_type NOT IN ('EXCLUDED_TYPE')
        AND o.transport_mode NOT LIKE 'DF_%'
        AND o.transport_mode NOT LIKE 'DEDICATED_%'
        AND o.carrier_code NOT LIKE 'INTERNAL_%'
        AND s.delivery_mode = 'FTL'
),

spot_rates AS (
    SELECT
        b.source_location_id,
        b.source_location_name,
        b.destination_location_id,
        b.destination_location_name,
        b.ship_month,
        b.unloading_stop_count,
        AVG(b.target_amount_eur) AS avg_spot_rate_cost,
        COUNT(DISTINCT b.freight_order_number) AS spot_order_count,
        LISTAGG(DISTINCT b.freight_order_number, ', ')
            WITHIN GROUP (ORDER BY b.freight_order_number) AS spot_order_list
    FROM base_freight_orders AS b
    INNER JOIN latest_spot_tendering_orders AS s
        ON b.freight_order_number = s.order_id
    GROUP BY
        b.source_location_id,
        b.source_location_name,
        b.destination_location_id,
        b.destination_location_name,
        b.ship_month,
        b.unloading_stop_count
),

non_spot_rates AS (
    SELECT
        b.source_location_id,
        b.source_location_name,
        b.destination_location_id,
        b.destination_location_name,
        b.ship_month,
        b.unloading_stop_count,
        AVG(b.target_amount_eur) AS avg_non_spot_rate_cost,
        COUNT(DISTINCT b.freight_order_number) AS non_spot_order_count,
        LISTAGG(DISTINCT b.freight_order_number, ', ')
            WITHIN GROUP (ORDER BY b.freight_order_number) AS non_spot_order_list
    FROM base_freight_orders AS b
    INNER JOIN latest_non_spot_tendering_orders AS n
        ON b.freight_order_number = n.order_id
    GROUP BY
        b.source_location_id,
        b.source_location_name,
        b.destination_location_id,
        b.destination_location_name,
        b.ship_month,
        b.unloading_stop_count
)

SELECT
    COALESCE(s.source_location_id, n.source_location_id) AS source_location_id,
    COALESCE(s.source_location_name, n.source_location_name) AS source_location_name,
    COALESCE(s.destination_location_id, n.destination_location_id) AS destination_location_id,
    COALESCE(s.destination_location_name, n.destination_location_name) AS destination_location_name,
    COALESCE(s.ship_month, n.ship_month) AS ship_month,
    COALESCE(s.unloading_stop_count, n.unloading_stop_count) AS unloading_stop_count,

    s.avg_spot_rate_cost,
    s.spot_order_count,
    s.spot_order_list,

    n.avg_non_spot_rate_cost,
    n.non_spot_order_count,
    n.non_spot_order_list,

    CONCAT(
        COALESCE(s.source_location_id, n.source_location_id),
        '|',
        COALESCE(s.destination_location_id, n.destination_location_id),
        '|',
        COALESCE(s.ship_month, n.ship_month),
        '|',
        COALESCE(s.unloading_stop_count, n.unloading_stop_count)
    ) AS lane_month_stops_key
FROM spot_rates AS s
FULL OUTER JOIN non_spot_rates AS n
    ON s.source_location_id = n.source_location_id
    AND s.source_location_name = n.source_location_name
    AND s.destination_location_id = n.destination_location_id
    AND s.destination_location_name = n.destination_location_name
    AND s.ship_month = n.ship_month
    AND s.unloading_stop_count = n.unloading_stop_count
WHERE COALESCE(s.avg_spot_rate_cost, 0) <> 0
    OR COALESCE(n.avg_non_spot_rate_cost, 0) <> 0
ORDER BY
    source_location_id,
    destination_location_id,
    ship_month;
