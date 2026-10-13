--------------------------------------------------------------------------------
-- Query-Intel Test Suite: TPC-DS
-- Source: SNOWFLAKE_SAMPLE_DATA.TPCDS_SF10TCL
--
-- Each query is tagged with the category it exercises.
-- Queries are intentionally flawed (for correctness / performance tests)
-- or intentionally complex (for explanation tests).
-- NOTE: SF10TCL is very large. Add LIMIT or date filters before executing.
--------------------------------------------------------------------------------

-- =============================================================================
-- CORRECTNESS TESTS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Q1  [Correctness: NULL comparison]
-- Bug: WHERE ss_customer_sk != -1 silently drops rows where ss_customer_sk
-- IS NULL.  A correct version would add: OR ss_customer_sk IS NULL.
-- ---------------------------------------------------------------------------
SELECT
    s.s_store_name,
    COUNT(*)          AS txn_count,
    SUM(ss_net_paid)  AS total_paid
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales  ss
JOIN snowflake_sample_data.tpcds_sf10tcl.store         s
  ON ss.ss_store_sk = s.s_store_sk
WHERE ss.ss_customer_sk != -1            -- misses NULLs
GROUP BY s.s_store_name
ORDER BY total_paid DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- Q2  [Correctness: AND/OR precedence]
-- Bug: The intent is "(promo via email OR promo via catalog) AND year 2002",
-- but without parentheses AND binds tighter, giving:
--   promo email  OR  (promo catalog AND year=2002)
-- which returns all email-promo rows regardless of year.
-- ---------------------------------------------------------------------------
SELECT
    i.i_category,
    SUM(ss.ss_ext_sales_price) AS promo_revenue
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales  ss
JOIN snowflake_sample_data.tpcds_sf10tcl.date_dim      d  ON ss.ss_sold_date_sk = d.d_date_sk
JOIN snowflake_sample_data.tpcds_sf10tcl.item           i  ON ss.ss_item_sk      = i.i_item_sk
JOIN snowflake_sample_data.tpcds_sf10tcl.promotion      p  ON ss.ss_promo_sk     = p.p_promo_sk
WHERE p.p_channel_email = 'Y' OR p.p_channel_catalog = 'Y' AND d.d_year = 2002
GROUP BY i.i_category
ORDER BY promo_revenue DESC;


-- ---------------------------------------------------------------------------
-- Q3  [Correctness: Timestamp / date predicate trap]
-- Bug: d_date is a DATE column. Comparing with a timestamp string that
-- includes a time component means '2002-01-15 00:00:00' works but
-- '2002-01-15 12:30:00' wouldn't match any row. Here, the BETWEEN
-- with timestamps is misleading — it accidentally works because d_date
-- has no time component, but the pattern is fragile. The real trap:
-- the end bound should be '2002-03-31' not '2002-04-01' if the intent
-- is Q1 only, because BETWEEN on DATE includes the end date.
-- ---------------------------------------------------------------------------
SELECT
    d.d_date,
    SUM(ss.ss_net_paid) AS daily_revenue
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss
JOIN snowflake_sample_data.tpcds_sf10tcl.date_dim     d ON ss.ss_sold_date_sk = d.d_date_sk
WHERE d.d_date BETWEEN '2002-01-01'::TIMESTAMP AND '2002-04-01'::TIMESTAMP
GROUP BY d.d_date
ORDER BY d.d_date;


-- ---------------------------------------------------------------------------
-- Q4  [Correctness: Non-deterministic predicate]
-- Bug: ROW_NUMBER() ordered by ss_net_paid, but many rows share the same
-- net_paid value.  The "top 1" per store is arbitrary and unstable across runs.
-- ---------------------------------------------------------------------------
WITH ranked AS (
    SELECT
        ss.ss_store_sk,
        ss.ss_item_sk,
        ss.ss_net_paid,
        ROW_NUMBER() OVER (
            PARTITION BY ss.ss_store_sk
            ORDER BY ss.ss_net_paid DESC      -- not unique → non-deterministic
        ) AS rn
    FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss
    WHERE ss.ss_sold_date_sk BETWEEN 2452275 AND 2452639   -- year 2002 approx
)
SELECT ss_store_sk, ss_item_sk, ss_net_paid
FROM ranked
WHERE rn = 1;


-- ---------------------------------------------------------------------------
-- Q5  [Correctness: Division by zero]
-- Bug: ss_quantity can be 0 or NULL; dividing without NULLIF risks error
-- or incorrect NULL propagation.
-- ---------------------------------------------------------------------------
SELECT
    i.i_category,
    i.i_brand,
    AVG(ss.ss_net_paid / ss.ss_quantity) AS avg_unit_price     -- div by zero
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss
JOIN snowflake_sample_data.tpcds_sf10tcl.item         i ON ss.ss_item_sk = i.i_item_sk
GROUP BY i.i_category, i.i_brand
ORDER BY avg_unit_price DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- Q6  [Correctness: UNION vs UNION ALL]
-- Bug: UNION deduplicates, but a customer can legitimately buy the same item
-- via store AND web.  UNION removes those valid dual-channel rows, under-
-- counting cross-channel customers.
-- ---------------------------------------------------------------------------
SELECT ss_customer_sk AS customer_sk, ss_item_sk AS item_sk, 'store' AS channel
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales
WHERE ss_sold_date_sk BETWEEN 2452275 AND 2452639
UNION                                  -- should be UNION ALL
SELECT ws_bill_customer_sk, ws_item_sk, 'web'
FROM snowflake_sample_data.tpcds_sf10tcl.web_sales
WHERE ws_sold_date_sk BETWEEN 2452275 AND 2452639;


-- ---------------------------------------------------------------------------
-- Q7  [Correctness: NULL in aggregation]
-- Bug: COUNT(DISTINCT ss_customer_sk) silently ignores NULLs.  If the intent
-- is "transactions with no customer" + "distinct customers", the NULL bucket
-- is lost.
-- ---------------------------------------------------------------------------
SELECT
    s.s_state,
    COUNT(*)                            AS total_txns,
    COUNT(DISTINCT ss.ss_customer_sk)   AS unique_customers   -- NULLs vanish
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss
JOIN snowflake_sample_data.tpcds_sf10tcl.store        s ON ss.ss_store_sk = s.s_store_sk
GROUP BY s.s_state
ORDER BY unique_customers DESC;


-- ---------------------------------------------------------------------------
-- Q8  [Correctness: Wrong join / fanout]
-- Bug: Joining store_sales to store_returns on item_sk alone creates a
-- many-to-many fanout (one sale can match many returns of the same item
-- from different tickets).  This inflates both the sales and return sums.
-- The correct join needs (item_sk, ticket_number) = (item_sk, ticket_number).
-- ---------------------------------------------------------------------------
SELECT
    s.s_store_name,
    SUM(ss.ss_net_paid)       AS gross_revenue,
    SUM(sr.sr_return_amt)     AS total_returns,
    SUM(ss.ss_net_paid) - SUM(sr.sr_return_amt) AS net_revenue
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales   ss
JOIN snowflake_sample_data.tpcds_sf10tcl.store_returns sr
  ON ss.ss_item_sk = sr.sr_item_sk                        -- missing sr_ticket_number match
JOIN snowflake_sample_data.tpcds_sf10tcl.store          s
  ON ss.ss_store_sk = s.s_store_sk
WHERE ss.ss_sold_date_sk BETWEEN 2452275 AND 2452639
GROUP BY s.s_store_name
ORDER BY net_revenue DESC
LIMIT 10;


-- =============================================================================
-- PERFORMANCE TESTS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Q9  [Performance: Non-selective predicate / function on filter column]
-- Bug: Wrapping d_date in EXTRACT() prevents partition pruning on d_date_sk.
-- Should join to date_dim and filter on d_year instead, or filter d_date
-- directly with a range.
-- ---------------------------------------------------------------------------
SELECT
    EXTRACT(MONTH FROM d.d_date) AS sale_month,
    SUM(ss.ss_ext_sales_price)   AS monthly_revenue
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss
JOIN snowflake_sample_data.tpcds_sf10tcl.date_dim     d ON ss.ss_sold_date_sk = d.d_date_sk
WHERE EXTRACT(YEAR FROM d.d_date) = 2002                   -- function defeats pruning
GROUP BY EXTRACT(MONTH FROM d.d_date)
ORDER BY sale_month;


-- ---------------------------------------------------------------------------
-- Q10  [Performance: Repeated scans]
-- Bug: store_sales is scanned twice — once for the totals CTE, once for the
-- returns CTE via store_returns that also joins back to store_sales.  A single
-- pass with conditional aggregation would halve I/O.
-- ---------------------------------------------------------------------------
WITH store_totals AS (
    SELECT ss_store_sk, SUM(ss_net_paid) AS total_sales
    FROM snowflake_sample_data.tpcds_sf10tcl.store_sales
    WHERE ss_sold_date_sk BETWEEN 2452275 AND 2452639
    GROUP BY ss_store_sk
),
store_return_totals AS (
    SELECT ss.ss_store_sk, SUM(sr.sr_return_amt) AS total_returns
    FROM snowflake_sample_data.tpcds_sf10tcl.store_sales   ss
    JOIN snowflake_sample_data.tpcds_sf10tcl.store_returns sr
      ON ss.ss_item_sk = sr.sr_item_sk
     AND ss.ss_ticket_number = sr.sr_ticket_number
    WHERE ss.ss_sold_date_sk BETWEEN 2452275 AND 2452639
    GROUP BY ss.ss_store_sk
)
SELECT
    s.s_store_name,
    st.total_sales,
    srt.total_returns,
    st.total_sales - COALESCE(srt.total_returns, 0) AS net_sales
FROM store_totals st
LEFT JOIN store_return_totals srt ON st.ss_store_sk = srt.ss_store_sk
JOIN snowflake_sample_data.tpcds_sf10tcl.store s ON st.ss_store_sk = s.s_store_sk
ORDER BY net_sales DESC;


-- ---------------------------------------------------------------------------
-- Q11  [Performance: Unnecessary sort]
-- Bug: The inner subquery has ORDER BY which is pointless — the outer query
-- re-sorts by a different column anyway.
-- ---------------------------------------------------------------------------
SELECT
    i_category,
    i_brand,
    total_revenue
FROM (
    SELECT
        i.i_category,
        i.i_brand,
        SUM(ss.ss_ext_sales_price) AS total_revenue
    FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss
    JOIN snowflake_sample_data.tpcds_sf10tcl.item         i ON ss.ss_item_sk = i.i_item_sk
    JOIN snowflake_sample_data.tpcds_sf10tcl.date_dim     d ON ss.ss_sold_date_sk = d.d_date_sk
    WHERE d.d_year = 2002
    GROUP BY i.i_category, i.i_brand
    ORDER BY i.i_category, i.i_brand              -- useless inner sort
) sub
ORDER BY total_revenue DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- Q12  [Performance: Cartesian product]
-- Bug: Comma-join between store_sales and item with no WHERE join condition
-- linking them.  The intent was probably ss.ss_item_sk = i.i_item_sk but it
-- was forgotten.  On SF10TCL this is a 28B × 402K catastrophe.
-- ---------------------------------------------------------------------------
SELECT
    i.i_category,
    COUNT(*)             AS pair_count,
    SUM(ss.ss_net_paid)  AS total_paid
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss,
     snowflake_sample_data.tpcds_sf10tcl.item        i     -- no join predicate!
WHERE ss.ss_sold_date_sk BETWEEN 2452275 AND 2452639
  AND i.i_category = 'Electronics'
GROUP BY i.i_category
LIMIT 10;


-- ---------------------------------------------------------------------------
-- Q13  [Performance: Missing date predicate / full scan]
-- Bug: No filter on ss_sold_date_sk or any date dimension — scans the entire
-- 28B-row store_sales table.  Adding even a year filter would cut I/O ~20×.
-- ---------------------------------------------------------------------------
SELECT
    ca.ca_state,
    cd.cd_gender,
    cd.cd_marital_status,
    COUNT(*)              AS customer_txns,
    SUM(ss.ss_net_paid)   AS total_paid
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales          ss
JOIN snowflake_sample_data.tpcds_sf10tcl.customer              c  ON ss.ss_customer_sk   = c.c_customer_sk
JOIN snowflake_sample_data.tpcds_sf10tcl.customer_address     ca ON c.c_current_addr_sk  = ca.ca_address_sk
JOIN snowflake_sample_data.tpcds_sf10tcl.customer_demographics cd ON c.c_current_cdemo_sk = cd.cd_demo_sk
GROUP BY ca.ca_state, cd.cd_gender, cd.cd_marital_status
ORDER BY total_paid DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- Q14  [Performance: Correlated subquery]
-- Bug: For each store, a correlated subquery rescans store_sales to compute
-- the global average.  A window function or a single pre-aggregated CTE
-- would be far cheaper.
-- ---------------------------------------------------------------------------
SELECT
    s.s_store_name,
    SUM(ss.ss_net_paid) AS store_revenue,
    (SELECT AVG(ss2.ss_net_paid)
     FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss2
     WHERE ss2.ss_sold_date_sk BETWEEN 2452275 AND 2452639
    ) AS global_avg_sale
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss
JOIN snowflake_sample_data.tpcds_sf10tcl.store        s ON ss.ss_store_sk = s.s_store_sk
WHERE ss.ss_sold_date_sk BETWEEN 2452275 AND 2452639
GROUP BY s.s_store_name
ORDER BY store_revenue DESC;


-- =============================================================================
-- COMPLEXITY / EXPLANATION TESTS
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Q15  [Complexity: CTEs + window functions]
-- Correct query — tests the "explain what this computes" capability.
-- Running total of monthly revenue per store, with month-over-month change.
-- ---------------------------------------------------------------------------
WITH monthly_sales AS (
    SELECT
        s.s_store_name,
        d.d_year,
        d.d_moy                         AS month_num,
        SUM(ss.ss_ext_sales_price)       AS monthly_revenue
    FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss
    JOIN snowflake_sample_data.tpcds_sf10tcl.date_dim     d ON ss.ss_sold_date_sk = d.d_date_sk
    JOIN snowflake_sample_data.tpcds_sf10tcl.store        s ON ss.ss_store_sk      = s.s_store_sk
    WHERE d.d_year = 2002
    GROUP BY s.s_store_name, d.d_year, d.d_moy
)
SELECT
    s_store_name,
    month_num,
    monthly_revenue,
    SUM(monthly_revenue) OVER (
        PARTITION BY s_store_name
        ORDER BY month_num
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total,
    monthly_revenue - LAG(monthly_revenue) OVER (
        PARTITION BY s_store_name ORDER BY month_num
    ) AS mom_change
FROM monthly_sales
ORDER BY s_store_name, month_num;


-- ---------------------------------------------------------------------------
-- Q16  [Complexity: Multi-join star schema]
-- Correct query — tests the "explain what this computes" capability.
-- Cross-channel revenue comparison: for each item category, compare store vs
-- web vs catalog revenue in 2002, plus return rates by channel.
-- ---------------------------------------------------------------------------
WITH store_rev AS (
    SELECT i.i_category, SUM(ss.ss_ext_sales_price) AS revenue, COUNT(*) AS txns
    FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss
    JOIN snowflake_sample_data.tpcds_sf10tcl.item         i ON ss.ss_item_sk      = i.i_item_sk
    JOIN snowflake_sample_data.tpcds_sf10tcl.date_dim     d ON ss.ss_sold_date_sk = d.d_date_sk
    WHERE d.d_year = 2002
    GROUP BY i.i_category
),
web_rev AS (
    SELECT i.i_category, SUM(ws.ws_ext_sales_price) AS revenue, COUNT(*) AS txns
    FROM snowflake_sample_data.tpcds_sf10tcl.web_sales   ws
    JOIN snowflake_sample_data.tpcds_sf10tcl.item         i ON ws.ws_item_sk      = i.i_item_sk
    JOIN snowflake_sample_data.tpcds_sf10tcl.date_dim     d ON ws.ws_sold_date_sk = d.d_date_sk
    WHERE d.d_year = 2002
    GROUP BY i.i_category
),
catalog_rev AS (
    SELECT i.i_category, SUM(cs.cs_ext_sales_price) AS revenue, COUNT(*) AS txns
    FROM snowflake_sample_data.tpcds_sf10tcl.catalog_sales cs
    JOIN snowflake_sample_data.tpcds_sf10tcl.item           i ON cs.cs_item_sk      = i.i_item_sk
    JOIN snowflake_sample_data.tpcds_sf10tcl.date_dim       d ON cs.cs_sold_date_sk = d.d_date_sk
    WHERE d.d_year = 2002
    GROUP BY i.i_category
)
SELECT
    COALESCE(sr.i_category, wr.i_category, cr.i_category) AS category,
    sr.revenue  AS store_revenue,
    sr.txns     AS store_txns,
    wr.revenue  AS web_revenue,
    wr.txns     AS web_txns,
    cr.revenue  AS catalog_revenue,
    cr.txns     AS catalog_txns,
    sr.revenue + wr.revenue + cr.revenue AS total_revenue
FROM store_rev sr
FULL OUTER JOIN web_rev     wr ON sr.i_category = wr.i_category
FULL OUTER JOIN catalog_rev cr ON sr.i_category = cr.i_category
ORDER BY total_revenue DESC;


-- =============================================================================
-- FALSE-POSITIVE TESTS
-- These queries look suspicious but are correct. The skill should produce
-- no correctness findings (performance observations are acceptable).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Q17  [False-positive: SELECT * where all columns are needed]
-- NOT a bug: The inner query uses SELECT *, but the outer query references
-- every column from store_sales that it needs via explicit aliases.  This is
-- a common pattern in staging CTEs.  Flagging "SELECT * is wasteful" would
-- be a false positive — all columns are consumed downstream.
-- ---------------------------------------------------------------------------
WITH raw_sales AS (
    SELECT *
    FROM snowflake_sample_data.tpcds_sf10tcl.store_sales
    WHERE ss_sold_date_sk BETWEEN 2452275 AND 2452639
)
SELECT
    rs.ss_store_sk,
    rs.ss_customer_sk,
    rs.ss_item_sk,
    rs.ss_ticket_number,
    rs.ss_quantity,
    rs.ss_net_paid,
    rs.ss_ext_sales_price,
    rs.ss_net_profit,
    rs.ss_sold_date_sk
FROM raw_sales rs
WHERE rs.ss_net_paid > 100
ORDER BY rs.ss_net_paid DESC
LIMIT 50;


-- ---------------------------------------------------------------------------
-- Q18  [False-positive: UNION dedup is intentional]
-- NOT a bug: The business requirement is "items that appear in the top-100
-- by revenue in EITHER store or web channel" — a set union of two ranked
-- lists.  UNION ALL would produce duplicates for items ranked highly in both
-- channels, which is wrong for this use case.
-- ---------------------------------------------------------------------------
SELECT i_item_sk, i_product_name, 'store' AS channel
FROM (
    SELECT i.i_item_sk, i.i_product_name,
           RANK() OVER (ORDER BY SUM(ss.ss_ext_sales_price) DESC) AS rnk
    FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss
    JOIN snowflake_sample_data.tpcds_sf10tcl.item i ON ss.ss_item_sk = i.i_item_sk
    JOIN snowflake_sample_data.tpcds_sf10tcl.date_dim d ON ss.ss_sold_date_sk = d.d_date_sk
    WHERE d.d_year = 2002
    GROUP BY i.i_item_sk, i.i_product_name
) ranked WHERE rnk <= 100
UNION   -- intentional dedup: we want the distinct set of top items across channels
SELECT i_item_sk, i_product_name, 'web' AS channel
FROM (
    SELECT i.i_item_sk, i.i_product_name,
           RANK() OVER (ORDER BY SUM(ws.ws_ext_sales_price) DESC) AS rnk
    FROM snowflake_sample_data.tpcds_sf10tcl.web_sales ws
    JOIN snowflake_sample_data.tpcds_sf10tcl.item i ON ws.ws_item_sk = i.i_item_sk
    JOIN snowflake_sample_data.tpcds_sf10tcl.date_dim d ON ws.ws_sold_date_sk = d.d_date_sk
    WHERE d.d_year = 2002
    GROUP BY i.i_item_sk, i.i_product_name
) ranked WHERE rnk <= 100;


-- ---------------------------------------------------------------------------
-- Q19  [False-positive: NOT IN with non-nullable column]
-- NOT a bug: ss_sold_date_sk is used as a join key to date_dim, so rows
-- where it is NULL never match a date_dim row anyway — they are excluded
-- by the JOIN.  The NOT IN subquery returns d_date_sk which is the PK of
-- date_dim and is NOT NULL.  The classic "NOT IN with NULLs" trap does not
-- apply here because the subquery column is non-nullable.
-- ---------------------------------------------------------------------------
SELECT
    ss.ss_store_sk,
    COUNT(*) AS non_holiday_txns
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss
JOIN snowflake_sample_data.tpcds_sf10tcl.date_dim d ON ss.ss_sold_date_sk = d.d_date_sk
WHERE d.d_date_sk NOT IN (
    SELECT d2.d_date_sk
    FROM snowflake_sample_data.tpcds_sf10tcl.date_dim d2
    WHERE d2.d_holiday = 'Y'
)
GROUP BY ss.ss_store_sk
ORDER BY non_holiday_txns DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- Q20  [False-positive: COUNT(column) intentionally excludes NULLs]
-- NOT a bug: The query computes two metrics side by side — total transactions
-- (COUNT(*)) and transactions with a known customer (COUNT(ss_customer_sk)).
-- The difference reveals anonymous/walk-in transactions.  Suggesting
-- COUNT(*) instead of COUNT(ss_customer_sk) would destroy the metric.
-- ---------------------------------------------------------------------------
SELECT
    s.s_store_name,
    COUNT(*)                    AS total_txns,
    COUNT(ss.ss_customer_sk)    AS identified_txns,
    COUNT(*) - COUNT(ss.ss_customer_sk) AS anonymous_txns
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss
JOIN snowflake_sample_data.tpcds_sf10tcl.store s ON ss.ss_store_sk = s.s_store_sk
WHERE ss.ss_sold_date_sk BETWEEN 2452275 AND 2452639
GROUP BY s.s_store_name
ORDER BY anonymous_txns DESC;


-- =============================================================================
-- BAD-REWRITE-TRAP TESTS
-- These queries have a real issue, but the "obvious" fix changes semantics.
-- The skill should either not suggest the naive fix, or should suggest a
-- correct alternative that preserves the query's intent.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Q21  [Bad-rewrite-trap: LEFT JOIN that looks like INNER but isn't]
-- Issue: The WHERE clause filters on a right-side column (sr_return_amt > 0),
-- which normally converts a LEFT JOIN to an INNER JOIN.  The naive fix is
-- "change to INNER JOIN".  But the OR branch (sr_return_amt IS NULL) keeps
-- non-returned items in the result — it's how the query distinguishes
-- "sale with return" from "sale without return".  Changing to INNER JOIN
-- would drop all non-returned sales.
-- ---------------------------------------------------------------------------
SELECT
    s.s_store_name,
    ss.ss_item_sk,
    ss.ss_net_paid,
    sr.sr_return_amt,
    CASE
        WHEN sr.sr_return_amt IS NULL THEN 'no_return'
        WHEN sr.sr_return_amt > 0     THEN 'returned'
    END AS return_status
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss
LEFT JOIN snowflake_sample_data.tpcds_sf10tcl.store_returns sr
  ON ss.ss_item_sk       = sr.sr_item_sk
 AND ss.ss_ticket_number = sr.sr_ticket_number
JOIN snowflake_sample_data.tpcds_sf10tcl.store s
  ON ss.ss_store_sk = s.s_store_sk
WHERE ss.ss_sold_date_sk BETWEEN 2452275 AND 2452639
  AND (sr.sr_return_amt > 0 OR sr.sr_return_amt IS NULL)
ORDER BY ss.ss_net_paid DESC
LIMIT 50;


-- ---------------------------------------------------------------------------
-- Q22  [Bad-rewrite-trap: Non-aggregated column that is functionally dependent]
-- Issue: s_store_name is in SELECT but not in GROUP BY.  Snowflake allows
-- this (picks an arbitrary value).  The naive fix is "add s_store_name to
-- GROUP BY" or "wrap in MAX()".  But ss_store_sk → s_store_name is a 1:1
-- functional dependency (each store_sk has exactly one name).  The correct
-- fix is ANY_VALUE(s.s_store_name), which documents the intent without
-- changing grouping granularity.  Adding it to GROUP BY is harmless here
-- but sets a bad precedent; MAX() implies ordering semantics that don't apply.
-- ---------------------------------------------------------------------------
SELECT
    ss.ss_store_sk,
    s.s_store_name,                              -- not in GROUP BY
    SUM(ss.ss_net_paid)  AS total_revenue,
    COUNT(*)             AS txn_count
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss
JOIN snowflake_sample_data.tpcds_sf10tcl.store s ON ss.ss_store_sk = s.s_store_sk
WHERE ss.ss_sold_date_sk BETWEEN 2452275 AND 2452639
GROUP BY ss.ss_store_sk
ORDER BY total_revenue DESC;


-- ---------------------------------------------------------------------------
-- Q23  [Bad-rewrite-trap: Correlated subquery where JOIN introduces fanout]
-- Issue: The correlated subquery in SELECT computes the average return amount
-- per item.  The naive fix is "rewrite as JOIN".  But store_returns has
-- multiple return rows per (item_sk, store_sk) pair, so a plain JOIN would
-- create a 1:N fanout that inflates the store_sales rows — making SUM and
-- COUNT wrong.  The correct rewrite needs a pre-aggregated CTE or a lateral
-- join, not a bare JOIN.
-- ---------------------------------------------------------------------------
SELECT
    ss.ss_store_sk,
    ss.ss_item_sk,
    SUM(ss.ss_net_paid) AS item_revenue,
    (SELECT AVG(sr.sr_return_amt)
     FROM snowflake_sample_data.tpcds_sf10tcl.store_returns sr
     WHERE sr.sr_item_sk = ss.ss_item_sk
    ) AS avg_return_for_item
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss
WHERE ss.ss_sold_date_sk BETWEEN 2452275 AND 2452639
GROUP BY ss.ss_store_sk, ss.ss_item_sk
ORDER BY item_revenue DESC
LIMIT 50;


-- ---------------------------------------------------------------------------
-- Q24  [Bad-rewrite-trap: DISTINCT masking intentional many-to-many]
-- Issue: DISTINCT is applied to the final result after a many-to-many join
-- between store_sales (via item) and promotion.  The naive fix is "remove
-- DISTINCT and fix the join to avoid duplicates".  But the business intent
-- is: "which (category, promotion) pairs exist?" — a set-of-pairs question.
-- The many-to-many is expected (one item can be in multiple promotions),
-- and DISTINCT is the correct way to get unique pairs.  Removing it would
-- return millions of duplicate rows.
-- ---------------------------------------------------------------------------
SELECT DISTINCT
    i.i_category,
    p.p_promo_name,
    p.p_channel_email,
    p.p_channel_catalog
FROM snowflake_sample_data.tpcds_sf10tcl.store_sales ss
JOIN snowflake_sample_data.tpcds_sf10tcl.item      i ON ss.ss_item_sk  = i.i_item_sk
JOIN snowflake_sample_data.tpcds_sf10tcl.promotion  p ON ss.ss_promo_sk = p.p_promo_sk
JOIN snowflake_sample_data.tpcds_sf10tcl.date_dim   d ON ss.ss_sold_date_sk = d.d_date_sk
WHERE d.d_year = 2002
ORDER BY i.i_category, p.p_promo_name;
