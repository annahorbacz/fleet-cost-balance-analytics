/*
Portfolio SQL sample
Project: Fleet Cost Balance Analytics
File: earlier_assigned_cost_logic_sanitized.sql

Purpose:
Identifies the most realistic earlier non-dedicated-fleet carrier cost for orders that were eventually executed by the internal fleet.
This output can be used as one benchmark source in the Cost Balance calculation.

Notes:
- Source table names, organization IDs, carrier IDs, server names, and internal system fields were anonymized.
- The structure keeps the original analytical logic: CTEs, carrier timeline reconstruction, window functions, fallback cost logic.
- This is a portfolio-safe version and is not intended to run against the original production environment.
*/

WITH awarded_tender_events AS (
    SELECT
        o.order_id,
        bp.carrier_id,
        t.tender_sequence_number
    FROM source_schema.transport_orders AS o
    LEFT JOIN source_schema.tendering_process AS t
        ON o.order_key = t.order_key
    LEFT JOIN source_schema.tendering_steps AS ts
        ON t.tendering_key = ts.tendering_key
    LEFT JOIN source_schema.tendering_requests AS tr
        ON ts.step_key = tr.step_key
    RIGHT JOIN source_schema.tendering_responses AS resp
        ON tr.request_key = resp.request_key
    LEFT JOIN source_schema.carrier_master AS bp
        ON resp.carrier_key = bp.carrier_key
    WHERE o.market_org IN ('MARKET_01', 'MARKET_02', 'MARKET_03')
        AND o.document_category IN ('TRANSPORT_ORDER', 'BOOKING_ORDER')
        AND EXTRACT(YEAR FROM o.created_date) IN (2023, 2024, 2025, 2026)
        AND o.order_id IS NOT NULL
        AND o.lifecycle_status <> 'CANCELLED'
        AND o.document_type NOT IN ('EXCLUDED_TYPE')
        AND (
            o.transport_mode LIKE 'DF_%'
            OR o.transport_mode LIKE 'DEDICATED_%'
            OR o.carrier_code LIKE 'INTERNAL_%'
        )
        AND resp.award_status = 'AWARDED'
    GROUP BY
        o.order_id,
        bp.carrier_id,
        t.tender_sequence_number
),

last_external_tender AS (
    SELECT
        order_id,
        MAX(tender_sequence_number) AS last_external_sequence
    FROM awarded_tender_events
    WHERE carrier_id NOT IN (
        'DF_CARRIER_01',
        'DF_CARRIER_02',
        'DF_CARRIER_03',
        'DF_CARRIER_04',
        'DF_CARRIER_05'
    )
    GROUP BY order_id
),

first_internal_fleet_after_external AS (
    SELECT
        df.order_id,
        MIN(df.tender_sequence_number) AS first_internal_fleet_sequence,
        ext.last_external_sequence
    FROM awarded_tender_events AS df
    INNER JOIN last_external_tender AS ext
        ON df.order_id = ext.order_id
        AND df.tender_sequence_number > ext.last_external_sequence
    WHERE df.carrier_id IN (
        'DF_CARRIER_01',
        'DF_CARRIER_02',
        'DF_CARRIER_03',
        'DF_CARRIER_04',
        'DF_CARRIER_05'
    )
    GROUP BY
        df.order_id,
        ext.last_external_sequence
),

direct_internal_fleet_orders AS (
    SELECT DISTINCT
        o.order_id
    FROM source_schema.transport_orders AS o
    LEFT JOIN source_schema.tendering_requests AS tr
        ON o.order_key = tr.order_key
    WHERE o.market_org IN ('MARKET_01', 'MARKET_02', 'MARKET_03')
        AND o.document_category IN ('TRANSPORT_ORDER', 'BOOKING_ORDER')
        AND EXTRACT(YEAR FROM o.created_date) IN (2023, 2024, 2025, 2026)
        AND o.order_id IS NOT NULL
        AND o.lifecycle_status <> 'CANCELLED'
        AND o.document_type NOT IN ('EXCLUDED_TYPE')
        AND tr.carrier_internal_id IN ('INTERNAL_FLEET_01', 'INTERNAL_FLEET_02')
),

excluded_orders AS (
    SELECT DISTINCT
        f.order_id
    FROM first_internal_fleet_after_external AS f
    WHERE f.first_internal_fleet_sequence - f.last_external_sequence >= 2
        AND NOT EXISTS (
            SELECT 1
            FROM direct_internal_fleet_orders AS d
            WHERE d.order_id = f.order_id
        )
),

change_log_base AS (
    SELECT
        o.order_id,
        h.change_date,
        h.change_time,
        p.field_name,
        p.old_value,
        p.new_value,
        p.old_currency,
        TO_TIMESTAMP(h.change_date || ' ' || h.change_time, 'YYYY-MM-DD HH24:MI:SS') AS change_timestamp
    FROM source_schema.transport_orders AS o
    INNER JOIN source_schema.change_header AS h
        ON o.order_key = h.object_id
    INNER JOIN source_schema.change_position AS p
        ON h.change_number = p.change_number
    WHERE h.object_class = 'TRANSPORT_ORDER'
        AND o.market_org IN ('MARKET_01', 'MARKET_02', 'MARKET_03')
        AND o.document_category IN ('TRANSPORT_ORDER', 'BOOKING_ORDER')
        AND o.document_type NOT IN ('EXCLUDED_TYPE')
        AND EXTRACT(YEAR FROM o.created_date) IN (2023, 2024, 2025, 2026)
        AND (
            o.transport_mode LIKE 'DF_%'
            OR o.transport_mode LIKE 'DEDICATED_%'
            OR o.carrier_code LIKE 'INTERNAL_%'
        )
        AND o.lifecycle_status <> 'CANCELLED'
        AND p.field_name IN ('CARRIER_ID', 'NET_AMOUNT', 'RESOURCE_ID')
        AND p.old_value NOT LIKE '%-%'
        AND p.new_value NOT LIKE '%-%'
),

resource_based_internal_fleet_changes AS (
    SELECT
        order_id,
        change_timestamp AS resource_change_timestamp
    FROM change_log_base
    WHERE field_name = 'RESOURCE_ID'
        AND (
            LOWER(new_value) LIKE '%internal_fleet_pattern_01%'
            OR LOWER(new_value) LIKE '%internal_fleet_pattern_02%'
            OR LOWER(new_value) LIKE '%internal_fleet_pattern_03%'
        )
),

carrier_id_changes AS (
    SELECT
        order_id,
        change_timestamp,
        old_value,
        new_value
    FROM change_log_base
    WHERE field_name = 'CARRIER_ID'
),

carrier_change_boundaries AS (
    SELECT DISTINCT
        order_id,
        change_timestamp AS boundary_timestamp
    FROM carrier_id_changes

    UNION

    SELECT DISTINCT
        r.order_id,
        r.resource_change_timestamp AS boundary_timestamp
    FROM resource_based_internal_fleet_changes AS r
    WHERE NOT EXISTS (
        SELECT 1
        FROM carrier_id_changes AS c
        WHERE c.order_id = r.order_id
            AND c.change_timestamp BETWEEN DATEADD('second', -60, r.resource_change_timestamp)
                                      AND DATEADD('second',  60, r.resource_change_timestamp)
    )
),

carrier_windows AS (
    SELECT
        order_id,
        boundary_timestamp AS start_timestamp,
        LEAD(boundary_timestamp) OVER (
            PARTITION BY order_id
            ORDER BY boundary_timestamp
        ) AS end_timestamp
    FROM carrier_change_boundaries
),

carrier_timeline_raw AS (
    SELECT
        w.order_id,
        w.start_timestamp,
        w.end_timestamp,
        c.change_timestamp AS carrier_change_timestamp,
        c.old_value,
        c.new_value AS carrier_id
    FROM carrier_windows AS w
    LEFT JOIN carrier_id_changes AS c
        ON c.order_id = w.order_id
        AND c.change_timestamp <= w.start_timestamp
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY w.order_id, w.start_timestamp
        ORDER BY c.change_timestamp DESC NULLS LAST
    ) = 1
),

carrier_timeline AS (
    SELECT
        c.*,

        CASE
            WHEN c.carrier_id IS NULL OR c.carrier_id = ''
                THEN 1
            ELSE 0
        END AS is_blank_carrier,

        CASE
            WHEN c.carrier_id LIKE 'INTERNAL_%'
                OR c.carrier_id IN ('DF_CARRIER_01', 'DF_CARRIER_02', 'DF_CARRIER_03')
                THEN 1
            ELSE 0
        END AS is_internal_fleet_by_pattern,

        CASE
            WHEN c.carrier_id IN ('DF_CARRIER_04', 'DF_CARRIER_05')
                AND EXISTS (
                    SELECT 1
                    FROM resource_based_internal_fleet_changes AS r
                    WHERE r.order_id = c.order_id
                        AND r.resource_change_timestamp BETWEEN DATEADD('second', -300, c.start_timestamp)
                                                           AND DATEADD('second',  300, c.start_timestamp)
                )
                THEN 1
            ELSE 0
        END AS is_internal_fleet_by_resource,

        CASE
            WHEN c.carrier_id IS NULL OR c.carrier_id = ''
                THEN 0
            WHEN c.carrier_id LIKE 'INTERNAL_%'
                OR c.carrier_id IN ('DF_CARRIER_01', 'DF_CARRIER_02', 'DF_CARRIER_03')
                THEN 1
            WHEN c.carrier_id IN ('DF_CARRIER_04', 'DF_CARRIER_05')
                AND EXISTS (
                    SELECT 1
                    FROM resource_based_internal_fleet_changes AS r
                    WHERE r.order_id = c.order_id
                        AND r.resource_change_timestamp BETWEEN DATEADD('second', -300, c.start_timestamp)
                                                           AND DATEADD('second',  300, c.start_timestamp)
                )
                THEN 1
            ELSE 0
        END AS is_internal_fleet,

        CASE
            WHEN c.carrier_id IS NOT NULL
                AND c.carrier_id <> ''
                AND NOT (
                    c.carrier_id LIKE 'INTERNAL_%'
                    OR c.carrier_id IN (
                        'DF_CARRIER_01',
                        'DF_CARRIER_02',
                        'DF_CARRIER_03',
                        'DF_CARRIER_04',
                        'DF_CARRIER_05'
                    )
                )
                THEN 1
            ELSE 0
        END AS is_valid_external_carrier

    FROM carrier_timeline_raw AS c
),

last_carrier_status AS (
    SELECT *
    FROM (
        SELECT
            order_id,
            carrier_id,
            is_internal_fleet,
            is_valid_external_carrier,
            start_timestamp,
            ROW_NUMBER() OVER (
                PARTITION BY order_id
                ORDER BY start_timestamp DESC
            ) AS row_number_desc
        FROM carrier_timeline
        WHERE carrier_id IS NOT NULL
            AND carrier_id <> ''
    ) AS ranked
    WHERE row_number_desc = 1
),

earlier_external_carrier AS (
    SELECT *
    FROM (
        SELECT
            t.order_id,
            t.start_timestamp,
            t.end_timestamp,
            t.carrier_id,
            t.is_internal_fleet,
            ROW_NUMBER() OVER (
                PARTITION BY t.order_id
                ORDER BY t.start_timestamp DESC
            ) AS row_number_desc
        FROM carrier_timeline AS t
        WHERE t.is_valid_external_carrier = 1
    ) AS ranked
    WHERE row_number_desc = 1
),

net_amount_changes AS (
    SELECT
        order_id,
        change_timestamp,

        CASE old_currency
            WHEN 'PLN' THEN TRY_TO_DECIMAL(new_value, 38, 10) * 0.22 * 10000
            WHEN 'CHF' THEN TRY_TO_DECIMAL(new_value, 38, 10) * 0.95 * 10000
            WHEN 'GBP' THEN TRY_TO_DECIMAL(new_value, 38, 10) * 1.15 * 10000
            ELSE TRY_TO_DECIMAL(new_value, 38, 10) * 10000
        END AS amount_eur,

        CASE old_currency
            WHEN 'PLN' THEN TRY_TO_DECIMAL(old_value, 38, 10) * 0.22 * 10000
            WHEN 'CHF' THEN TRY_TO_DECIMAL(old_value, 38, 10) * 0.95 * 10000
            WHEN 'GBP' THEN TRY_TO_DECIMAL(old_value, 38, 10) * 1.15 * 10000
            ELSE TRY_TO_DECIMAL(old_value, 38, 10) * 10000
        END AS previous_amount_eur,

        old_currency AS source_currency
    FROM change_log_base
    WHERE field_name = 'NET_AMOUNT'
),

main_cost_match AS (
    SELECT *
    FROM (
        SELECT
            n.order_id,
            n.amount_eur AS earlier_assigned_cost,
            n.source_currency,
            e.carrier_id AS earlier_assigned_carrier_id,
            n.change_timestamp,
            ROW_NUMBER() OVER (
                PARTITION BY n.order_id
                ORDER BY n.change_timestamp DESC
            ) AS row_number_desc
        FROM earlier_external_carrier AS e
        INNER JOIN last_carrier_status AS l
            ON l.order_id = e.order_id
            AND l.is_internal_fleet = 1
        INNER JOIN net_amount_changes AS n
            ON n.order_id = e.order_id
            AND n.amount_eur > 0
            AND n.change_timestamp >= e.start_timestamp
            AND (
                e.end_timestamp IS NULL
                OR n.change_timestamp < e.end_timestamp
            )
    ) AS ranked
    WHERE row_number_desc = 1
),

fallback_cost_match AS (
    SELECT *
    FROM (
        SELECT
            n.order_id,
            n.previous_amount_eur AS earlier_assigned_cost,
            n.source_currency,
            e.carrier_id AS earlier_assigned_carrier_id,
            n.change_timestamp,
            ROW_NUMBER() OVER (
                PARTITION BY n.order_id
                ORDER BY n.change_timestamp
            ) AS row_number_asc
        FROM net_amount_changes AS n
        INNER JOIN earlier_external_carrier AS e
            ON n.order_id = e.order_id
        INNER JOIN last_carrier_status AS l
            ON l.order_id = e.order_id
            AND l.is_internal_fleet = 1
    ) AS ranked
    WHERE row_number_asc = 1
),

final_output AS (
    SELECT *
    FROM main_cost_match

    UNION ALL

    SELECT f.*
    FROM fallback_cost_match AS f
    WHERE NOT EXISTS (
        SELECT 1
        FROM main_cost_match AS m
        WHERE m.order_id = f.order_id
    )
)

SELECT
    f.order_id,
    f.earlier_assigned_cost,
    f.earlier_assigned_carrier_id,
    f.change_timestamp,
    f.source_currency
FROM final_output AS f
WHERE f.earlier_assigned_cost >= 100
    AND NOT EXISTS (
        SELECT 1
        FROM excluded_orders AS e
        WHERE e.order_id = f.order_id
    );
