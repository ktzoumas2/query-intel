# Query-Intel Skill + Test Suites

A Cortex Code skill for SQL query analysis (explanation, correctness, performance) along with three test suites to validate it.

## Structure

```
skill/SKILL.md              — Query-Intel skill definition
test_suite_tpcds.sql        — 24 test queries against TPC-DS (SNOWFLAKE_SAMPLE_DATA.TPCDS_SF10TCL)
test_suite_cybersyn.sql     — 24 test queries against Cybersyn (SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE)
test_suite_adversarial.sql           — 11 hint-free queries designed to make the skill fail (QUERY_INTEL_TEST.ADVERSARIAL)
test_suite_adversarial_setup.sql     — creates the synthetic tables for the adversarial suite (evaluator only)
test_suite_adversarial_answers.md    — ground truth + measured benchmarks for the adversarial suite (evaluator only)
```

## Test Categories

Each suite covers 24 categories (Q1–Q24 map 1:1 across suites):

**Correctness (Q1-Q8):** NULL comparison, AND/OR precedence, timestamp predicate traps, non-deterministic predicates, division by zero, UNION vs UNION ALL, NULL in aggregation, wrong join / fanout.

**Performance (Q9-Q14):** Non-selective predicates, repeated scans, unnecessary sort, cartesian product, missing date predicates, correlated subquery.

**Complexity / Explanation (Q15-Q16):** CTEs + window functions, multi-join star schema / EAV pivot.

**False-Positive (Q17-Q20):** SELECT * where all columns are needed, UNION where dedup is intentional, NOT IN with non-nullable subquery column, COUNT(column) intentionally excluding NULLs. The skill should produce no correctness findings on these.

**Bad-Rewrite-Trap (Q21-Q24):** LEFT JOIN that looks like INNER but preserves NULLs via OR, non-aggregated column with functional dependency, correlated subquery where JOIN introduces fanout, DISTINCT on intentional many-to-many. The skill should not suggest the naive fix that changes semantics.

## Adversarial Suite

Runs on synthetic tables in `QUERY_INTEL_TEST.ADVERSARIAL`, because misleading names, hidden schema facts and skew can't be built on the public datasets.

- **Explanation (A1-A3):** opaque names, a "customers" table holding sensor data, an inverted `IS_ACTIVE` flag.
- **Correctness (A4-A8):** false positives (NOT NULL column, single-row config) and false negatives (SCD2 fanout, VARCHAR to NUMBER leading-zero collisions, NTZ vs session timezone).
- **Performance (A9-A11):** skewed data where the intuitive rewrite is slower (OR to UNION ALL, pre-aggregating on a unique key, "selective" filter that keeps 99% of rows). Each degradation was measured, see the answer key.

Queries are labelled only by ID. Ground truth is in `test_suite_adversarial_answers.md`, which the evaluator reads after the skill has answered. Don't give the skill the setup script or the answer key.

Setup: run `test_suite_adversarial_setup.sql` (10M-row fact table by default). Teardown: `DROP DATABASE QUERY_INTEL_TEST;`

## Known Issue: Answer Leakage in Q-Suites

In the TPC-DS and Cybersyn suites, each query's comment header states the expected bug. If the skill sees the whole file, it can read the answer straight from the comment. For a fair evaluation, strip the headers before feeding queries to the skill, or move them into an answer key the way the adversarial suite does.

## Data Sources

- **TPC-DS:** Pre-installed at `SNOWFLAKE_SAMPLE_DATA.TPCDS_SF10TCL` (10TB scale).
- **Cybersyn:** Install the free "Snowflake Public Data (Free)" listing from the Snowflake Marketplace. It appears as `SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE`.
- **Adversarial:** Created by `test_suite_adversarial_setup.sql`.

## Usage

Feed any query to the `query-intel` skill in Cortex Code and verify it detects the intended issue described in the query's comment header.
