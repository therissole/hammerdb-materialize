# Locust Load Test

This folder contains a Locust-based read workload for Materialize.

It connects directly to Materialize and exercises three query shapes:

1. Customer directory browse.
2. Recent orders plus order-line detail lookups.
3. Dashboard-style aggregate by district.

## Run

Start the stack first, then bring up Locust with the `locust` profile:

```bash
docker compose --profile locust up -d --build locust
```

Open the Locust UI at http://localhost:8089.

## Required objects

The load test expects these Materialize views to exist in the `tpcc` schema:

- `tpcc.customer`
- `tpcc.order_summary`
- `tpcc.order_detail`

Canonical query definitions for the two derived views are stored in:

- `scripts/queries/order_summary.sql`
- `scripts/queries/order_detail.sql`

`order_summary` should expose `o_total` so the dashboard query can run:

```sql
select o_d_id, sum(o_total) from order_summary group by o_d_id
```
