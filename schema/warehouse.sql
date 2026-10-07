-- Project 2: Santam short-term insurance training warehouse
-- PostgreSQL 14+. This is a cleaned analytics model; stage and validate raw CSVs first.
-- Fraud indicators are for human review only, never automatic claim decisions.

CREATE SCHEMA IF NOT EXISTS santam_dw;
SET search_path TO santam_dw, public;

CREATE TABLE IF NOT EXISTS dim_date (
    date_key          integer PRIMARY KEY, -- YYYYMMDD
    calendar_date     date NOT NULL UNIQUE,
    calendar_year     smallint NOT NULL,
    calendar_quarter  smallint NOT NULL,
    calendar_month    smallint NOT NULL,
    month_name        text NOT NULL,
    is_month_end      boolean NOT NULL DEFAULT false
);

CREATE TABLE IF NOT EXISTS dim_channel (
    channel_sk        smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    channel_code      text NOT NULL UNIQUE,
    channel_name      text NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_customer (
    customer_sk       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_bk       text NOT NULL,
    customer_hash     text,
    customer_type     text NOT NULL,
    province          text,
    postal_area       text,
    valid_from        date NOT NULL,
    valid_to          date NOT NULL DEFAULT '9999-12-31',
    is_current        boolean NOT NULL DEFAULT true,
    CONSTRAINT dim_customer_dates_ck CHECK (valid_to >= valid_from)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_dim_customer_current
    ON dim_customer(customer_bk) WHERE is_current;

CREATE TABLE IF NOT EXISTS dim_intermediary (
    intermediary_sk   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    intermediary_bk   text NOT NULL,
    fsp_number        text,
    channel_sk        smallint REFERENCES dim_channel(channel_sk),
    channel           text NOT NULL,
    network_name      text,
    region_name       text,
    is_active         boolean NOT NULL DEFAULT true,
    valid_from        date NOT NULL,
    valid_to          date NOT NULL DEFAULT '9999-12-31',
    is_current        boolean NOT NULL DEFAULT true,
    CONSTRAINT dim_intermediary_dates_ck CHECK (valid_to >= valid_from)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_dim_intermediary_current
    ON dim_intermediary(intermediary_bk) WHERE is_current;

CREATE TABLE IF NOT EXISTS dim_provider (
    provider_sk       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    provider_bk       text NOT NULL,
    provider_type     text NOT NULL,
    provider_name     text NOT NULL,
    branch_name       text,
    region_name       text,
    is_active         boolean NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_dim_provider_bk ON dim_provider(provider_bk);

CREATE TABLE IF NOT EXISTS dim_geography (
    geography_sk      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    postal_area       text NOT NULL,
    suburb_name       text NOT NULL,
    municipality      text NOT NULL,
    province          text NOT NULL,
    region_name       text NOT NULL,
    UNIQUE (postal_area, suburb_name)
);
CREATE INDEX IF NOT EXISTS ix_dim_geo_province ON dim_geography(province, postal_area);

CREATE TABLE IF NOT EXISTS dim_product (
    product_sk        smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_code      text NOT NULL UNIQUE,
    product_line      text NOT NULL,
    product_name      text NOT NULL
);

CREATE TABLE IF NOT EXISTS dim_policy (
    policy_sk         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    policy_bk         text NOT NULL UNIQUE,
    customer_bk       text NOT NULL,
    inception_date    date NOT NULL,
    expiry_date       date NOT NULL,
    policy_status     text NOT NULL,
    currency_code     char(3) NOT NULL DEFAULT 'ZAR',
    CONSTRAINT dim_policy_dates_ck CHECK (expiry_date >= inception_date)
);
CREATE INDEX IF NOT EXISTS ix_dim_policy_customer ON dim_policy(customer_bk);

-- Type 2 policy/risk dimension. One business key may have many historical
-- versions but only one current row. Facts join the version effective on event date.
CREATE TABLE IF NOT EXISTS dim_policy_risk (
    policy_risk_sk    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    policy_bk         text NOT NULL REFERENCES dim_policy(policy_bk),
    risk_bk           text NOT NULL,
    product_sk        smallint NOT NULL REFERENCES dim_product(product_sk),
    intermediary_sk   bigint REFERENCES dim_intermediary(intermediary_sk),
    geography_sk      bigint REFERENCES dim_geography(geography_sk),
    provider_channel  text,
    sum_insured       numeric(18,2) NOT NULL,
    vehicle_year      smallint,
    vehicle_registration_hash text,
    vehicle_vin_hash  text,
    effective_from    date NOT NULL,
    effective_to      date NOT NULL DEFAULT '9999-12-31',
    is_current        boolean NOT NULL DEFAULT true,
    CONSTRAINT dim_policy_risk_dates_ck CHECK (effective_to >= effective_from)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_policy_risk_current
    ON dim_policy_risk(policy_bk, risk_bk) WHERE is_current;
CREATE INDEX IF NOT EXISTS ix_policy_risk_asof
    ON dim_policy_risk(policy_bk, risk_bk, effective_from, effective_to);
CREATE INDEX IF NOT EXISTS ix_policy_risk_geo ON dim_policy_risk(geography_sk);
CREATE INDEX IF NOT EXISTS ix_policy_risk_product ON dim_policy_risk(product_sk);

CREATE TABLE IF NOT EXISTS dim_cause_of_loss (
    cause_sk          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cause_code        text NOT NULL UNIQUE,
    cause_name        text NOT NULL,
    catastrophe_related boolean NOT NULL DEFAULT false
);

CREATE TABLE IF NOT EXISTS fact_written_premium (
    written_premium_sk bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_row_id     text NOT NULL UNIQUE,
    transaction_ref   text,
    policy_sk         bigint NOT NULL REFERENCES dim_policy(policy_sk),
    policy_risk_sk    bigint REFERENCES dim_policy_risk(policy_risk_sk),
    customer_sk       bigint NOT NULL REFERENCES dim_customer(customer_sk),
    intermediary_sk   bigint REFERENCES dim_intermediary(intermediary_sk),
    channel_sk        smallint REFERENCES dim_channel(channel_sk),
    product_sk        smallint NOT NULL REFERENCES dim_product(product_sk),
    transaction_date_key integer NOT NULL REFERENCES dim_date(date_key),
    cover_start_date_key integer NOT NULL REFERENCES dim_date(date_key),
    cover_end_date_key integer NOT NULL REFERENCES dim_date(date_key),
    written_amount    numeric(18,2) NOT NULL,
    commission_amount numeric(18,2) NOT NULL DEFAULT 0,
    acquisition_expense_amount numeric(18,2) NOT NULL DEFAULT 0,
    administration_expense_amount numeric(18,2) NOT NULL DEFAULT 0,
    transaction_type  text NOT NULL,
    original_ref      text,
    source_file       text NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_written_premium_date ON fact_written_premium(transaction_date_key);
CREATE INDEX IF NOT EXISTS ix_written_premium_policy ON fact_written_premium(policy_sk);
CREATE INDEX IF NOT EXISTS ix_written_premium_product ON fact_written_premium(product_sk);

-- Monthly allocation grain: one policy/risk version per calendar month.
CREATE TABLE IF NOT EXISTS fact_earned_premium_monthly (
    earned_premium_sk bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    policy_sk         bigint NOT NULL REFERENCES dim_policy(policy_sk),
    policy_risk_sk    bigint NOT NULL REFERENCES dim_policy_risk(policy_risk_sk),
    product_sk        smallint NOT NULL REFERENCES dim_product(product_sk),
    intermediary_sk   bigint REFERENCES dim_intermediary(intermediary_sk),
    channel_sk        smallint REFERENCES dim_channel(channel_sk),
    geography_sk      bigint REFERENCES dim_geography(geography_sk),
    month_date_key    integer NOT NULL REFERENCES dim_date(date_key),
    net_written_amount numeric(18,2) NOT NULL,
    covered_days      integer NOT NULL CHECK (covered_days >= 0),
    total_cover_days  integer NOT NULL CHECK (total_cover_days > 0),
    earned_amount     numeric(18,2) NOT NULL,
    source_batch_id   uuid NOT NULL,
    UNIQUE (policy_sk, policy_risk_sk, month_date_key, source_batch_id)
);
CREATE INDEX IF NOT EXISTS ix_earned_month ON fact_earned_premium_monthly(month_date_key);
CREATE INDEX IF NOT EXISTS ix_earned_product_geo ON fact_earned_premium_monthly(product_sk, geography_sk);

-- One row per claim, updated as milestones arrive; retain claim transaction
-- history separately if event-level financial audit is needed.
CREATE TABLE IF NOT EXISTS fact_claim_lifecycle (
    claim_sk          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claim_bk          text NOT NULL UNIQUE,
    policy_sk         bigint NOT NULL REFERENCES dim_policy(policy_sk),
    policy_risk_sk    bigint REFERENCES dim_policy_risk(policy_risk_sk),
    customer_sk       bigint NOT NULL REFERENCES dim_customer(customer_sk),
    intermediary_sk   bigint REFERENCES dim_intermediary(intermediary_sk),
    channel_sk        smallint REFERENCES dim_channel(channel_sk),
    provider_sk       bigint REFERENCES dim_provider(provider_sk),
    product_sk        smallint NOT NULL REFERENCES dim_product(product_sk),
    geography_sk      bigint REFERENCES dim_geography(geography_sk),
    cause_sk          smallint REFERENCES dim_cause_of_loss(cause_sk),
    loss_date_key     integer NOT NULL REFERENCES dim_date(date_key),
    report_date_key   integer NOT NULL REFERENCES dim_date(date_key),
    assessed_date_key integer REFERENCES dim_date(date_key),
    authorised_date_key integer REFERENCES dim_date(date_key),
    repaired_date_key integer REFERENCES dim_date(date_key),
    settled_date_key  integer REFERENCES dim_date(date_key),
    claim_status      text NOT NULL,
    claim_amount      numeric(18,2) NOT NULL,
    authorised_amount numeric(18,2) NOT NULL DEFAULT 0,
    paid_amount       numeric(18,2) NOT NULL DEFAULT 0,
    outstanding_reserve numeric(18,2) NOT NULL DEFAULT 0,
    is_catastrophe    boolean NOT NULL DEFAULT false,
    source_file       text NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_claim_loss_date ON fact_claim_lifecycle(loss_date_key);
CREATE INDEX IF NOT EXISTS ix_claim_report_date ON fact_claim_lifecycle(report_date_key);
CREATE INDEX IF NOT EXISTS ix_claim_settle_date ON fact_claim_lifecycle(settled_date_key);
CREATE INDEX IF NOT EXISTS ix_claim_provider_date ON fact_claim_lifecycle(provider_sk, loss_date_key);
CREATE INDEX IF NOT EXISTS ix_claim_geo_cause ON fact_claim_lifecycle(geography_sk, cause_sk);
CREATE INDEX IF NOT EXISTS ix_claim_status ON fact_claim_lifecycle(claim_status);

CREATE TABLE IF NOT EXISTS fact_claim_transaction (
    claim_transaction_sk bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_row_id     text NOT NULL UNIQUE,
    claim_bk          text NOT NULL REFERENCES fact_claim_lifecycle(claim_bk),
    transaction_date_key integer NOT NULL REFERENCES dim_date(date_key),
    transaction_type  text NOT NULL,
    amount_zar        numeric(18,2) NOT NULL,
    authorised_amount numeric(18,2),
    source_file       text NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_claim_txn_claim ON fact_claim_transaction(claim_bk);
CREATE INDEX IF NOT EXISTS ix_claim_txn_date ON fact_claim_transaction(transaction_date_key);

CREATE TABLE IF NOT EXISTS dim_catastrophe_event (
    event_sk          smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_bk          text NOT NULL UNIQUE,
    event_name        text NOT NULL,
    event_type        text NOT NULL,
    province          text NOT NULL,
    event_start_date  date NOT NULL,
    event_end_date    date NOT NULL,
    damage_ratio_assumption numeric(6,4),
    CONSTRAINT catastrophe_dates_ck CHECK (event_end_date >= event_start_date)
);

CREATE TABLE IF NOT EXISTS etl_quarantine (
    quarantine_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id          uuid NOT NULL,
    source_file       text NOT NULL,
    source_row_id     text NOT NULL,
    source_table      text NOT NULL,
    reason_code       text NOT NULL,
    reason_detail     text NOT NULL,
    raw_record        jsonb NOT NULL,
    status            text NOT NULL DEFAULT 'open'
                      CHECK (status IN ('open','resolved','rejected')),
    loaded_at         timestamptz NOT NULL DEFAULT now(),
    resolved_at       timestamptz,
    UNIQUE (batch_id, source_file, source_row_id, reason_code)
);
CREATE INDEX IF NOT EXISTS ix_santam_quarantine_status ON etl_quarantine(status, loaded_at);
CREATE INDEX IF NOT EXISTS ix_santam_quarantine_reason ON etl_quarantine(reason_code);

CREATE TABLE IF NOT EXISTS etl_change_audit (
    audit_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id          uuid NOT NULL,
    source_file       text NOT NULL,
    source_row_id     text NOT NULL,
    entity_name       text NOT NULL,
    field_name        text NOT NULL,
    original_value    text,
    new_value         text,
    rule_code         text NOT NULL,
    changed_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (batch_id, source_file, source_row_id, field_name, rule_code)
);
CREATE INDEX IF NOT EXISTS ix_santam_audit_entity ON etl_change_audit(entity_name, rule_code);

CREATE TABLE IF NOT EXISTS etl_entity_crosswalk (
    source_system     text NOT NULL,
    entity_type       text NOT NULL,
    source_bk         text NOT NULL,
    survivor_bk       text NOT NULL,
    match_method      text NOT NULL,
    reviewed          boolean NOT NULL DEFAULT false,
    created_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source_system, entity_type, source_bk)
);

CREATE OR REPLACE VIEW v_santam_claim_cycle_time AS
SELECT claim_bk,
       report_date.calendar_date AS report_date,
       settle_date.calendar_date AS settled_date,
       (settle_date.calendar_date - report_date.calendar_date) AS settlement_days,
       provider_sk, geography_sk, product_sk
FROM fact_claim_lifecycle f
JOIN dim_date report_date ON report_date.date_key = f.report_date_key
LEFT JOIN dim_date settle_date ON settle_date.date_key = f.settled_date_key;

CREATE OR REPLACE VIEW v_santam_warehouse_control_totals AS
SELECT 'written_premium'::text AS measure_name, count(*) AS row_count,
       coalesce(sum(written_amount), 0)::numeric(20,2) AS amount_zar
FROM fact_written_premium
UNION ALL
SELECT 'earned_premium', count(*),
       coalesce(sum(earned_amount), 0)::numeric(20,2)
FROM fact_earned_premium_monthly
UNION ALL
SELECT 'paid_claims', count(*),
       coalesce(sum(paid_amount), 0)::numeric(20,2)
FROM fact_claim_lifecycle;

CREATE OR REPLACE VIEW v_santam_quarantine_counts AS
SELECT source_file, source_table, status, count(*) AS row_count
FROM etl_quarantine
GROUP BY source_file, source_table, status;