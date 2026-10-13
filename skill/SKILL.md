---
name: query-intel
description: "Analyze a SQL query for understanding, correctness, and performance. Use when the user provides SQL text or a Snowflake query ID and wants to understand what it does, find bugs or correctness issues, or identify performance problems. Triggers: explain query, review SQL, check query, query issues, SQL correctness, SQL performance, what does this query do, is this query correct, optimize query, query review, analyze SQL, SQL bugs, query problems, debug SQL, slow query, review my SQL, check my query."
---

# Query Intel

Analyze a Snowflake SQL query in three dimensions: **explanation**, **correctness**, and **performance**.

**Scope constraint:** This skill performs **static analysis only**. Never execute the user's query or any rewritten version of it. The only SQL you may run is metadata retrieval (fetching query text from `QUERY_HISTORY`, object definitions via `GET_DDL`/`INFORMATION_SCHEMA`, and query profile stats from `GET_QUERY_OPERATOR_STATS`). All analysis is done by reading the SQL text, not by running it.

## Workflow

### Step 1: Acquire the Query

**Goal:** Obtain the SQL text to analyze.

**Actions:**

The user provides either:

- **SQL text** directly in the conversation or in a file
- **A Snowflake query ID** -- retrieve the SQL with:

```sql
SELECT QUERY_TEXT
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE QUERY_ID = '<id>'
```

If the query references views or stored procedures whose definitions matter for a thorough review, fetch those definitions via `GET_DDL` or `INFORMATION_SCHEMA`. Use judgment -- only fetch when the outer query's correctness or performance depends on understanding the inner definition.

If the user provides a query ID, also retrieve the query profile metadata when relevant to the performance section:

```sql
SELECT *
FROM TABLE(GET_QUERY_OPERATOR_STATS('<query_id>'))
```

These metadata queries are the **only** SQL you may execute. Never run the user's query itself or any rewrite of it.

### Step 2: Explain

**Goal:** Produce a clear, plain-language explanation of what the query computes.

**Actions:**

1. Break the query into logical sections (CTEs, subqueries, main SELECT).
2. For each section, describe:
   - What data it reads and from where
   - What filtering, joining, or aggregation it performs
   - What the output represents in business terms (infer from column/table names)
3. Summarize the overall result: "This query returns [what] by [how]."

Keep the explanation concise. Use a bulleted breakdown for complex queries; a single paragraph for simple ones.

### Step 3: Correctness Review

**Goal:** Flag logic bugs, subtle pitfalls, and correctness risks. Provide SQL rewrites for each issue.

**Check for these categories (non-exhaustive -- apply SQL expertise broadly):**

| Category | Examples |
|----------|----------|
| NULL handling | Comparisons with `=`/`!=` instead of `IS [NOT] NULL`; `NOT IN` with nullable subquery; `COUNT(col)` vs `COUNT(*)` when NULLs matter |
| Join correctness | Wrong join type silently dropping or duplicating rows; missing join predicates producing cartesian products; join on columns with mismatched types causing implicit casting |
| Aggregation | Columns in SELECT not in GROUP BY and not aggregated (Snowflake allows this but picks arbitrary values); HAVING filters that should be WHERE; DISTINCT masking a fanout bug |
| Type coercion | Implicit casts between VARCHAR and NUMBER in predicates; date/string comparison without explicit conversion; integer division losing precision |
| Window functions | Missing or incorrect PARTITION BY; ORDER BY in window frame not matching intent; ROWS vs RANGE semantics confusion |
| Predicate logic | OR conditions that need parentheses; negative conditions that don't account for NULLs; LIKE patterns without proper escaping |
| Set operations | UNION vs UNION ALL when duplicates matter; column alignment mismatches between branches |
| Determinism | Queries that return different results on re-execution (e.g., LIMIT without ORDER BY, non-deterministic functions in filters) |

**For each issue found:**
- State the problem clearly
- Explain why it's wrong or risky (what incorrect results could occur)
- Provide a concrete SQL rewrite that fixes it

If no correctness issues are found, say so explicitly.

### Step 4: Performance Review

**Goal:** Flag performance anti-patterns and suggest improvements through static analysis of the SQL text. If query profile data was retrieved in Step 1 (from a query ID), incorporate those metrics. Do not execute the query or use EXPLAIN to obtain new profile data.

**Check for these categories (non-exhaustive):**

| Category | Examples |
|----------|----------|
| Scan scope | `SELECT *` when few columns are needed; missing filters on large tables; filters on non-clustered columns for very large tables |
| Join efficiency | Cartesian products or very large cross joins; joining large tables without pushdown-friendly predicates; repeated joins to the same table that could be consolidated |
| Subquery patterns | Correlated subqueries that could be rewritten as joins; repeated subqueries that could be CTEs; `IN (SELECT ...)` on large sets vs `EXISTS` or join |
| Sorting & limits | `ORDER BY` in subqueries/CTEs that don't feed a `LIMIT`; sorting on high-cardinality expressions; unnecessary `DISTINCT` on already-unique results |
| Function usage | Scalar functions on columns in WHERE clauses preventing pruning (e.g., `YEAR(date_col) = 2024` vs range predicate); UDF calls in tight loops |
| Data types | String operations on columns that could be numeric/date; overly wide VARCHAR columns used in joins |
| Warehouse hints | If query profile data shows significant spilling, suggest a larger warehouse; if scan is heavy, suggest clustering keys to investigate |

**For each issue found:**
- Describe the problem and its likely performance impact
- Suggest a specific fix or rewrite
- Note when the fix involves a trade-off (e.g., readability vs speed)

If query profile data is available, reference specific operators (e.g., "TableScan on ORDERS accounted for 80% of execution time").

If no performance issues are found, say so explicitly.

### Step 5: Present Report

**Goal:** Deliver a consolidated, structured report.

**Format the output as three clear sections:**

1. **Explanation** -- what the query does
2. **Correctness** -- issues found (or "No issues found"), each with problem/risk/fix
3. **Performance** -- issues found (or "No issues found"), each with problem/impact/suggestion

Use severity indicators where helpful:
- **Bug** -- almost certainly produces wrong results
- **Risk** -- produces correct results in most cases but can fail on edge cases
- **Suggestion** -- not wrong but could be improved

End with a rewritten version of the full query incorporating all suggested fixes, if any issues were found. If the query is clean, say so.

## Stopping Points

- After Step 1 if the query cannot be retrieved (bad query ID, no SQL provided)
- After Step 5 for user review and follow-up questions

## Output

A structured analysis with three sections (explanation, correctness, performance), concrete SQL rewrites for each issue, and an optional consolidated rewrite of the full query.
