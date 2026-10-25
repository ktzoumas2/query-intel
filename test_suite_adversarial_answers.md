# Adversarial Suite: Answer Key (evaluator only)

Do not show this file, or `test_suite_adversarial_setup.sql`, to the skill under test. The skill gets only `test_suite_adversarial.sql` plus whatever it can learn from Snowflake metadata (`GET_DDL`, `EXPLAIN`, etc.).

Each query is designed to make the skill fail. A **PASS** means the skill avoided the trap.

## Explanation traps

### A1: opaque names
- **Ground truth:** Table `T_9X` and columns `C1..C6` carry no meaning. The data is synthetic random values.
- **Expected failure:** The skill invents business meaning, e.g. "C2 is a store id, C3 is price".
- **PASS:** A structural explanation (filter on C5, group by C2/C4, count/avg/sum, keep groups with more than 10 rows) that says outright the business meaning can't be inferred.

### A2: misleading table and column names
- **Ground truth:** `CUSTOMERS` holds IoT sensor readings. `REVENUE` is temperature in Kelvin (about 270-310), `REGION` is a device zone, `CUSTOMER_ID` is a device id. The query computes average temperature and temperature range per zone.
- **Expected failure:** The skill explains it as "average revenue per sales region".
- **PASS:** Any hedge that the names may not match the content. A strong pass notices that `REVENUE` values cluster tightly around 270-310, which only shows up if the skill looks at stats or EXPLAIN.

### A3: inverted flag
- **Ground truth:** `IS_ACTIVE = 1` means soft-deleted (a legacy inverted flag). The query correctly lists churned accounts.
- **Expected failure:** The skill flags "filtering on is_active = 1 contradicts the churned intent" as a bug, or describes the output as active accounts.
- **PASS:** No correctness bug. At most a note that the flag name and the CTE name seem to conflict and the user should confirm.

## Correctness traps

### A4: false positive, NOT NULL column
- **Ground truth:** `STATUS` is declared `NOT NULL`, so `!= 'VOID'` can't silently drop NULLs. The query is correct.
- **Expected failure:** The skill flags a NULL-handling bug.
- **PASS:** No NULL finding, or a finding the skill withdraws after checking the DDL.

### A5: false positive, single-row config
- **Ground truth:** `APP_CONFIG` has exactly one row, so `LIMIT 1` without `ORDER BY` is deterministic and the `CROSS JOIN` doesn't multiply rows.
- **Expected failure:** The skill flags non-determinism and/or a cartesian product as a Bug or Risk.
- **PASS:** No Bug-level finding. A Suggestion-level note ("assumes a single-row table") is fine.

### A6: false negative, SCD2 fanout
- **Ground truth:** `DIM_ACCOUNT` has 3 versions per `ACCOUNT_ID`. Without `IS_CURRENT = TRUE` (or a date-range join), every activity row is counted three times, once under each tier. Spend is inflated 3x and spread across tiers.
- **Expected failure:** The skill reports no correctness issue, because the join looks like an ordinary key join.
- **PASS:** Flags possible fanout or non-unique `account_id` in the dimension and suggests a current-row or validity-range filter.

### A7: false negative, implicit VARCHAR to NUMBER cast
- **Ground truth:** `EXT_ID` is VARCHAR with leading zeros ('007', '0007', '00007'...). The join to NUMBER `ID` casts it implicitly, so different partner strings collapse onto the same merchant. Any non-numeric value would also make the query fail at runtime.
- **Expected failure:** No finding.
- **PASS:** Flags the type mismatch and the leading-zero collision (best case: after checking the column types).

### A8: false negative, timezone
- **Ground truth:** `LOGIN_TS` is `TIMESTAMP_NTZ` holding UTC wall-clock time. `CURRENT_DATE()` uses the session timezone, which defaults to `America/Los_Angeles` on this account. So the "today" window is shifted by 7-8 hours and the count is wrong for part of every day.
- **Expected failure:** No finding.
- **PASS:** Flags the NTZ vs session-timezone mismatch and suggests `CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::DATE` or similar.

## Performance traps (skewed data)

Data shape (from setup): `FACT_EVENTS` has 10M rows in random order. `STATUS = 'COMPLETE'` is about 99% of rows, `CUST_KEY = 1` is about 95%, and `EVENT_ID` is unique.

A PASS means the skill does not recommend the degrading rewrite, or recommends it only with a caveat tied to data distribution. Measurements: XS warehouse `COMPUTE_WH`, result cache disabled, elapsed time from `QUERY_HISTORY`. At this scale every query runs in well under a second, so bytes scanned is the more reliable signal than elapsed time.

### A9: OR to UNION ALL
- **Intuitive suggestion:** Split the `OR` into a `UNION ALL` of two branches so each can prune.
- **Why it degrades:** `status = 'COMPLETE'` matches about 99% of rows, so neither branch prunes. The rewrite scans the table twice.
- **Degraded rewrite:**
  ```sql
  SELECT region_code, COUNT(*), SUM(amount) FROM (
      SELECT region_code, amount FROM fact_events WHERE status = 'COMPLETE'
      UNION ALL
      SELECT region_code, amount FROM fact_events WHERE region_code = 7 AND status <> 'COMPLETE'
  ) GROUP BY region_code;
  ```
- **Measured (2 runs each):** original 106 / 141 ms, 478-494 MB scanned. Rewrite 142 / 167 ms, 957 MB-1.03 GB scanned. About 2x the bytes and slower in both runs. **Confirmed.**

### A10: pre-aggregate before join
- **Intuitive suggestion:** Aggregate `fact_events` in a CTE before joining, to reduce join input.
- **Why it degrades:** The join key `event_id` is unique, so grouping on it reduces nothing and adds a full hash-aggregate pass.
- **Degraded rewrite:**
  ```sql
  WITH f AS (SELECT event_id, SUM(amount) AS amount, COUNT(*) AS n
             FROM fact_events WHERE event_ts >= '2024-07-01' GROUP BY event_id)
  SELECT d.channel, SUM(f.amount), SUM(f.n)
  FROM f JOIN event_details d ON f.event_id = d.event_id GROUP BY d.channel;
  ```
- **Measured (5 runs each):** original median 482 ms (range 361-547). Rewrite median 539 ms (range 477-655). Same bytes scanned (549 MB), so the extra time is the added aggregation pass. **Confirmed, modest effect** (about 12% at 10M rows).

### A11: cluster on the "selective" filter column
- **Intuitive suggestion:** Add `CLUSTER BY (status)`, or treat `status = 'COMPLETE'` as a selective filter that should prune.
- **Why it degrades:** About 99% of rows match. No clustering can prune a predicate that keeps almost everything, and reclustering a 10M-row table on a skewed low-cardinality column costs credits with no read benefit.
- **Measured:** `EXPLAIN` shows 8 of 8 micro-partitions assigned. The predicate prunes nothing. **Confirmed.** Clustering itself wasn't benchmarked because it would cost credits for a known non-result.

## Dropped case

A correlated-subquery to window-function trap (cust_key skew, 95% in one partition) was designed but didn't hold up. Over 3 runs each the original and the window rewrite were the same within noise (median 211 vs 195 ms, same bytes). It was removed instead of being kept with an unproven claim. It may show up at larger scale.
