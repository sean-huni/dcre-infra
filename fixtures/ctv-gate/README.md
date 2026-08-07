# CTV mandate-gate fixtures (SCRUM-91 Task 11 Step 8)

Fixtures that drive `VerdictChain.projectionMandateVerdict` to BOTH of its verdicts
on live traffic, with `DCRE_CTV_MANDATE_SOURCE=projection`.

The gate's only predicate is a string equality between `tx_entry.mandate_ref` and
`man_ctv_view.mandate_ref`, followed by `"ACCP".equals(state)`. Client,
`creditor_account` and `contract_ref` are selected but never compared, so the book
only has to carry the right `mandate_ref` values and clear the account tier first.

## Files

| File | Role |
|---|---|
| `accounts.csv` | The ten debtor accounts seeded by `../seed/dcre_col_accounts.sql`, in the toolkit's account-CSV shape. Balances match the seed exactly so the affordability arm passes and execution reaches the mandate gate. |
| `mandates.csv` | Seven mandates whose `mandate_ref` values are real rows in `dcre_man.man_ctv_view`: six ACCP (the PASS cases) and `CHAMREQ00000012`, the only SUSPENDED row in the projection (the `FAIL_MANDATE_NOT_ACTIVE` case). `status` here only steers the generator's fault planner; the live verdict comes from the projection. |
| `FNBRF01_DCRERF2026072707365303.txt` | The V3 DC book cut from the two CSVs. |
| `FNBRF01_DCRERF2026072707365303.manifest.csv` | The generator's per-entry CTV expectation manifest. |

## Cut command

Run from `be/python/dcre/fnb_dcre_ctv_toolkit`. `--timestamp` was the UTC wall clock
at cut time; a fresh value is required on every re-cut, both to dodge AGT's
content-hash dedup and because CTV pins `AS OF SYSTEM TIME` in the batch execution
context, so replaying an old arrival dies on the CockroachDB replica GC threshold.

```
python3 generate_dcre_copybook.py \
  --accounts <infra>/fixtures/ctv-gate/accounts.csv \
  --mandates <infra>/fixtures/ctv-gate/mandates.csv \
  --flow dc --version 3 --count 8 --seed 20260727 \
  --timestamp 20260727073653 \
  --destination-id FNBRF01 --sender-id DCRE --file-type RF \
  --inactive-mandate-count 1 --unique-amounts \
  --output-dir <infra>/fixtures/ctv-gate
```

Verified green by `verify_ctv_fixtures.py` (structural checks, mandate coverage,
manifest diff CLEAN). Expected outcomes: `PASS=7`, `FAIL_MANDATE_NOT_ACTIVE=1`.

`--unique-amounts` is load bearing: several entries share an account and a
`contract_ref`, so without it two of them can collide on CTV's R-41 content hash and
be verdicted `FAIL_DUPLICATE_TX` before the mandate gate ever runs.

## Dropping it

Stage, then move atomically, so AGT never scans a partial file:

```
cp fixtures/ctv-gate/<book>.txt exchange/.staging-drop/
mv exchange/.staging-drop/<book>.txt exchange/fnbrf01/onhost-req/in/
```

## Resolved blocker (raised 2026-07-27, fixed since; verified 2026-08-07)

CRR ingested this book cleanly but CTV then failed in projection mode before writing any
`validation_log` row:

```
java.lang.ArrayIndexOutOfBoundsException: Index 8 out of bounds for length 8
  at org.postgresql.jdbc.TimestampUtils.parseDate(TimestampUtils.java:395)
  at za.co.fnb.dcre.ctv.data.repo.MandateProjectionDao.map(MandateProjectionDao.java:85)
```

`man_ctv_view.start_date` and `expiry_date` are `VARCHAR(8)` carrying COBOL `YYYYMMDD`, which is
the MSR contract, and `rs.getDate(...)` asks pgjdbc to parse them as `YYYY-MM-DD`.
`MandateProjectionDaoIT` declared its fixture columns as `DATE`, so the mismatch was invisible in
test: a fixture that could not express the production column type.

**Fixed.** `MandateProjectionDao.map` now reads both columns with `rs.getString` and parses them
through `CcyymmddDate.parse`. Confirmed on the running cluster on 2026-08-07: a book cut from
these CSVs passed CRR, CTV, CDE and CIR, and reached `DAG_COMPLETE` after CRW emitted.
