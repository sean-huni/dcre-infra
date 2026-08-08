CREATE DATABASE IF NOT EXISTS dcre_col;
CREATE DATABASE IF NOT EXISTS agt_ops;
CREATE DATABASE IF NOT EXISTS dcre_man;
-- SCRUM-107: payments owns its own database. Until this existed, the payments
-- lane ran in the dcre-pay Kubernetes namespace while writing dcre_col, which
-- is namespace isolation without data isolation.
CREATE DATABASE IF NOT EXISTS dcre_pay;
-- SCRUM-107: hcs is a shared-reference CONTEXT with its own database, and it
-- earns one because it has a real upstream it ingests from (the Nager.Date API,
-- on a six-hour sync) and a single accountable owner. A database is named for
-- the context that OWNS it, so it takes the service's name rather than a topic
-- name.
--
-- THERE IS NO dcre_acs, and adding one back is a design reversal, not a fix.
-- A second such database was created on 2026-08-08 for `acs`, an account
-- registry, and RETIRED on 2026-08-09: unlike hcs it had no authoritative
-- source, no accountable owner, no ingestion of its own and no freshness
-- contract, which made it a shared integration database wearing the costume of
-- a bounded context, and it put a runtime dependency on the first validation
-- gate of all three families for 110 static fixture rows. Account reference
-- data now travels as ONE immutable versioned artifact under
-- fixtures/reference/account/ and each context materialises its OWN projection
-- into its OWN database. FIVE databases, not six.
CREATE DATABASE IF NOT EXISTS dcre_hcs;   -- hcs: public_holiday
