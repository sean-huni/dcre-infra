-- THIS FILE IS THE CANON for the dcre_man shared-core shapes (SCRUM-73, M1/M2).
-- Every M-service's 000-man-core-bootstrap changelog (mrr et al.) must stay
-- byte-equivalent in SHAPE with this file: same tables, columns, types, uniques,
-- indexes and seed rows. Source of the shape: mrr 000-man-core-bootstrap.xml
-- (branch SCRUM-74-feat-mrr); drift in either direction is a review defect.
--
-- WHY: whichever M-service boots first would otherwise mint these shared shapes,
-- and concurrent FIRST boots race on the CREATEs. env-reset.sh applies this file
-- BEFORE any service boots (--database=dcre_man); the services' MARK_RAN-guarded
-- 000 changesets then converge as no-ops in any boot order.
--
-- ==========================================================================
-- SCRUM-107, 2026-08-08: account AND account_type ARE NO LONGER HERE.
--
-- They left this file and INFRA DOES NOT SEED ACCOUNT DATA AT ALL ANY MORE.
--
-- For one day they lived in a shared dcre_acs database owned by an `acs`
-- service. That service was retired on 2026-08-09: it had no authoritative
-- source, no accountable owner, no ingestion of its own and no freshness
-- contract, so it was a shared integration database wearing the costume of a
-- bounded context. Account reference data now travels as ONE immutable
-- versioned artifact (fixtures/reference/account/) and each context
-- materialises its OWN projection into its OWN database, keeping its OWN NOT
-- NULL constraints rather than relaxing them to a nullable union.
--
-- account therefore EXISTS in dcre_man, and legitimately: it is the mandates
-- PROJECTION, filled by MRV's own loader job, not a copy of somebody else's
-- table. cutover-v1.sh asserts exactly that placement, by relation name.
--
-- TWO CONSEQUENCES, STATED PLAINLY RATHER THAN LEFT TO BE DISCOVERED:
--
-- 1. The M-services' MARK_RAN 000 bootstraps still CREATE account and
--    account_type in dcre_man, because those changelogs live in the mandates
--    repositories and are not this repository's to change. Infra no longer
--    pre-applies them, so on a fresh dcre_man those tables are now minted by
--    whichever M-service boots first, EMPTY. MRV resolves the debtor account
--    against account, so mandate instructions fail FAIL_ACCOUNT_NOT_FOUND until
--    MRV's LOADER JOB has run and materialised the artifact's MANDATES
--    projection into it. Running that job is now part of bringing an
--    environment up, and it is the step that used to be this file's job.
--    account_type is NOT part of the artifact: it is a closed vocabulary the
--    mandates changelogs seed, and no loader touches it.
--
-- 2. Not pre-applying those two CREATEs re-opens the concurrent-first-boot race
--    they existed to prevent: nothing serialises two M-services minting the
--    same shared table, and the loser crashes with "relation already exists"
--    (M7 straight-cycle e2e, 2026-07-13). The correct home for that fix is
--    Liquibase's own lock in each service's changelog, or a warm-up that runs
--    each stage once serially before parallel traffic. It is deliberately NOT
--    re-solved here by infra pre-creating tables, which is the same shape as
--    the Liquibase history seed the owner ruled out on 2026-08-08.
-- ==========================================================================
--
-- WHAT REMAINS is the mandates-only shared core that has no other owner: the
-- mandate_reason_code reference table, and the guarded drop of the retired
-- mandate projection. The mandate PROJECTION is not part of this core either:
-- SCRUM-91 deleted the mandate state writer, its only writer, and replaced it
-- with the MRG-derived mnd_ext_status / mandate_effective_status /
-- mandate_current_status views.
--
-- Idempotent throughout: IF NOT EXISTS creates; the seed is a per-row
-- INSERT ... ON CONFLICT DO NOTHING on the BUSINESS identity (code).

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
