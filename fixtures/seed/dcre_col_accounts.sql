-- ==========================================================================
-- DCRE Collections: dcre_col.account seed (GENERATED shape, synthetic data)
--
-- WHY THIS EXISTS (SCRUM-91, 2026-07-27). dcre_col.account is created by NOTHING
-- in version control. No Liquibase changelog mints it: the man-core bootstraps
-- create account in dcre_man, not dcre_col, and AIS's 000-bootstrap only guards
-- ordering. The only path was env-reset.sh --seed <accounts.sql> <mandates.sql>,
-- and no such file was ever committed. So after every reset the table was absent,
-- and CtvValidationService called referenceSnapshot.accountsByNumber(...)
-- UNCONDITIONALLY, before the mandate-source branch, so CTV TECH-failed on
-- "relation account does not exist" before reaching any verdict. env-reset.sh
-- even warns about it verbatim, then leaves it unfixed.
--
-- That made SCRUM-91 Task 11 Step 8 (CTV gating) unverifiable in EITHER mode:
-- legacy reads dcre_col.mandate (also absent) and projection never got that far.
--
-- Idempotent: CREATE TABLE IF NOT EXISTS, and INSERT ... ON CONFLICT DO NOTHING
-- keyed on the business identity account_number, never the UUID primary key
-- (CockroachDB resolves UPSERT on the PK only). Re-running changes nothing and
-- never clobbers a later owner's edits.
--
-- Canonical DDL is lifted verbatim from the toolkit's generated
-- fnb_dcre_ctv_toolkit/dcre_accounts.sql so the two cannot drift.
-- Ownership stays R-04: AIS is the single writer, CTV holds SELECT only.
-- ==========================================================================

CREATE TABLE IF NOT EXISTS account (
    id                UUID        NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
    product_code      VARCHAR(8)  NOT NULL,
    account_number    VARCHAR(34) NOT NULL,
    app_no            VARCHAR(34) NOT NULL,
    acc_type          VARCHAR(4)  NOT NULL,
    branch_code       VARCHAR(11) NOT NULL,
    balance           DECIMAL(18,2)   NULL,
    max_credit_limit  DECIMAL(18,2)   NULL,
    cancel_reason     VARCHAR(64)     NULL,
    country_id        INT8        NOT NULL DEFAULT 1,
    edr_ind           BOOL        NOT NULL DEFAULT false,
    pre_ind           BOOL        NOT NULL DEFAULT false,
    process_status    VARCHAR(16) NOT NULL,
    status            VARCHAR(8)  NOT NULL,
    status_reason     VARCHAR(64)     NULL,
    ucn               VARCHAR(20) NOT NULL,
    client_id         INT8        NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now() ON UPDATE now(),
    CONSTRAINT uq_account_account_number UNIQUE (account_number),
    CONSTRAINT chk_account_product CHECK (product_code IN ('FNBRF', 'FNBCC')),
    CONSTRAINT chk_account_product_amount CHECK (
        (product_code = 'FNBRF' AND balance IS NOT NULL AND max_credit_limit IS NULL)
        OR
        (product_code = 'FNBCC' AND max_credit_limit IS NOT NULL AND balance IS NULL)
    ),
    CONSTRAINT chk_account_amounts_nonneg CHECK (
        (balance IS NULL OR balance >= 0)
        AND (max_credit_limit IS NULL OR max_credit_limit >= 0)
    )
);

-- The ten debtor accounts carried by the SCRUM-91 chaos book
-- (FNBRF01_FNB1MB2026072619000001, refs CHAM*). All FNBRF (balance-carrying),
-- ACTIVE/AAUT, each with a balance comfortably above its entry amount so the
-- affordability arm passes and execution reaches the mandate gate, which is what
-- Step 8 actually tests. Sequence 1 carries mandate CHAMREQ00000001 (ACCP, the
-- PASS case) and sequence 2 carries CHAMREQ00000012 (SUSPENDED, the
-- FAIL_MANDATE_NOT_ACTIVE case).
INSERT INTO account (product_code, account_number, app_no, acc_type, branch_code,
                     balance, max_credit_limit, cancel_reason, country_id,
                     edr_ind, pre_ind, process_status, status, status_reason, ucn, client_id)
VALUES
    ('FNBRF', '62114052700219584', '2590451916851902001', 'CACC', '250205',  75000.00, NULL, NULL, 1, false, false, 'ACTIVE', 'AAUT', NULL, '100000000201', 2),
    ('FNBRF', '62951744441790616', '2590451916851902002', 'CACC', '250205',  95000.00, NULL, NULL, 1, false, false, 'ACTIVE', 'AAUT', NULL, '100000000202', 2),
    ('FNBRF', '62194840710758320', '2590451916851902003', 'CACC', '250205', 150000.00, NULL, NULL, 1, false, false, 'ACTIVE', 'AAUT', NULL, '100000000203', 2),
    ('FNBRF', '62715270961331344', '2590451916851902004', 'CACC', '250205',  75000.00, NULL, NULL, 1, false, false, 'ACTIVE', 'AAUT', NULL, '100000000204', 2),
    ('FNBRF', '62085856711390458', '2590451916851902005', 'CACC', '250205', 100000.00, NULL, NULL, 1, false, false, 'ACTIVE', 'AAUT', NULL, '100000000205', 2),
    ('FNBRF', '62302525712117412', '2590451916851902006', 'CACC', '250205',  10000.00, NULL, NULL, 1, false, false, 'ACTIVE', 'AAUT', NULL, '100000000206', 2),
    ('FNBRF', '62357385864618711', '2590451916851902007', 'CACC', '250205',  85000.00, NULL, NULL, 1, false, false, 'ACTIVE', 'AAUT', NULL, '100000000207', 2),
    ('FNBRF', '62796524456709879', '2590451916851902008', 'CACC', '250205', 300000.00, NULL, NULL, 1, false, false, 'ACTIVE', 'AAUT', NULL, '100000000208', 2),
    ('FNBRF', '62539548436473238', '2590451916851902009', 'CACC', '250205', 250000.00, NULL, NULL, 1, false, false, 'ACTIVE', 'AAUT', NULL, '100000000209', 2),
    ('FNBRF', '62090449463877041', '2590451916851902010', 'CACC', '250205', 300000.00, NULL, NULL, 1, false, false, 'ACTIVE', 'AAUT', NULL, '100000000210', 2)
ON CONFLICT (account_number) DO NOTHING;
