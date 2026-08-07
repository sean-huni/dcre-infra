CREATE DATABASE IF NOT EXISTS dcre_col;
CREATE DATABASE IF NOT EXISTS agt_ops;
CREATE DATABASE IF NOT EXISTS dcre_man;
-- SCRUM-107: payments owns its own database. Until this existed, the payments
-- lane ran in the dcre-pay Kubernetes namespace while writing dcre_col, which
-- is namespace isolation without data isolation.
CREATE DATABASE IF NOT EXISTS dcre_pay;
