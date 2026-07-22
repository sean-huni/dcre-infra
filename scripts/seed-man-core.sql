-- THIS FILE IS THE CANON for the dcre_man shared-core shapes (SCRUM-73, M1/M2).
-- Every M-service's 000-man-core-bootstrap changelog (mrr et al.) must stay
-- byte-equivalent in SHAPE with this file: same tables, columns, types, uniques,
-- indexes and seed rows. Source of the shape: mrr 000-man-core-bootstrap.xml
-- (branch SCRUM-74-feat-mrr); drift in either direction is a review defect.
--
-- WHY: whichever M-service boots first would otherwise mint these shared shapes,
-- and concurrent FIRST boots race on the CREATEs (same class as the Liquibase
-- history bootstrap race, see seed-liquibase-history.sql). env-reset.sh applies
-- this file BEFORE any service boots (--database=dcre_man, step 6); the services'
-- MARK_RAN-guarded 000 changesets then converge as no-ops in any boot order.
--
-- FK relationships are deliberately SHAPE-ONLY (columns + indexes, no DB
-- constraints) so guarded pre-creates converge from any service order.
-- Canonical owners arrive with their services (R-04): mandate projection = MSR
-- (T13), account master consolidation = M11.
-- Idempotent throughout: IF NOT EXISTS creates; seeds are per-row
-- INSERT ... ON CONFLICT (code) DO NOTHING (business identity = PK).

CREATE TABLE IF NOT EXISTS account_type (
  code VARCHAR(8) NOT NULL PRIMARY KEY,
  description VARCHAR(64) NOT NULL,
  mandates_allowed BOOLEAN NOT NULL);

-- A-62 (FNB account-type roster attestation pending): CHQ/SAV/TRN/CC/RF per the
-- spec roster. AG01 semantics: mandates are disallowed on Savings only; every
-- other type allows them until attested otherwise.
INSERT INTO account_type (code, description, mandates_allowed) VALUES
  ('CHQ', 'Cheque/Current', true),
  ('SAV', 'Savings', false),
  ('TRN', 'Transmission', true),
  ('CC', 'Credit Card', true),
  ('RF', 'Revolving Facility/ENDO', true)
ON CONFLICT (code) DO NOTHING;

CREATE TABLE IF NOT EXISTS account (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  account_number VARCHAR(32) NOT NULL,
  -- FK-shaped to account_type.code; constraint deliberately app-side.
  account_type_code VARCHAR(8) NOT NULL,
  product_code VARCHAR(8),
  status VARCHAR(16) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_account_number UNIQUE (account_number));
CREATE INDEX IF NOT EXISTS ix_account_type_code ON account (account_type_code);

-- Mandate PROJECTION shape (spec section 2); MSR is the sole writer (R-10,
-- ruling note 2). R-20/F28-F29: at-most-one EFFECTIVELY ACTIVE mandate per ref
-- is an effective-WINDOW rule enforced app-side, so mandate_ref carries an
-- index, not a DB UNIQUE constraint.
CREATE TABLE IF NOT EXISTS mandate (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  mandate_ref VARCHAR(35) NOT NULL,
  contract_ref VARCHAR(14) NOT NULL,
  creditor_account VARCHAR(32) NOT NULL,
  debtor_account VARCHAR(32),
  debtor_branch VARCHAR(16),
  debtor_name VARCHAR(70),
  max_collection_amount DECIMAL(18,2),
  frequency VARCHAR(4),
  collection_day SMALLINT,
  state VARCHAR(16) NOT NULL,
  start_date DATE,
  expiry_date DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS ix_mandate_ref ON mandate (mandate_ref);

CREATE TABLE IF NOT EXISTS mandate_reason_code (
  code VARCHAR(4) NOT NULL PRIMARY KEY,
  description VARCHAR(64) NOT NULL,
  system_action VARCHAR(32) NOT NULL,
  accepted BOOLEAN NOT NULL);

-- R-21: reason codes + system actions live as reference DATA, never enum
-- ordinals. Vocabulary per the ISO 20022 external status-reason set as pinned
-- in plan T3; accepted=false throughout (the nine are reject/terminal reasons;
-- accepted-with-reason codes arrive when attested).
INSERT INTO mandate_reason_code (code, description, system_action, accepted) VALUES
  ('AC01', 'Incorrect account number', 'NO_RETRY', false),
  ('AC04', 'Closed account number', 'PERMANENT_FAIL', false),
  ('AC06', 'Blocked account', 'BLOCKED', false),
  ('AG01', 'Transaction forbidden on account type', 'DISALLOWED_TYPE', false),
  ('MD01', 'No mandate / unknown mandate', 'UNKNOWN_MANDATE', false),
  ('MD06', 'Refund request by end customer', 'DISPUTE', false),
  ('MD07', 'End customer deceased', 'TERMINATE_NOW', false),
  ('MS03', 'Reason not specified', 'BANK_RISK', false),
  ('TM01', 'Authorisation window timeout', 'EXPIRE', false)
ON CONFLICT (code) DO NOTHING;
