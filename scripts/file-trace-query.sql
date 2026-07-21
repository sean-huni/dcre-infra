-- SCRUM-58 file-trace killer query (spec docs/specs/2026-07-16-file-trace-design.md section 3).
--
-- ONE saved cross-DB statement that resolves ANY boundary file name a prod supporter holds to
-- its client, direction, kind (format), route and the ordered step timeline. There is NO persisted
-- cross-DB view (the deprecated cluster-wide sql.cross_db_views.enabled stays OFF on the shared
-- cluster); ad-hoc 3-part-name cross-DB SELECTs work by default, which is what this is.
--
-- RUN AS rpt_internal (or root). The four rpt.* views are gated
-- `WHERE current_user IN ('rpt_internal','root')`, so any client datasource role sees zero rows.
--
--   cockroach sql --database=dcre_col --user=rpt_internal ...   (see the runbook in README.md)
--
-- The connected database is passed explicitly (ops-scripting rule) but is otherwise irrelevant:
-- every table is reached through its fully-qualified `<db>.rpt.<view>` name.
--
-- ==============================  :fname  USAGE  ==============================
-- :fname is a PLACEHOLDER for the bare basename, written as a single-quoted SQL string literal,
-- e.g.  'FNBCC01_DCRECC2026071410000001_onhost-req_RESP.txt'.  cockroach sql has no psql-style
-- `:var` binding, so replace BOTH occurrences of :fname below by hand, OR let
-- scripts/audit-file-trace.sh substitute it for you (it reads this exact file).
--
-- Works for ANY file class: inbound copybook, CIR RESP, pain.008, ISR/SBSR/PBSR reply, PSR /
-- heartbeat, outcomes/ seam name, duplicate re-delivery, or a quarantined name.
--
-- PREFIX NOTE (error/ and duplicates/ dirs): those on-disk names carry a '<uuid>_' claim prefix,
-- and after the quarantine row-id fix the uuid IS the arrival/claim id. The owner tables store the
-- BARE name, so either (a) strip the '<uuid>_' prefix and paste the bare name as :fname, or
-- (b) paste the uuid straight into the arr CTE as an extra `SELECT '<uuid>'::UUID`. The audit
-- script strips a leading strict-UUID prefix automatically.
-- ============================================================================
WITH matched AS (
  SELECT * FROM dcre_col.rpt.v_file_index   WHERE file_name = :fname
  UNION ALL
  SELECT * FROM agt_ops.rpt.v_ops_file_index        WHERE file_name = :fname
),
arr AS (
  SELECT arrival_id AS aid FROM matched WHERE arrival_id IS NOT NULL
  UNION
  SELECT related_arrival_id FROM matched WHERE related_arrival_id IS NOT NULL
),
jobs AS (
  SELECT DISTINCT job_name FROM matched WHERE job_name IS NOT NULL
)
-- CRDB adjustment (verified live 2026-07-16, cockroach v26.2.3): CockroachDB rejects
-- `ORDER BY ... NULLS LAST` under `SELECT DISTINCT` (SQLSTATE 42P10), and its ASC default is
-- NULLS FIRST (the opposite of PostgreSQL). To preserve the spec's intent -- a flow-less
-- "facts only" row sorts LAST, the step timeline reads top-down chronologically -- the DISTINCT
-- is wrapped and NULLS LAST is applied in the outer ORDER BY. Otherwise byte-verbatim spec 3.
SELECT * FROM (
  SELECT DISTINCT m.file_name, m.client, m.direction, m.kind, m.route, m.state, m.source_table,
         t.step, t.step_at, t.detail
  FROM matched m
  LEFT JOIN (
    SELECT arrival_id, job_name, step, step_at, detail FROM agt_ops.rpt.v_ops_flow
    UNION ALL
    SELECT arrival_id, job_name, step, step_at, detail FROM dcre_col.rpt.v_flow_trace
  ) t ON t.arrival_id IN (SELECT aid FROM arr)
      OR t.job_name  IN (SELECT job_name FROM jobs)    -- clock-scoped flows (PSR, seams) join on job identity
) z
ORDER BY z.step_at NULLS LAST;
-- One result set: client, direction, kind (format), route, state, and the ordered step sequence
-- with timestamps -- ARRIVED/QUARANTINED/DUPLICATE_REDELIVERY -> <STAGE>_INTENDED ->
-- <STAGE>_<OUTCOME> (ops) interleaved with CRR_INGESTED -> CTV_VALIDATED -> CIR_RESP_STAGED/
-- WRITTEN -> CRW_PLANNED/CRW_VISIBLE -> IXR/SXR/PXR_REPLY -> PRG_REPORTED -> RPT_OUTCOME (business).
-- Zero rows == the file resolves to NO owner record: an untraceable file (the audit-gate red condition).
