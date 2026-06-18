# Fleet Cost Balance Analytics

Enterprise-inspired transportation cost benchmarking and operational analytics project built with Power BI and SQL.

## Business Problem

The project focuses on evaluating the real financial impact of an internal transportation fleet by comparing actual fleet execution costs against realistic alternative transportation cost scenarios.

Traditional benchmarking approaches compared fleet execution costs against the cheapest contracted carrier available on a given route, which significantly overestimated operational losses. This project introduces a rule-based comparison engine that dynamically selects the most realistic alternative cost depending on operational conditions such as:

- Earlier assigned carriers
- Spot market tenders
- Contracted carrier rankings
- Walk away costs
- Historical average transportation rates

## Key Features

- Complex transportation cost benchmarking logic
- Rule-based alternative cost selection engine
- Power BI semantic model
- SQL preprocessing layer
- Transportation KPI analysis
- Operational trend analysis
- Route performance monitoring

## Tech Stack

- Power BI
- SQL
- Power Query
- DAX
- Snowflake
- SAP

## Planned Project Structure

```txt
fleet-cost-balance-analytics/
├── sql/
├── powerbi/
├── screenshots/
├── data_model/
└── docs/
