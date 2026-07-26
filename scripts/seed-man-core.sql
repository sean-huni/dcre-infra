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
-- Canonical owners arrive with their services (R-04): account master
-- consolidation = M11. The mandate PROJECTION is no longer part of this core:
-- SCRUM-91 deleted MSR, its only writer, and replaced it with the MRG-derived
-- mnd_ext_status / mandate_effective_status / mandate_current_status views.
-- Idempotent throughout: IF NOT EXISTS creates; seeds are per-row
-- INSERT ... ON CONFLICT DO NOTHING on the BUSINESS identity: (code) for the
-- two reference tables, (account_number) for account (its PK is a UUID).

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

-- A-61/A-62 fixture account master (100 rows), the SAME set the mandate book
-- generator cuts its debtor accounts from: fnb_dcre_ctv_toolkit dcre_accounts.csv
-- -> generate_dcre_mandate_book.py --sql-output, fingerprint
-- c5718e01762ebee79ae099fa90ba0bc0af86fa96c2d84ed92a360756676b9fd3 (the
-- accounts_fpr column carried by every mandate-book manifest under
-- infra fixtures/mandate/).
--
-- WHY THIS LIVES HERE: MRV resolves the DEBTOR account against dcre_man.account.
-- env-reset.sh --seed loads its accounts/mandates SQL into dcre_col, never
-- dcre_man, so before SCRUM-91 a reset left this table EMPTY and every mandate
-- instruction row failed FAIL_ACCOUNT_NOT_FOUND at MRV; ALL_OR_NOTHING then
-- rejected the whole book before MRW and no mandate round trip was possible.
-- Seeding here makes a plain reset produce a usable mandate environment with no
-- manual step.
--
-- Business identity is account_number (uq_account_number), NOT the UUID PK, so
-- the idempotent form is INSERT ... ON CONFLICT (account_number) DO NOTHING; a
-- CRDB UPSERT would conflict on the PK only and duplicate-key on re-run.
-- DO NOTHING (not DO UPDATE): a re-run must never clobber an operator's or a
-- later owner's edits to a row that already exists (R-04, account master
-- consolidation is M11's).
-- Type roster: SAV is the only mandates-disallowed type, so SAV rows are the
-- AG01 (FAIL_ACCOUNT_TYPE_DISALLOWED) targets and are deliberately present.
INSERT INTO account (account_number, account_type_code, product_code, status) VALUES
  ('62681769356319023', 'CHQ', 'FNBRF', 'ACTIVE'),
  ('62454267979193807', 'CC', 'FNBCC', 'ACTIVE'),
  ('62468648748036585', 'CC', 'FNBRF', 'ACTIVE'),
  ('62492343856480059', 'CC', 'FNBCC', 'ACTIVE'),
  ('62845860423565548', 'CC', 'FNBRF', 'ACTIVE'),
  ('62001482970090167', 'CC', 'FNBCC', 'ACTIVE'),
  ('62782537787682908', 'SAV', 'FNBRF', 'ACTIVE'),
  ('62622253224127353', 'CHQ', 'FNBCC', 'ACTIVE'),
  ('62253923183350978', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62657200953522054', 'SAV', 'FNBCC', 'ACTIVE'),
  ('62923308323669443', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62094402221154650', 'CHQ', 'FNBCC', 'ACTIVE'),
  ('62599491134377647', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62541771464553718', 'CC', 'FNBCC', 'ACTIVE'),
  ('62902576347321860', 'CHQ', 'FNBRF', 'ACTIVE'),
  ('62255002728315278', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62379224324085381', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62696721282627611', 'CC', 'FNBCC', 'ACTIVE'),
  ('62105042425401097', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62032508308755214', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62497774258013186', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62736337421426333', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62425862968784216', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62025988167735481', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62257083694259802', 'SAV', 'FNBRF', 'ACTIVE'),
  ('62435790007621181', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62661715506662504', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62030708736532664', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62156194462854359', 'SAV', 'FNBRF', 'ACTIVE'),
  ('62194510590128934', 'SAV', 'FNBCC', 'ACTIVE'),
  ('62200337362482435', 'CHQ', 'FNBRF', 'ACTIVE'),
  ('62061337745888197', 'CHQ', 'FNBCC', 'ACTIVE'),
  ('62042008313943907', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62494218764150329', 'CC', 'FNBCC', 'ACTIVE'),
  ('62387974585811819', 'SAV', 'FNBRF', 'ACTIVE'),
  ('62654662590905530', 'SAV', 'FNBCC', 'ACTIVE'),
  ('62437006469091885', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62775402571510857', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62972858063695998', 'CHQ', 'FNBRF', 'ACTIVE'),
  ('62252732027868966', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62435195287214682', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62643604995894609', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62928361023616874', 'CHQ', 'FNBRF', 'ACTIVE'),
  ('62536091269301568', 'CC', 'FNBCC', 'ACTIVE'),
  ('62529802174259656', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62901938093122884', 'SAV', 'FNBCC', 'ACTIVE'),
  ('62393117912604830', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62950825402315397', 'SAV', 'FNBCC', 'ACTIVE'),
  ('62919269173697309', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62866135468500458', 'CC', 'FNBCC', 'ACTIVE'),
  ('62142728535602389', 'CHQ', 'FNBRF', 'ACTIVE'),
  ('62312099145049459', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62330324750657911', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62329584720905911', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62401360169368614', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62962414213014688', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62881895597015326', 'SAV', 'FNBRF', 'ACTIVE'),
  ('62980903847061738', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62672382543653990', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62798725835758047', 'CHQ', 'FNBCC', 'ACTIVE'),
  ('62490627257574842', 'CHQ', 'FNBRF', 'ACTIVE'),
  ('62515597026692759', 'SAV', 'FNBCC', 'ACTIVE'),
  ('62904929521214058', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62530448880496463', 'CHQ', 'FNBCC', 'ACTIVE'),
  ('62668542884083216', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62984352840932569', 'SAV', 'FNBCC', 'ACTIVE'),
  ('62958816186831965', 'CC', 'FNBRF', 'ACTIVE'),
  ('62489690441586290', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62611554481478246', 'SAV', 'FNBRF', 'ACTIVE'),
  ('62291550204886699', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62387072011509798', 'SAV', 'FNBRF', 'ACTIVE'),
  ('62268219176455254', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62273709592414632', 'CHQ', 'FNBRF', 'ACTIVE'),
  ('62331867562904217', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62983425522373617', 'CHQ', 'FNBRF', 'ACTIVE'),
  ('62448838738609460', 'SAV', 'FNBCC', 'ACTIVE'),
  ('62226569907288614', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62056783379044426', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62677448991744788', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62254875275045808', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62560959708542388', 'SAV', 'FNBRF', 'ACTIVE'),
  ('62727292061771358', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62464372317868100', 'CHQ', 'FNBRF', 'ACTIVE'),
  ('62070343696265312', 'SAV', 'FNBCC', 'ACTIVE'),
  ('62964184447247961', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62116338722884921', 'CHQ', 'FNBCC', 'ACTIVE'),
  ('62697671237591278', 'SAV', 'FNBRF', 'ACTIVE'),
  ('62764962526814128', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62085282659955316', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62664878179388056', 'SAV', 'FNBCC', 'ACTIVE'),
  ('62936213671379905', 'CHQ', 'FNBRF', 'ACTIVE'),
  ('62198266519758447', 'CC', 'FNBCC', 'ACTIVE'),
  ('62866618400197106', 'SAV', 'FNBRF', 'ACTIVE'),
  ('62222019817112257', 'CHQ', 'FNBCC', 'ACTIVE'),
  ('62729554117986312', 'CC', 'FNBRF', 'ACTIVE'),
  ('62417473486239799', 'CHQ', 'FNBCC', 'ACTIVE'),
  ('62404251458277038', 'CC', 'FNBRF', 'ACTIVE'),
  ('62719411557505878', 'TRN', 'FNBCC', 'ACTIVE'),
  ('62109145135566199', 'TRN', 'FNBRF', 'ACTIVE'),
  ('62569506531057629', 'CC', 'FNBCC', 'ACTIVE')
ON CONFLICT (account_number) DO NOTHING;

-- SCRUM-91: the mandate PROJECTION table is GONE and this file must not mint it
-- again. Its state is derived by the MRG views listed above and every other
-- attribute it carried lives on the MRR request spine. The services' 000
-- bootstraps still contain the immutable create changeset (applied on the
-- standing cluster, so it can never be rewritten); nine of them now end with a
-- guarded drop, and MRG drops it in its own 009-drop-mandate-projection.xml.
-- The DROP below keeps this canon file convergent: re-applying the bootstrap
-- over a database that still holds the table removes it rather than preserving
-- it. Safe on a fresh dcre_man, where it is a no-op.
DROP TABLE IF EXISTS mandate;

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
