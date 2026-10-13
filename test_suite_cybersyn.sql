--------------------------------------------------------------------------------
-- Query-Intel Test Suite: Cybersyn (Snowflake Public Data Free)
-- Source: SNOWFLAKE_PUBLIC_DATA_FREE.PUBLIC_DATA_FREE
--
-- Each query is tagged with the category it exercises.
-- Queries are intentionally flawed (for correctness / performance tests)
-- or intentionally complex (for explanation tests).
--------------------------------------------------------------------------------

-- =============================================================================
-- CORRECTNESS TESTS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Q1  [Correctness: NULL comparison]
-- Bug: PRIMARY_TICKER can be NULL for private companies.  The != filter
-- silently drops all rows where PRIMARY_TICKER IS NULL, excluding private
-- companies from the count instead of counting them in an "unlisted" bucket.
-- ---------------------------------------------------------------------------
SELECT
    ci.PRIMARY_EXCHANGE_NAME,
    COUNT(*) AS company_count
FROM snowflake_public_data_free.public_data_free.company_index ci
WHERE ci.PRIMARY_TICKER != 'AAPL'          -- NULLs silently excluded
GROUP BY ci.PRIMARY_EXCHANGE_NAME
ORDER BY company_count DESC;


-- ---------------------------------------------------------------------------
-- Q2  [Correctness: AND/OR precedence]
-- Bug: Intent is "(LAUS report OR JOLTS report) AND monthly frequency".
-- Without parentheses, AND binds tighter:
--   LAUS  OR  (JOLTS AND monthly)
-- which returns all LAUS rows regardless of frequency.
-- ---------------------------------------------------------------------------
SELECT
    a.REPORT,
    a.FREQUENCY,
    COUNT(*) AS variable_count
FROM snowflake_public_data_free.public_data_free.bureau_of_labor_statistics_employment_attributes a
WHERE a.REPORT = 'Local Area Unemployment Statistics'
   OR a.REPORT = 'Job Openings and Labor Turnover Survey'
  AND a.FREQUENCY = 'Monthly'                  -- AND binds before OR
GROUP BY a.REPORT, a.FREQUENCY
ORDER BY variable_count DESC;


-- ---------------------------------------------------------------------------
-- Q3  [Correctness: Timestamp predicate trap]
-- Bug: DATE column compared against a TIMESTAMP with time component.
-- The cast to TIMESTAMP changes semantics — BETWEEN with timestamps on a
-- DATE column includes the end date entirely (DATE '2023-12-31' becomes
-- TIMESTAMP '2023-12-31 00:00:00' which matches), but if someone later
-- changes the end to '2024-01-01' meaning "up to but not including Jan 1",
-- it would include Jan 1 midnight.  The fragile pattern invites off-by-one.
-- ---------------------------------------------------------------------------
SELECT
    sp.TICKER,
    sp.DATE,
    sp.VALUE AS close_price
FROM snowflake_public_data_free.public_data_free.stock_price_timeseries sp
WHERE sp.VARIABLE = 'nasdaq_close'
  AND sp.DATE BETWEEN '2023-01-01'::TIMESTAMP AND '2024-01-01'::TIMESTAMP
  AND sp.TICKER = 'AAPL'
ORDER BY sp.DATE;


-- ---------------------------------------------------------------------------
-- Q4  [Correctness: Non-deterministic predicate]
-- Bug: Multiple variables can have the same VALUE on a given date.
-- ROW_NUMBER ordered by VALUE (not unique) produces unstable "top 1"
-- per geo_id — the winning variable is arbitrary across runs.
-- ---------------------------------------------------------------------------
WITH ranked AS (
    SELECT
        ts.GEO_ID,
        ts.VARIABLE_NAME,
        ts.VALUE,
        ts.DATE,
        ROW_NUMBER() OVER (
            PARTITION BY ts.GEO_ID
            ORDER BY ts.VALUE DESC          -- VALUE not unique → non-deterministic
        ) AS rn
    FROM snowflake_public_data_free.public_data_free.bureau_of_labor_statistics_employment_timeseries ts
    WHERE ts.DATE = '2023-06-01'
)
SELECT GEO_ID, VARIABLE_NAME, VALUE
FROM ranked
WHERE rn = 1;


-- ---------------------------------------------------------------------------
-- Q5  [Correctness: Division by zero]
-- Bug: Dividing current month's value by previous month's value without
-- guarding against zero.  If last month's CPI value happens to be 0
-- (e.g., missing/placeholder data), this produces a division-by-zero error.
-- ---------------------------------------------------------------------------
WITH monthly_cpi AS (
    SELECT
        ts.GEO_ID,
        ts.DATE,
        ts.VALUE AS cpi_value,
        LAG(ts.VALUE) OVER (PARTITION BY ts.GEO_ID ORDER BY ts.DATE) AS prev_cpi
    FROM snowflake_public_data_free.public_data_free.bureau_of_labor_statistics_price_timeseries ts
    WHERE ts.VARIABLE_NAME LIKE '%Consumer Price Index%'
      AND ts.GEO_ID = 'country/USA'
)
SELECT
    DATE,
    cpi_value,
    prev_cpi,
    (cpi_value - prev_cpi) / prev_cpi * 100 AS mom_pct_change   -- div by zero
FROM monthly_cpi
WHERE prev_cpi IS NOT NULL
ORDER BY DATE;


-- ---------------------------------------------------------------------------
-- Q6  [Correctness: UNION vs UNION ALL]
-- Bug: UNION deduplicates.  A geographic entity can legitimately appear in
-- both BLS employment AND BLS price data with the same geo_id and date.
-- UNION drops those valid dual-dataset rows, undercounting the combined
-- data points.
-- ---------------------------------------------------------------------------
SELECT GEO_ID, DATE, 'employment' AS source
FROM snowflake_public_data_free.public_data_free.bureau_of_labor_statistics_employment_timeseries
WHERE DATE >= '2023-01-01'
UNION                                          -- should be UNION ALL
SELECT GEO_ID, DATE, 'prices'
FROM snowflake_public_data_free.public_data_free.bureau_of_labor_statistics_price_timeseries
WHERE DATE >= '2023-01-01';


-- ---------------------------------------------------------------------------
-- Q7  [Correctness: NULL in aggregation]
-- Bug: COUNT(DISTINCT PRIMARY_TICKER) ignores NULL tickers.  Companies
-- without a ticker (private companies) are silently excluded from the
-- "unique tickers" count, making it look like there are fewer companies
-- than there actually are.
-- ---------------------------------------------------------------------------
SELECT
    ci.PRIMARY_EXCHANGE_NAME,
    COUNT(*)                          AS total_companies,
    COUNT(DISTINCT ci.PRIMARY_TICKER) AS unique_tickers    -- NULLs vanish
FROM snowflake_public_data_free.public_data_free.company_index ci
GROUP BY ci.PRIMARY_EXCHANGE_NAME
ORDER BY total_companies DESC;


-- ---------------------------------------------------------------------------
-- Q8  [Correctness: Wrong join / fanout]
-- Bug: Joining company_index to company_characteristics on COMPANY_ID alone
-- creates a 1:N fanout — each company has MANY characteristics rows (EIN,
-- address, industry, etc.).  This inflates the stock price rows, making
-- AVG(sp.VALUE) wrong (each price row duplicated per characteristic).
-- ---------------------------------------------------------------------------
SELECT
    ci.COMPANY_NAME,
    cc.RELATIONSHIP_TYPE,
    AVG(sp.VALUE) AS avg_close_price         -- inflated by fanout
FROM snowflake_public_data_free.public_data_free.stock_price_timeseries sp
JOIN snowflake_public_data_free.public_data_free.company_index          ci
  ON sp.TICKER = ci.PRIMARY_TICKER
JOIN snowflake_public_data_free.public_data_free.company_characteristics cc
  ON ci.COMPANY_ID = cc.COMPANY_ID           -- 1:N fanout!
WHERE sp.VARIABLE = 'nasdaq_close'
  AND sp.TICKER = 'AAPL'
  AND sp.DATE >= '2023-01-01'
GROUP BY ci.COMPANY_NAME, cc.RELATIONSHIP_TYPE
ORDER BY avg_close_price DESC;


-- =============================================================================
-- PERFORMANCE TESTS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Q9  [Performance: Non-selective predicate / function on filter column]
-- Bug: EXTRACT(YEAR FROM DATE) prevents the query engine from doing
-- partition pruning on the DATE column.  A direct range predicate like
-- DATE BETWEEN '2023-01-01' AND '2023-12-31' would be far more efficient.
-- ---------------------------------------------------------------------------
SELECT
    sp.TICKER,
    EXTRACT(MONTH FROM sp.DATE) AS trade_month,
    AVG(sp.VALUE)               AS avg_price
FROM snowflake_public_data_free.public_data_free.stock_price_timeseries sp
WHERE sp.VARIABLE = 'nasdaq_close'
  AND EXTRACT(YEAR FROM sp.DATE) = 2023        -- function defeats pruning
GROUP BY sp.TICKER, EXTRACT(MONTH FROM sp.DATE)
ORDER BY sp.TICKER, trade_month;


-- ---------------------------------------------------------------------------
-- Q10  [Performance: Repeated scans]
-- Bug: stock_price_timeseries is scanned three times — once per CTE —
-- to get open, close, and volume.  A single scan with conditional
-- aggregation (e.g., MAX(CASE WHEN VARIABLE='nasdaq_close' THEN VALUE END))
-- would be ~3× more efficient.
-- ---------------------------------------------------------------------------
WITH closes AS (
    SELECT TICKER, DATE, VALUE AS close_price
    FROM snowflake_public_data_free.public_data_free.stock_price_timeseries
    WHERE VARIABLE = 'nasdaq_close' AND DATE >= '2023-01-01'
),
opens AS (
    SELECT TICKER, DATE, VALUE AS open_price
    FROM snowflake_public_data_free.public_data_free.stock_price_timeseries
    WHERE VARIABLE = 'nasdaq_open' AND DATE >= '2023-01-01'
),
volumes AS (
    SELECT TICKER, DATE, VALUE AS volume
    FROM snowflake_public_data_free.public_data_free.stock_price_timeseries
    WHERE VARIABLE = 'nasdaq_volume' AND DATE >= '2023-01-01'
)
SELECT
    c.TICKER,
    c.DATE,
    o.open_price,
    c.close_price,
    v.volume,
    c.close_price - o.open_price AS daily_change
FROM closes c
JOIN opens   o ON c.TICKER = o.TICKER AND c.DATE = o.DATE
JOIN volumes v ON c.TICKER = v.TICKER AND c.DATE = v.DATE
ORDER BY c.TICKER, c.DATE;


-- ---------------------------------------------------------------------------
-- Q11  [Performance: Unnecessary sort]
-- Bug: The inner subquery sorts by GEO_ID + DATE, but the outer query
-- re-sorts by total_value DESC.  The inner ORDER BY is wasted work.
-- ---------------------------------------------------------------------------
SELECT
    GEO_ID,
    geo_name,
    total_value
FROM (
    SELECT
        ts.GEO_ID,
        g.GEO_NAME,
        SUM(ts.VALUE) AS total_value
    FROM snowflake_public_data_free.public_data_free.bureau_of_labor_statistics_employment_timeseries ts
    JOIN snowflake_public_data_free.public_data_free.geography_index g ON ts.GEO_ID = g.GEO_ID
    WHERE ts.DATE >= '2023-01-01'
      AND ts.VARIABLE_NAME LIKE '%Unemployment Rate%'
    GROUP BY ts.GEO_ID, g.GEO_NAME
    ORDER BY ts.GEO_ID, g.GEO_NAME            -- useless inner sort
) sub
ORDER BY total_value DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- Q12  [Performance: Cartesian product]
-- Bug: Comma-join between stock_price_timeseries and company_index with no
-- join predicate linking TICKER.  Every stock price row is paired with
-- every company — a massive cross product.
-- ---------------------------------------------------------------------------
SELECT
    ci.COMPANY_NAME,
    sp.DATE,
    sp.VALUE
FROM snowflake_public_data_free.public_data_free.stock_price_timeseries sp,
     snowflake_public_data_free.public_data_free.company_index          ci   -- no join predicate!
WHERE sp.VARIABLE = 'nasdaq_close'
  AND sp.DATE = '2023-12-29'
LIMIT 100;


-- ---------------------------------------------------------------------------
-- Q13  [Performance: Missing date predicate / full scan]
-- Bug: No filter on DATE — scans the entire stock price history for all
-- tickers.  Even a 1-year filter would dramatically reduce I/O.
-- ---------------------------------------------------------------------------
SELECT
    sp.TICKER,
    ci.COMPANY_NAME,
    ci.PRIMARY_EXCHANGE_NAME,
    AVG(sp.VALUE)  AS avg_close,
    MAX(sp.VALUE)  AS max_close,
    MIN(sp.VALUE)  AS min_close
FROM snowflake_public_data_free.public_data_free.stock_price_timeseries sp
JOIN snowflake_public_data_free.public_data_free.company_index          ci
  ON sp.TICKER = ci.PRIMARY_TICKER
WHERE sp.VARIABLE = 'nasdaq_close'
  -- no date filter → scans all history
GROUP BY sp.TICKER, ci.COMPANY_NAME, ci.PRIMARY_EXCHANGE_NAME
ORDER BY avg_close DESC
LIMIT 50;


-- ---------------------------------------------------------------------------
-- Q14  [Performance: Correlated subquery]
-- Bug: For each ticker, a correlated subquery rescans stock_price_timeseries
-- to find the global max close.  A window function or a pre-computed CTE
-- would scan the table once instead of once per ticker.
-- ---------------------------------------------------------------------------
SELECT
    sp.TICKER,
    sp.DATE,
    sp.VALUE AS close_price,
    (SELECT MAX(sp2.VALUE)
     FROM snowflake_public_data_free.public_data_free.stock_price_timeseries sp2
     WHERE sp2.VARIABLE = 'nasdaq_close'
       AND sp2.DATE >= '2023-01-01'
    ) AS global_max_close
FROM snowflake_public_data_free.public_data_free.stock_price_timeseries sp
WHERE sp.VARIABLE = 'nasdaq_close'
  AND sp.DATE >= '2023-01-01'
ORDER BY sp.VALUE DESC
LIMIT 20;


-- =============================================================================
-- COMPLEXITY / EXPLANATION TESTS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Q15  [Complexity: CTEs + window functions]
-- Correct query — tests the "explain what this computes" capability.
-- For each US state, compute the month-over-month change in unemployment
-- rate, then rank states by the largest single-month spike in 2023.
-- ---------------------------------------------------------------------------
WITH state_unemployment AS (
    SELECT
        g.GEO_NAME        AS state_name,
        ts.DATE,
        ts.VALUE           AS unemployment_rate
    FROM snowflake_public_data_free.public_data_free.bureau_of_labor_statistics_employment_timeseries ts
    JOIN snowflake_public_data_free.public_data_free.geography_index g
      ON ts.GEO_ID = g.GEO_ID
    WHERE ts.VARIABLE_NAME = 'Unemployment Rate, Seasonally Adjusted'
      AND g.LEVEL = 'State'
      AND ts.DATE BETWEEN '2023-01-01' AND '2023-12-31'
),
with_change AS (
    SELECT
        state_name,
        DATE,
        unemployment_rate,
        unemployment_rate - LAG(unemployment_rate) OVER (
            PARTITION BY state_name ORDER BY DATE
        ) AS mom_change
    FROM state_unemployment
)
SELECT
    state_name,
    DATE               AS spike_month,
    unemployment_rate,
    mom_change,
    RANK() OVER (ORDER BY mom_change DESC) AS spike_rank
FROM with_change
WHERE mom_change IS NOT NULL
ORDER BY mom_change DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- Q16  [Complexity: Multi-join with EAV pivot]
-- Correct query — tests the "explain what this computes" capability.
-- Pivot stock price data from EAV format into a wide table with columns
-- for open, close, high, low, volume per ticker per day. Then compute
-- the daily return and 5-day moving average return for tech stocks.
-- ---------------------------------------------------------------------------
WITH daily_ohlcv AS (
    SELECT
        sp.TICKER,
        sp.DATE,
        MAX(CASE WHEN sp.VARIABLE = 'nasdaq_open'   THEN sp.VALUE END) AS open_price,
        MAX(CASE WHEN sp.VARIABLE = 'nasdaq_close'  THEN sp.VALUE END) AS close_price,
        MAX(CASE WHEN sp.VARIABLE = 'nasdaq_high'   THEN sp.VALUE END) AS high_price,
        MAX(CASE WHEN sp.VARIABLE = 'nasdaq_low'    THEN sp.VALUE END) AS low_price,
        MAX(CASE WHEN sp.VARIABLE = 'nasdaq_volume' THEN sp.VALUE END) AS volume
    FROM snowflake_public_data_free.public_data_free.stock_price_timeseries sp
    WHERE sp.DATE BETWEEN '2023-01-01' AND '2023-12-31'
      AND sp.TICKER IN ('AAPL', 'MSFT', 'GOOGL', 'AMZN', 'META')
    GROUP BY sp.TICKER, sp.DATE
),
with_returns AS (
    SELECT
        TICKER,
        DATE,
        open_price,
        close_price,
        volume,
        (close_price - LAG(close_price) OVER (PARTITION BY TICKER ORDER BY DATE))
            / NULLIF(LAG(close_price) OVER (PARTITION BY TICKER ORDER BY DATE), 0)
            * 100 AS daily_return_pct,
        AVG(close_price) OVER (
            PARTITION BY TICKER
            ORDER BY DATE
            ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
        ) AS moving_avg_5d
    FROM daily_ohlcv
)
SELECT
    ci.COMPANY_NAME,
    wr.TICKER,
    wr.DATE,
    wr.close_price,
    ROUND(wr.daily_return_pct, 2)  AS daily_return_pct,
    ROUND(wr.moving_avg_5d, 2)     AS ma_5d,
    wr.volume
FROM with_returns wr
JOIN snowflake_public_data_free.public_data_free.company_index ci
  ON wr.TICKER = ci.PRIMARY_TICKER
ORDER BY wr.TICKER, wr.DATE;


-- =============================================================================
-- FALSE-POSITIVE TESTS
-- These queries look suspicious but are correct. The skill should produce
-- no correctness findings (performance observations are acceptable).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Q17  [False-positive: SELECT * where all columns are needed]
-- NOT a bug: The CTE uses SELECT * from stock_price_timeseries, but the
-- outer query references TICKER, DATE, VARIABLE, and VALUE — which are
-- all the meaningful columns.  Flagging "SELECT * is wasteful" would be
-- a false positive.
-- ---------------------------------------------------------------------------
WITH raw_prices AS (
    SELECT *
    FROM snowflake_public_data_free.public_data_free.stock_price_timeseries
    WHERE TICKER = 'AAPL'
      AND DATE >= '2023-01-01'
)
SELECT
    rp.TICKER,
    rp.DATE,
    rp.VARIABLE,
    rp.VALUE
FROM raw_prices rp
WHERE rp.VARIABLE IN ('nasdaq_open', 'nasdaq_close', 'nasdaq_volume')
ORDER BY rp.DATE, rp.VARIABLE;


-- ---------------------------------------------------------------------------
-- Q18  [False-positive: UNION dedup is intentional]
-- NOT a bug: The query finds geographic entities that appear in EITHER
-- employment OR price datasets — a set union.  UNION ALL would produce
-- duplicates for entities in both datasets, which is wrong for "which
-- entities have any BLS coverage?" use case.
-- ---------------------------------------------------------------------------
SELECT GEO_ID, 'employment' AS dataset
FROM snowflake_public_data_free.public_data_free.bureau_of_labor_statistics_employment_timeseries
WHERE DATE = '2023-06-01'
GROUP BY GEO_ID
UNION   -- intentional: want distinct geo_ids across both datasets
SELECT GEO_ID, 'prices' AS dataset
FROM snowflake_public_data_free.public_data_free.bureau_of_labor_statistics_price_timeseries
WHERE DATE = '2023-06-01'
GROUP BY GEO_ID;


-- ---------------------------------------------------------------------------
-- Q19  [False-positive: NOT IN with non-nullable column]
-- NOT a bug: GEO_ID in geography_index is the PK and is NOT NULL.
-- The NOT IN subquery returns GEO_IDs at the 'State' level, which are
-- always non-null.  The classic "NOT IN with NULLs" trap does not apply.
-- ---------------------------------------------------------------------------
SELECT
    ts.GEO_ID,
    SUM(ts.VALUE) AS total_value
FROM snowflake_public_data_free.public_data_free.bureau_of_labor_statistics_employment_timeseries ts
WHERE ts.DATE >= '2023-01-01'
  AND ts.VARIABLE_NAME LIKE '%Unemployment Rate%'
  AND ts.GEO_ID NOT IN (
      SELECT g.GEO_ID
      FROM snowflake_public_data_free.public_data_free.geography_index g
      WHERE g.LEVEL = 'State'
  )
GROUP BY ts.GEO_ID
ORDER BY total_value DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- Q20  [False-positive: COUNT(column) intentionally excludes NULLs]
-- NOT a bug: The query counts total companies vs companies with a ticker.
-- COUNT(PRIMARY_TICKER) intentionally excludes NULLs to count only publicly
-- traded companies.  The difference reveals private companies.  Suggesting
-- COUNT(*) would destroy the metric.
-- ---------------------------------------------------------------------------
SELECT
    ci.PRIMARY_EXCHANGE_NAME,
    COUNT(*)                        AS total_companies,
    COUNT(ci.PRIMARY_TICKER)        AS public_companies,
    COUNT(*) - COUNT(ci.PRIMARY_TICKER) AS private_companies
FROM snowflake_public_data_free.public_data_free.company_index ci
GROUP BY ci.PRIMARY_EXCHANGE_NAME
ORDER BY private_companies DESC;


-- =============================================================================
-- BAD-REWRITE-TRAP TESTS
-- These queries have a real issue, but the "obvious" fix changes semantics.
-- The skill should either not suggest the naive fix, or should suggest a
-- correct alternative that preserves the query's intent.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Q21  [Bad-rewrite-trap: LEFT JOIN that looks like INNER but isn't]
-- Issue: The WHERE clause filters on cc.RELATIONSHIP_TYPE (a right-side
-- column), which normally converts a LEFT JOIN to an INNER JOIN.  The naive
-- fix is "change to INNER JOIN".  But the OR branch (cc.RELATIONSHIP_TYPE
-- IS NULL) deliberately keeps companies with no characteristics rows — it's
-- how the query distinguishes "has industry data" from "no data available".
-- Changing to INNER JOIN would drop all companies without characteristics.
-- ---------------------------------------------------------------------------
SELECT
    ci.COMPANY_NAME,
    ci.PRIMARY_TICKER,
    cc.RELATIONSHIP_TYPE,
    CASE
        WHEN cc.RELATIONSHIP_TYPE IS NULL    THEN 'no_data'
        WHEN cc.RELATIONSHIP_TYPE = 'NAICS'  THEN 'has_industry'
        ELSE 'other'
    END AS data_status
FROM snowflake_public_data_free.public_data_free.company_index ci
LEFT JOIN snowflake_public_data_free.public_data_free.company_characteristics cc
  ON ci.COMPANY_ID = cc.COMPANY_ID
WHERE (cc.RELATIONSHIP_TYPE = 'NAICS' OR cc.RELATIONSHIP_TYPE IS NULL)
  AND ci.PRIMARY_TICKER IS NOT NULL
ORDER BY ci.COMPANY_NAME
LIMIT 50;


-- ---------------------------------------------------------------------------
-- Q22  [Bad-rewrite-trap: Non-aggregated column that is functionally dependent]
-- Issue: GEO_NAME is in SELECT but not in GROUP BY.  Snowflake allows this.
-- The naive fix is "add GEO_NAME to GROUP BY" or "wrap in MAX()".  But
-- GEO_ID → GEO_NAME is a 1:1 functional dependency (each geo_id has
-- exactly one name).  The correct fix is ANY_VALUE(g.GEO_NAME), which
-- documents the intent.  Adding it to GROUP BY is harmless here but
-- MAX() implies ordering semantics that don't apply to names.
-- ---------------------------------------------------------------------------
SELECT
    ts.GEO_ID,
    g.GEO_NAME,                                  -- not in GROUP BY
    SUM(ts.VALUE)  AS total_value,
    COUNT(*)       AS observation_count
FROM snowflake_public_data_free.public_data_free.bureau_of_labor_statistics_employment_timeseries ts
JOIN snowflake_public_data_free.public_data_free.geography_index g ON ts.GEO_ID = g.GEO_ID
WHERE ts.DATE >= '2023-01-01'
  AND ts.VARIABLE_NAME LIKE '%Unemployment Rate%'
  AND g.LEVEL = 'State'
GROUP BY ts.GEO_ID
ORDER BY total_value DESC;


-- ---------------------------------------------------------------------------
-- Q23  [Bad-rewrite-trap: Correlated subquery where JOIN introduces fanout]
-- Issue: The correlated subquery computes the latest close price per ticker.
-- The naive fix is "rewrite as JOIN to stock_price_timeseries".  But a plain
-- JOIN would create a 1:N fanout (many rows per ticker in stock_price),
-- inflating the company_index rows.  The correct rewrite needs a
-- pre-aggregated CTE or QUALIFY with ROW_NUMBER, not a bare JOIN.
-- ---------------------------------------------------------------------------
SELECT
    ci.COMPANY_NAME,
    ci.PRIMARY_TICKER,
    ci.PRIMARY_EXCHANGE_NAME,
    (SELECT MAX(sp.VALUE)
     FROM snowflake_public_data_free.public_data_free.stock_price_timeseries sp
     WHERE sp.TICKER = ci.PRIMARY_TICKER
       AND sp.VARIABLE = 'nasdaq_close'
       AND sp.DATE >= '2023-01-01'
    ) AS max_close_2023
FROM snowflake_public_data_free.public_data_free.company_index ci
WHERE ci.PRIMARY_TICKER IS NOT NULL
ORDER BY max_close_2023 DESC NULLS LAST
LIMIT 20;


-- ---------------------------------------------------------------------------
-- Q24  [Bad-rewrite-trap: DISTINCT masking intentional many-to-many]
-- Issue: DISTINCT is applied after joining employment timeseries to geography
-- and attributes, where one GEO_ID can have multiple VARIABLE_NAMEs and one
-- VARIABLE_NAME can appear in multiple REPORTs.  The naive fix is "remove
-- DISTINCT and fix the join".  But the business question is "which unique
-- (state, report) pairs have unemployment data?" — a set-of-pairs question.
-- DISTINCT is the correct approach; removing it returns millions of rows.
-- ---------------------------------------------------------------------------
SELECT DISTINCT
    g.GEO_NAME   AS state_name,
    a.REPORT,
    a.FREQUENCY
FROM snowflake_public_data_free.public_data_free.bureau_of_labor_statistics_employment_timeseries ts
JOIN snowflake_public_data_free.public_data_free.geography_index g
  ON ts.GEO_ID = g.GEO_ID
JOIN snowflake_public_data_free.public_data_free.bureau_of_labor_statistics_employment_attributes a
  ON ts.VARIABLE_NAME = a.VARIABLE_NAME
WHERE g.LEVEL = 'State'
  AND ts.DATE >= '2023-01-01'
ORDER BY state_name, a.REPORT;
