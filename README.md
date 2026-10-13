# Query-Intel Skill + Test Suites

A Cortex Code skill for SQL query analysis (explanation, correctness, performance) along with two test suites to validate it.

## Structure

```
skill/SKILL.md              — Query-Intel skill definition
test_suite_tpcds.sql        — 16 test queries against TPC-DS (SNOWFLAKE_SAMPLE_DATA.TPCDS_SF10TCL)
test_suite_cybersyn.sql     — 16 test queries against Cybersyn (SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE)
```

## Test Categories

Each suite covers 16 categories (Q1–Q16 map 1:1 across suites):

**Correctness:** NULL comparison, AND/OR precedence, timestamp predicate traps, non-deterministic predicates, division by zero, UNION vs UNION ALL, NULL in aggregation, wrong join / fanout.

**Performance:** Non-selective predicates, repeated scans, unnecessary sort, cartesian product, missing date predicates, correlated subquery.

**Complexity / Explanation:** CTEs + window functions, multi-join star schema / EAV pivot.

## Data Sources

- **TPC-DS:** Pre-installed at `SNOWFLAKE_SAMPLE_DATA.TPCDS_SF10TCL` (10TB scale).
- **Cybersyn:** Install the free "Snowflake Public Data (Free)" listing from the Snowflake Marketplace. It appears as `SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE`.

## Usage

Feed any query to the `query-intel` skill in Cortex Code and verify it detects the intended issue described in the query's comment header.
