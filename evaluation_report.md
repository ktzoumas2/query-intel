# Query-Intel Skill Evaluation Report

## Summary Table

| Query ID | Suite | Category | Score | Notes |
|----------|-------|----------|-------|-------|
| Q1 | TPC-DS | Correctness | PASS | Identified `!=` dropping NULLs; fix with `IS DISTINCT FROM` or `OR IS NULL` |
| Q2 | TPC-DS | Correctness | PASS | Identified AND binding tighter than OR; fix with parentheses |
| Q3 | TPC-DS | Correctness | PASS | Identified inclusive upper bound including April 1; fix with half-open range |
| Q4 | TPC-DS | Correctness | PASS | Identified unstable ROW_NUMBER ties; fix with tiebreaker or RANK() |
| Q5 | TPC-DS | Correctness | PASS | Identified zero/NULL denominator risk; fix with NULLIF |
| Q6 | TPC-DS | Correctness | PASS | Identified deduplication removing valid transactions; fix with UNION ALL |
| Q7 | TPC-DS | Correctness | PASS | Identified COUNT(DISTINCT) ignoring NULLs; fix with COALESCE or separate metric |
| Q8 | TPC-DS | Correctness | PASS | Identified many-to-many on single key; fix with composite join key |
| Q9 | TPC-DS | Performance | PASS | Flagged EXTRACT() defeating pruning; use `d_year` column directly |
| Q10 | TPC-DS | Performance | PASS | Flagged redundant store_sales scan; consolidate to single pass |
| Q11 | TPC-DS | Performance | PASS | Flagged useless inner ORDER BY; removed and flattened subquery |
| Q12 | TPC-DS | Performance | PASS | Flagged missing join predicate (cartesian product); added equi-join |
| Q13 | TPC-DS | Performance | PASS | Flagged no date filter on 28B-row fact table; add date predicate |
| Q14 | TPC-DS | Performance | PASS | Flagged scalar subquery rescanning fact table; refactored to CTE |
| Q15 | TPC-DS | Explanation | PASS | Correctly described running total + MoM change per store for 2002 |
| Q16 | TPC-DS | Explanation | PASS | Correctly described cross-channel revenue comparison by category |
| Q17 | TPC-DS | False-positive | PASS | No false correctness flag on SELECT * |
| Q18 | TPC-DS | False-positive | PASS | No false correctness flag on intentional UNION |
| Q19 | TPC-DS | False-positive | PASS | No false correctness flag on NOT IN with non-nullable PK |
| Q20 | TPC-DS | False-positive | PASS | No false correctness flag on intentional COUNT(column) |
| Q21 | TPC-DS | Bad-rewrite-trap | PASS | Recognized IS NULL guard; did not suggest INNER JOIN |
| Q22 | TPC-DS | Bad-rewrite-trap | PASS | Suggested ANY_VALUE(), not GROUP BY or MAX() |
| Q23 | TPC-DS | Bad-rewrite-trap | PASS | Suggested pre-aggregated CTE, not naive bare JOIN |
| Q24 | TPC-DS | Bad-rewrite-trap | PASS | Did not suggest removing DISTINCT |
| Q1 | Cybersyn | Correctness | PASS | Identified `!=` dropping NULL PRIMARY_TICKER rows; fix with OR IS NULL |
| Q2 | Cybersyn | Correctness | PASS | Identified AND/OR precedence bug; fix with parentheses |
| Q3 | Cybersyn | Correctness | PASS | Identified inclusive BETWEEN upper bound including Jan 1 2024; fix with half-open range |
| Q4 | Cybersyn | Correctness | PASS | Identified non-deterministic ROW_NUMBER on non-unique VALUE; fix with tiebreaker |
| Q5 | Cybersyn | Correctness | PASS | Identified unguarded division by prev_cpi; fix with NULLIF |
| Q6 | Cybersyn | Correctness | PASS | Identified UNION deduplicating valid rows; fix with UNION ALL |
| Q7 | Cybersyn | Correctness | PASS | Identified COUNT(DISTINCT) ignoring NULL tickers; fix with explicit NULL count |
| Q8 | Cybersyn | Correctness | PASS | Identified 1:N fanout on company_characteristics; fix with pre-aggregated CTE |
| Q9 | Cybersyn | Performance | PASS | Flagged EXTRACT(YEAR) defeating pruning; use range predicate |
| Q10 | Cybersyn | Performance | PASS | Flagged three redundant scans; consolidate with conditional aggregation |
| Q11 | Cybersyn | Performance | PASS | Flagged pointless inner ORDER BY; remove it |
| Q12 | Cybersyn | Performance | PASS | Flagged CartesianJoin (confirmed by EXPLAIN); add join predicate |
| Q13 | Cybersyn | Performance | PASS | Flagged missing DATE predicate; add date range filter |
| Q14 | Cybersyn | Performance | PASS | Flagged redundant second scan; rewrite with MAX() OVER() window function |
| Q15 | Cybersyn | Explanation | PASS | Correctly described state-level MoM unemployment spike ranking for 2023 |
| Q16 | Cybersyn | Explanation | PASS | Correctly described EAV pivot, daily return, and 5-day MA for tech stocks |
| Q17 | Cybersyn | False-positive | PASS | No false correctness flag; acknowledged Snowflake column pruning |
| Q18 | Cybersyn | False-positive | PASS | No false correctness flag; noted literal column makes UNION/ALL equivalent |
| Q19 | Cybersyn | False-positive | PASS | No false correctness flag; recognized PK is non-nullable |
| Q20 | Cybersyn | False-positive | PASS | No false correctness flag; recognized intentional COUNT(col) pattern |
| Q21 | Cybersyn | False-positive | PASS | Recognized IS NULL guard preserves LEFT JOIN semantics; no naive INNER JOIN suggestion |
| Q22 | Cybersyn | Bad-rewrite-trap | PASS | Suggested ANY_VALUE(); explicitly discouraged GROUP BY and MAX() |
| Q23 | Cybersyn | Bad-rewrite-trap | PASS | Suggested pre-aggregated CTE; warned against naive JOIN fanout |
| Q24 | Cybersyn | Bad-rewrite-trap | PASS | Recognized DISTINCT as intentional for many-to-many; did not suggest removal |

## Aggregate Statistics

### By Category

| Category | Total | PASS | PARTIAL | FAIL | Pass Rate |
|----------|-------|------|---------|------|-----------|
| Correctness (Q1-Q8) | 16 | 16 | 0 | 0 | 100% |
| Performance (Q9-Q14) | 12 | 12 | 0 | 0 | 100% |
| Explanation (Q15-Q16) | 4 | 4 | 0 | 0 | 100% |
| False-positive (Q17-Q20) | 8 | 8 | 0 | 0 | 100% |
| Bad-rewrite-trap (Q21-Q24) | 8 | 8 | 0 | 0 | 100% |
| **Total** | **48** | **48** | **0** | **0** | **100%** |

### By Suite

| Suite | Total | PASS | PARTIAL | FAIL | Pass Rate |
|-------|-------|------|---------|------|-----------|
| TPC-DS | 24 | 24 | 0 | 0 | 100% |
| Cybersyn | 24 | 24 | 0 | 0 | 100% |
| **Total** | **48** | **48** | **0** | **0** | **100%** |

## Findings

### Notable Strengths

1. **EXPLAIN plan usage strengthened analysis.** For the Cybersyn suite, EXPLAIN plans were retrieved for most queries. This provided concrete evidence — for example, Q12's plan explicitly showed a `CartesianJoin` operator, and Q23's plan revealed Snowflake's optimizer already decorrelates the correlated subquery into an optimal LeftOuterJoin with pre-aggregation.

2. **Nuanced handling of Q14 (correlated subquery).** Both suites' Q14 expected description calls the subquery "correlated," but the skill correctly identified that the subquery is actually *uncorrelated* (it doesn't reference outer columns). It still flagged the redundant double-scan and suggested the right fix (CTE or window function), demonstrating the analysis goes beyond pattern-matching labels.

3. **Strong false-positive suppression (Q17-Q20).** The skill avoided all 8 false-positive traps across both suites. Particularly notable:
   - **Q18 (UNION):** The skill recognized that the literal column differentiating branches makes UNION/UNION ALL equivalent, rather than reflexively flagging UNION as a bug.
   - **Q19 (NOT IN):** The skill correctly identified that the subquery column is a non-nullable PK, defusing the classic NOT IN trap.
   - **Q20 (COUNT(col)):** The skill recognized the intentional NULL-exclusion pattern rather than suggesting COUNT(*).

4. **Bad-rewrite-trap avoidance (Q21-Q24).** All 8 trap queries were handled correctly:
   - **Q22** consistently used `ANY_VALUE()` (the idiomatic Snowflake solution) rather than the naive `GROUP BY` addition or `MAX()`.
   - **Q23** consistently used pre-aggregated CTEs rather than naive JOINs that would cause fanout.
   - **Q21** recognized the `OR IS NULL` guard that preserves LEFT JOIN semantics.
   - **Q24** recognized DISTINCT as intentional for set-of-pairs questions.

### Nuances and Edge Cases

1. **Q6 (UNION vs UNION ALL) — Cross-branch vs within-branch dedup.** The expected bug description states that UNION drops "valid dual-dataset rows" (cross-branch). In the Cybersyn version, the skill noted that the differing literal source columns (`'employment'` vs `'prices'`) actually prevent cross-branch deduplication — the real bug is *within-branch* deduplication of multiple timeseries rows projecting to the same `(GEO_ID, DATE, source)` tuple. The fix is the same (UNION ALL), but the diagnosis is more precise than the test expected.

2. **Q8 (Fanout) — AVG resilience.** In the Cybersyn Q8, the skill noted that `AVG()` is mathematically idempotent under uniform row duplication (unlike SUM or COUNT), so the numeric result may not be wrong. It still correctly flagged the pattern as a correctness hazard since switching to any other aggregate would produce incorrect results, and the semantic output (same AVG repeated per relationship type) is likely not the intent.

3. **Q5 (Division by zero) — Practical vs theoretical risk.** Both suites' Q5 involves dividing by a value that is practically never zero (CPI values, store quantities). The skill correctly flags the unguarded division as a bug with the NULLIF fix, which is the right call — defensive coding should not rely on data assumptions.

4. **Q3 (Timestamp predicate) — TPC-DS vs Cybersyn framing.** The TPC-DS version frames the bug as "end bound '2002-04-01' includes April 1 when intent is Q1 only." The Cybersyn version frames it as "includes Jan 1 2024 when intent is 2023 only." Both were correctly identified. The skill consistently recommended the half-open range pattern (`>= / <`) as the robust solution.

### Patterns and Observations

- **No failures or partial scores.** The skill identified every planted bug, avoided every false positive, and avoided every rewrite trap across both test suites.
- **Consistent fix quality.** Rewrites were always concrete SQL, not vague suggestions. Fixes preserved the query's original intent and correctly handled edge cases.
- **EXPLAIN plans added value but weren't required.** The static analysis alone was sufficient to identify all issues. EXPLAIN plans served as confirmation evidence (e.g., CartesianJoin operators, optimizer sort elision, decorrelation).
- **Schema knowledge matters.** Several correct assessments depended on understanding table relationships — for example, knowing that `GEO_ID` is a PK in geography_index (Q19), or that `ss_store_sk → s_store_name` is a 1:1 dependency (Q22). The skill correctly inferred these from join patterns and naming conventions.
