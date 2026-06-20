# Cost Balance Logic

The `cost_balance` calculation estimates whether the internal fleet execution was financially beneficial compared to realistic external transportation alternatives.

The logic dynamically selects the best available benchmark source based on tender type and data availability.

## Benchmark priority

1. Earlier assigned carrier cost
2. Lowest spot market bid
3. Average spot benchmark rate
4. Average contracted benchmark rate
5. Rank 1 carrier contracted cost

If no realistic alternative cost is available, the measure returns `BLANK()` to avoid misleading comparisons.

## DAX Measure

```DAX
cost_balance = 
VAR TenderType =
    fact_transport_orders[tender_type]

VAR AvgNonSpotRateCost =
    RELATED(fact_benchmark_rates[avg_non_spot_rate_cost])

VAR AvgSpotRateCost =
    RELATED(fact_benchmark_rates[avg_spot_rate_cost])

VAR AlternativeCost =
    SWITCH(
        TRUE(),

        NOT ISBLANK(fact_transport_orders[earlier_assigned_cost]),
            fact_transport_orders[earlier_assigned_cost],

        TenderType = "Spot"
            && NOT ISBLANK(fact_transport_orders[lowest_spot_bid]),
            fact_transport_orders[lowest_spot_bid],

        TenderType = "Spot"
            && NOT ISBLANK(AvgSpotRateCost),
            AvgSpotRateCost,

        TenderType <> "Spot"
            && NOT ISBLANK(AvgNonSpotRateCost),
            AvgNonSpotRateCost,

        TenderType <> "Spot"
            && NOT ISBLANK(fact_transport_orders[rank_1_carrier_cost]),
            fact_transport_orders[rank_1_carrier_cost],

        BLANK()
    )

RETURN
IF(
    ISBLANK(AlternativeCost),
    BLANK(),
    AlternativeCost - fact_transport_orders[df_cost_corrected]
)
```
