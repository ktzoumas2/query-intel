--------------------------------------------------------------------------------
-- Query-Intel Adversarial Suite
-- Source: QUERY_INTEL_TEST.ADVERSARIAL (run test_suite_adversarial_setup.sql)
-- Ground truth: test_suite_adversarial_answers.md (evaluator only)
--------------------------------------------------------------------------------

-- A1
SELECT
    C2,
    C4,
    COUNT(*)  AS n,
    AVG(C3)   AS avg_c3,
    SUM(C6)   AS sum_c6
FROM query_intel_test.adversarial.t_9x
WHERE C5 >= '2024-07-01'
GROUP BY C2, C4
HAVING COUNT(*) > 10
ORDER BY n DESC;


-- A2
SELECT
    region,
    AVG(revenue)                 AS avg_revenue,
    MAX(revenue) - MIN(revenue)  AS revenue_spread,
    COUNT(DISTINCT customer_id)  AS customers
FROM query_intel_test.adversarial.customers
WHERE updated_at >= '2024-10-01'
GROUP BY region
ORDER BY avg_revenue DESC;


-- A3
WITH churned_accounts AS (
    SELECT account_id, last_change_date
    FROM query_intel_test.adversarial.account_state
    WHERE is_active = 1
      AND last_change_date >= '2024-01-01'
)
SELECT account_id, last_change_date
FROM churned_accounts
ORDER BY last_change_date DESC;


-- A4
SELECT
    status,
    COUNT(*)     AS orders,
    SUM(amount)  AS total_amount
FROM query_intel_test.adversarial.orders_ledger
WHERE status != 'VOID'
GROUP BY status;


-- A5
SELECT
    o.order_id,
    o.amount,
    o.amount * c.tax_rate  AS tax,
    c.reporting_ccy
FROM query_intel_test.adversarial.orders_ledger o
CROSS JOIN (
    SELECT tax_rate, reporting_ccy
    FROM query_intel_test.adversarial.app_config
    LIMIT 1
) c
WHERE o.status = 'PAID';


-- A6
SELECT
    d.tier,
    SUM(a.spend)  AS total_spend,
    COUNT(*)      AS activity_rows
FROM query_intel_test.adversarial.account_activity a
JOIN query_intel_test.adversarial.dim_account d
  ON a.account_id = d.account_id
GROUP BY d.tier
ORDER BY total_spend DESC;


-- A7
SELECT
    m.name,
    p.partner
FROM query_intel_test.adversarial.partner_refs p
JOIN query_intel_test.adversarial.merchants m
  ON p.ext_id = m.id
ORDER BY m.name;


-- A8
SELECT COUNT(DISTINCT user_id) AS users_today
FROM query_intel_test.adversarial.user_logins
WHERE login_ts::DATE = CURRENT_DATE();


-- A9
SELECT
    region_code,
    COUNT(*)     AS events,
    SUM(amount)  AS total_amount
FROM query_intel_test.adversarial.fact_events
WHERE status = 'COMPLETE' OR region_code = 7
GROUP BY region_code
ORDER BY region_code;


-- A10
SELECT
    d.channel,
    SUM(f.amount)  AS total_amount,
    COUNT(*)       AS events
FROM query_intel_test.adversarial.fact_events f
JOIN query_intel_test.adversarial.event_details d
  ON f.event_id = d.event_id
WHERE f.event_ts >= '2024-07-01'
GROUP BY d.channel
ORDER BY total_amount DESC;


-- A11
SELECT
    DATE_TRUNC('month', event_ts)  AS month,
    SUM(amount)                    AS completed_amount
FROM query_intel_test.adversarial.fact_events
WHERE status = 'COMPLETE'
GROUP BY 1
ORDER BY 1;
