-- Pre-create every service's Liquibase history (+lock) tables.
-- WHY: concurrent FIRST runs of the same service on a fresh database race on
-- CREATE TABLE <svc>_databasechangelog (the lock table does not exist yet, so
-- there is nothing to serialize the bootstrap); the loser crashes with
-- "relation already exists" (caught in the M7 straight-cycle e2e, 2026-07-13).
-- DDL matches what Liquibase 5.x itself creates; Liquibase adopts pre-existing
-- tables untouched. Idempotent: IF NOT EXISTS throughout.
-- Totals: 44 tables = 24 in dcre_col (12 services x 2) + 2 in agt_ops (rpt)
-- + 18 in dcre_man (9 M-services x 2).

CREATE TABLE IF NOT EXISTS crr_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS crr_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_crr_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS ctv_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS ctv_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_ctv_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS cir_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS cir_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_cir_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS cde_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS cde_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_cde_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS crw_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS crw_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_crw_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS ixr_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS ixr_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_ixr_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS sxr_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS sxr_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_sxr_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS pxr_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS pxr_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_pxr_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS prg_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS prg_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_prg_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS ais_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS ais_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_ais_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS hcs_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS hcs_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_hcs_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS rpt_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS rpt_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_rpt_databasechangeloglock PRIMARY KEY (id));

-- agt_ops section. rpt is the only module with Liquibase history in BOTH databases
-- (client-stats reads dcre_col above; report state lives in agt_ops).
-- This file is executed with --database=dcre_col (env-reset.sh step 6),
-- so the agt_ops pair must be database-qualified.
CREATE TABLE IF NOT EXISTS agt_ops.rpt_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS agt_ops.rpt_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_rpt_databasechangeloglock PRIMARY KEY (id));

-- dcre_man section: the M10 Mandates services (SCRUM-73). Executed with
-- --database=dcre_col (env-reset.sh step 6), so every pair must be
-- database-qualified, same as the agt_ops.rpt pair above.
CREATE TABLE IF NOT EXISTS dcre_man.mrr_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS dcre_man.mrr_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_mrr_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS dcre_man.mrv_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS dcre_man.mrv_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_mrv_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS dcre_man.mas_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS dcre_man.mas_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_mas_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS dcre_man.mit_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS dcre_man.mit_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_mit_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS dcre_man.mir_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS dcre_man.mir_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_mir_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS dcre_man.mrw_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS dcre_man.mrw_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_mrw_databasechangeloglock PRIMARY KEY (id));

-- SCRUM-91: the three mandate response-leg readers. They are three PARALLEL
-- token-picked entries on one route, which is exactly the concurrency shape that
-- triggered the 2026-07-13 history-table bootstrap race (two routes launching the
-- same service simultaneously both attempt CREATE TABLE <svc>_databasechangelog
-- before the lock table exists; the loser dies with 'relation already exists').
-- Pre-creating all three here is what makes their first concurrent run safe.
CREATE TABLE IF NOT EXISTS dcre_man.mix_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS dcre_man.mix_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_mix_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS dcre_man.msx_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS dcre_man.msx_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_msx_databasechangeloglock PRIMARY KEY (id));

CREATE TABLE IF NOT EXISTS dcre_man.mpx_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS dcre_man.mpx_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_mpx_databasechangeloglock PRIMARY KEY (id));

-- SCRUM-91: mar and msr are RETIRED. MAR split into the three per-leg readers
-- mix/msx/mpx (seeded above); MSR's projection, expiry sweep and suspension sweep
-- are derived views in MRG plus the mandate_override sink. Their history tables are
-- deliberately NOT seeded: a service that no longer exists must not be pre-minted,
-- and the dcre_man guard in env-reset.sh counts on this roster being exact.
-- Archived repos: github.com/sean-huni/dcre-mar, github.com/sean-huni/dcre-msr.

CREATE TABLE IF NOT EXISTS dcre_man.mrg_databasechangelog (
  id VARCHAR(255) NOT NULL, author VARCHAR(255) NOT NULL, filename VARCHAR(255) NOT NULL,
  dateexecuted TIMESTAMP WITHOUT TIME ZONE NOT NULL, orderexecuted INTEGER NOT NULL,
  exectype VARCHAR(10) NOT NULL, md5sum VARCHAR(35), description VARCHAR(255),
  comments VARCHAR(255), tag VARCHAR(255), liquibase VARCHAR(20), contexts VARCHAR(255),
  labels VARCHAR(255), deployment_id VARCHAR(10));
CREATE TABLE IF NOT EXISTS dcre_man.mrg_databasechangeloglock (
  id INTEGER NOT NULL, locked BOOLEAN NOT NULL, lockgranted TIMESTAMP WITHOUT TIME ZONE,
  lockedby VARCHAR(255), CONSTRAINT pk_mrg_databasechangeloglock PRIMARY KEY (id));
