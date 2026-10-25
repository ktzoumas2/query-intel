--------------------------------------------------------------------------------
-- Query-Intel Adversarial Suite: Setup
-- Creates synthetic tables in QUERY_INTEL_TEST.ADVERSARIAL.
--
-- EVALUATOR ONLY: this file reveals what the tables really contain. Do not
-- give it to the skill under test.
--
-- Scale: FACT_EVENTS row count is set in the GENERATOR call below (default
-- 10,000,000). Edit that one number to scale up or down.
-- Teardown: DROP DATABASE QUERY_INTEL_TEST;
--------------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS QUERY_INTEL_TEST;
CREATE SCHEMA IF NOT EXISTS QUERY_INTEL_TEST.ADVERSARIAL;
USE SCHEMA QUERY_INTEL_TEST.ADVERSARIAL;

-- -----------------------------------------------------------------------------
-- Explanation traps
-- -----------------------------------------------------------------------------

-- A1: opaque names, no semantics recoverable.
CREATE OR REPLACE TABLE T_9X AS
SELECT
    SEQ4()                              AS C1,
    UNIFORM(1, 40, RANDOM())            AS C2,
    UNIFORM(0, 1000, RANDOM()) / 10     AS C3,
    IFF(UNIFORM(0, 9, RANDOM()) = 0, 'Q', 'R') AS C4,
    DATEADD(day, -UNIFORM(0, 365, RANDOM()), '2024-12-31'::DATE) AS C5,
    UNIFORM(0, 1, RANDOM())             AS C6
FROM TABLE(GENERATOR(ROWCOUNT => 100000));

-- A2: named like a customer table, actually IoT sensor readings.
-- REVENUE = temperature in Kelvin, REGION = device zone, CUSTOMER_ID = device id.
CREATE OR REPLACE TABLE CUSTOMERS AS
SELECT
    UNIFORM(1, 500, RANDOM())                         AS CUSTOMER_ID,
    ARRAY_CONSTRUCT('Z-NORTH','Z-SOUTH','Z-CORE','Z-EDGE')[UNIFORM(0, 3, RANDOM())]::VARCHAR AS REGION,
    ROUND(270 + UNIFORM(0, 4000, RANDOM()) / 100, 2)  AS REVENUE,
    DATEADD(minute, -UNIFORM(0, 525600, RANDOM()), '2024-12-31 23:59:00'::TIMESTAMP_NTZ) AS UPDATED_AT
FROM TABLE(GENERATOR(ROWCOUNT => 200000));

-- A3: IS_ACTIVE = 1 means soft-deleted (legacy inverted flag).
CREATE OR REPLACE TABLE ACCOUNT_STATE AS
SELECT
    SEQ4() + 1                              AS ACCOUNT_ID,
    IFF(UNIFORM(0, 9, RANDOM()) < 2, 1, 0)  AS IS_ACTIVE,
    DATEADD(day, -UNIFORM(0, 900, RANDOM()), '2024-12-31'::DATE) AS LAST_CHANGE_DATE
FROM TABLE(GENERATOR(ROWCOUNT => 100000));

-- -----------------------------------------------------------------------------
-- Correctness traps
-- -----------------------------------------------------------------------------

-- A4: STATUS is NOT NULL, so != cannot drop NULLs.
CREATE OR REPLACE TABLE ORDERS_LEDGER (
    ORDER_ID   NUMBER       NOT NULL,
    STATUS     VARCHAR(10)  NOT NULL,
    AMOUNT     NUMBER(12,2) NOT NULL
);
INSERT INTO ORDERS_LEDGER
SELECT SEQ4() + 1,
       ARRAY_CONSTRUCT('OPEN','PAID','VOID')[UNIFORM(0, 2, RANDOM())]::VARCHAR,
       UNIFORM(1, 50000, RANDOM()) / 100
FROM TABLE(GENERATOR(ROWCOUNT => 100000));

-- A5: exactly one row, enforced by design.
CREATE OR REPLACE TABLE APP_CONFIG (
    FISCAL_YEAR_START DATE,
    REPORTING_CCY     VARCHAR(3),
    TAX_RATE          NUMBER(5,4)
);
INSERT INTO APP_CONFIG VALUES ('2024-02-01', 'EUR', 0.1900);

-- A6: SCD2 dimension, ~3 versions per ACCOUNT_ID; only IS_CURRENT rows are unique.
CREATE OR REPLACE TABLE DIM_ACCOUNT AS
WITH base AS (
    SELECT SEQ4() + 1 AS ACCOUNT_ID FROM TABLE(GENERATOR(ROWCOUNT => 100000))
), versions AS (
    SELECT b.ACCOUNT_ID, v.VERSION_NO
    FROM base b
    CROSS JOIN (SELECT SEQ4() + 1 AS VERSION_NO FROM TABLE(GENERATOR(ROWCOUNT => 3))) v
)
SELECT
    ACCOUNT_ID,
    VERSION_NO,
    ARRAY_CONSTRUCT('BRONZE','SILVER','GOLD')[VERSION_NO - 1]::VARCHAR AS TIER,
    DATEADD(month, (VERSION_NO - 1) * 8, '2022-01-01'::DATE)           AS VALID_FROM,
    IFF(VERSION_NO = 3, NULL, DATEADD(month, VERSION_NO * 8, '2022-01-01'::DATE)) AS VALID_TO,
    VERSION_NO = 3                                                     AS IS_CURRENT
FROM versions;

CREATE OR REPLACE TABLE ACCOUNT_ACTIVITY AS
SELECT
    UNIFORM(1, 100000, RANDOM())    AS ACCOUNT_ID,
    UNIFORM(1, 100000, RANDOM()) / 100 AS SPEND,
    DATEADD(day, -UNIFORM(0, 365, RANDOM()), '2024-12-31'::DATE) AS ACTIVITY_DATE
FROM TABLE(GENERATOR(ROWCOUNT => 1000000));

-- A7: VARCHAR partner ids with leading zeros; distinct strings, same number.
CREATE OR REPLACE TABLE PARTNER_REFS (
    EXT_ID      VARCHAR(10),
    PARTNER     VARCHAR(20)
);
INSERT INTO PARTNER_REFS
SELECT LPAD(TO_VARCHAR(n), LENGTH(TO_VARCHAR(n)) + UNIFORM(0, 3, RANDOM()), '0'),
       'PARTNER_' || UNIFORM(1, 30, RANDOM())
FROM (SELECT UNIFORM(1, 5000, RANDOM()) AS n FROM TABLE(GENERATOR(ROWCOUNT => 20000)));

CREATE OR REPLACE TABLE MERCHANTS (
    ID      NUMBER,
    NAME    VARCHAR(40)
);
INSERT INTO MERCHANTS
SELECT SEQ4() + 1, 'MERCHANT_' || (SEQ4() + 1) FROM TABLE(GENERATOR(ROWCOUNT => 5000));

-- A8: LOGIN_TS is TIMESTAMP_NTZ holding UTC wall-clock time.
CREATE OR REPLACE TABLE USER_LOGINS AS
SELECT
    UNIFORM(1, 20000, RANDOM()) AS USER_ID,
    DATEADD(second, -UNIFORM(0, 60 * 60 * 24 * 30, RANDOM()),
            CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP())::TIMESTAMP_NTZ) AS LOGIN_TS
FROM TABLE(GENERATOR(ROWCOUNT => 500000));

-- -----------------------------------------------------------------------------
-- Performance traps: skewed fact table
-- CUST_KEY: ~95% of rows = 1, rest spread over 2..1,000,000
-- STATUS:   ~99% 'COMPLETE'
-- EVENT_ID: unique
-- Rows are inserted in random order, so no column is naturally clustered.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE FACT_EVENTS AS
SELECT
    SEQ8() + 1 AS EVENT_ID,
    IFF(UNIFORM(1, 100, RANDOM()) <= 95, 1, UNIFORM(2, 1000000, RANDOM())) AS CUST_KEY,
    IFF(UNIFORM(1, 100, RANDOM()) <= 99, 'COMPLETE',
        IFF(UNIFORM(0, 1, RANDOM()) = 0, 'PENDING', 'FAILED'))              AS STATUS,
    UNIFORM(1, 50, RANDOM())                                                AS REGION_CODE,
    UNIFORM(1, 1000000, RANDOM()) / 100                                     AS AMOUNT,
    DATEADD(second, -UNIFORM(0, 60 * 60 * 24 * 365, RANDOM()),
            '2024-12-31 23:59:59'::TIMESTAMP_NTZ)                           AS EVENT_TS
FROM TABLE(GENERATOR(ROWCOUNT => 10000000))
ORDER BY RANDOM();

-- Near-unique detail table for A10 (one row per EVENT_ID).
CREATE OR REPLACE TABLE EVENT_DETAILS AS
SELECT EVENT_ID,
       ARRAY_CONSTRUCT('web','app','pos','api')[UNIFORM(0, 3, RANDOM())]::VARCHAR AS CHANNEL
FROM FACT_EVENTS;
