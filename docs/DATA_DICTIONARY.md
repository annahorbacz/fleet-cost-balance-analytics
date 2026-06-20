# Mock Data Dictionary

Synthetic dataset for the Fleet Cost Balance Analytics portfolio project.

## Main grain

`fact_transport_orders`: 1 row = 1 freight order executed by the internal fleet.

## Key formula

`cost_balance = df_cost_corrected - alternative_cost`

Positive value = internal fleet was more expensive than the realistic alternative cost.  
Negative value = internal fleet generated savings.

## Model notes

This dataset intentionally keeps small categorical attributes such as `tender_type` and `operating_region` directly in the fact table to avoid unnecessary over-modeling.

Separate dimension tables are used where they add analytical value:

- `dim_calendar.csv`
- `dim_route.csv`
- `dim_carrier.csv`
- `dim_cost_balance_source.csv`

## Files

- `fact_transport_orders.csv` — main order-level fact table
- `bridge_previous_orders.csv` — previous order sequence analysis
- `benchmark_rates_by_route_month.csv` — historical average benchmark rates
- `dim_route.csv` — route / lane dimension
- `dim_carrier.csv` — carrier dimension
- `dim_cost_balance_source.csv` — benchmark rule/source dimension
- `dim_calendar.csv` — date dimension

All data is fake and generated for portfolio purposes.
