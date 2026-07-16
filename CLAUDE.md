# CLAUDE.md — context for AI-assisted runs

Hand this file to Claude (or any assistant) when running this pipeline. It contains the architecture,
the exact commands, the failure modes and their fixes, and how to plan larger loads. Pair it with the
user telling you **what they're loading** (which dumpset, which schema) and **which environment**
(WSL + Docker Desktop, or a Linux server).

---

## What this project does

Converts **Oracle Data Pump (`expdp`) `.dmp` files → PostgreSQL**, then optionally **normalizes** the
loaded tables into a shared `canonical` schema so multiple Oracle sources can be analyzed together.
Side paths: **Excel sources** load directly into schema `xlsx` (etl/load_xlsx.py), and the source's
**PK/UNIQUE/FK constraints** can be rebuilt from the dumps' own DDL (etl/build_constraints.py) —
both covered in sections below.

`.dmp` files are proprietary binary — they can only be read by importing (`impdp`) into an Oracle DB.
So the flow is: **impdp into a local Oracle → stream tables out to Postgres → (optional) normalize**.

The whole thing is Dockerized and driven by `load_dump.sh`.

---

## The stack (docker-compose.yml)

- **oracle** — `gvenzl/oracle-free:23-slim`. PDB `FREEPDB1`, `SYSTEM`/`$ORACLE_PASSWORD` (default `oracle`).
  Dump folder mounted read-only at `/dumps`. **Free edition caps user data at 12 GB.**
- **postgres** — `timescale/timescaledb-ha:pg18` (PG 18.4 + TimescaleDB; the **-ha Ubuntu/glibc**
  variant on purpose — the default TimescaleDB image is Alpine/musl, which silently breaks glibc
  text collation), published on host port **5432**, db/user/pass from `.env`
  (default `nmd`/`nmd`/`nmd`). Cluster history: `pg_upgrade`d 16→18 (copy mode) into the
  `pg18_data` volume (mounted at `/var/lib/postgresql`), then switched to the TimescaleDB image
  in place — volume chown'd 999→1000 (image uid differs), 187 text-keyed indexes REINDEXed for
  the glibc 2.41→2.35 collation change, `REFRESH COLLATION VERSION` applied.
- **etl** — Python image, `oracledb` **thin mode** (no Oracle client) + `psycopg2`. Runs `migrate.py`.

Bring up: `docker compose up -d` → wait for `docker compose ps` to show **oracle (healthy)**.

---

## The pipeline command

```
bash load_dump.sh '<dumpfile_pattern>' <SCHEMA> ['T1,T2,...']
```
Phases it runs (each prints `==> [n/5] ...`):
1. ensure Oracle directory objects (`NMD_DUMPS`=/dumps, `NMD_LOG`=/tmp), create the `<SCHEMA>` staging
   user, and apply `oracle-init/02_secmgr_stub.sql` (stub packages/users the dump DDL references).
2. `impdp` the dumpset into Oracle (data-only; flags below). Prints the impdp **log tail**.
3. `migrate.py migrate` — convert the schema's tables to Postgres (schema = lowercased `<SCHEMA>`).
4. `migrate.py verify` — Oracle vs Postgres row counts per table.
5. drop the converted tables + stray Data Pump master tables in Oracle (reclaim the 12 GB). `KEEP_ORACLE=1` skips this.

`migrate.py` subcommands (also usable directly via `docker compose exec -T etl python migrate.py ...`):
- `list --schema S` — tables + row estimates
- `migrate --schema S [--tables a,b] [--force] [--limit N]` — resumable (skips tables marked done in `_mig.migration_state`)
- `verify --schema S` — count comparison

Type mapping is generic/lossless-leaning: `NUMBER`→int/bigint/numeric, char/CLOB→`text`, `DATE`/`TIMESTAMP`→`timestamp(tz)`, **`RAW(16)`→`uuid`** (these are `SYS_GUID()` keys — verified empirically: every 16-byte RAW column held only 16-byte values; the sole exceptions were 8-byte `hist_*.xid` transaction ids, which stay `bytea`), other `RAW`/`BLOB`→`bytea`. LOBs fetched inline (`oracledb.defaults.fetch_lobs=False`), data streamed with `COPY`. Temporal columns are fetched as text via server-side `TO_CHAR` — oracledb thin mode otherwise decodes them into Python `datetime` client-side, and one corrupt year-0 date kills the whole table; unrepresentable dates (year ≤ 0) become NULL with a printed `!` warning.

---

## Hard constraints (explain these before they bite)

1. **A Data Pump *job* imports as a whole set.** Every dumpfile of a job must be present and complete
   before `impdp`. A partial/incomplete set → `ORA-31640 / file not found` or a fatal error. Group by job;
   use the `%U` wildcard for multi-file jobs.
2. **12 GB Oracle cap, cumulative — and it counts *allocated datafile size*, not used space.**
   Imports accumulate and Oracle never auto-reclaims. If it fills, even the impdp master table fails
   (`ORA-12954`). The script drops each chunk after converting — but a schema larger than 12 GB must
   be imported **a few tables at a time** (3rd arg), converting+freeing between batches. Postgres
   accumulates the whole result. Crucially, `DROP ... PURGE` frees space *inside* `users01.dbf` but
   never shrinks the file, so multi-batch runs balloon it until later batches die with `ORA-12954`
   on an apparently empty DB — the script now does `ALTER DATABASE DATAFILE ... RESIZE 1G` in phase 5.
3. **`verify` can't see tables that failed to create.** It compares only tables present in Oracle; a
   table whose `CREATE` failed (stub principals, cap hit) exists in *neither* DB and shows as
   "All counts match". Cross-check `_mig.migration_state` (`status='done'` count) against the
   expected table list, and read the impdp log for `ORA-39083` / `ORA-31693`.

---

## impdp flags (already in the script — needed, don't drop them)

- `transform=segment_attributes:n` — strip source tablespace/storage, else every `CREATE TABLE` hits
  `ORA-00959 tablespace does not exist`.
- `exclude=statistics,index,constraint,ref_constraint,grant,trigger,rls_policy,fga_policy` — we only
  need tables+data. `rls_policy` matters: imported VPD policies reference `SECMGR` packages that
  don't exist locally, and then **every `SELECT` on the table fails** with `ORA-28110`.
- `directory=NMD_DUMPS` — **not** `DUMP_DIR` (collides with an Oracle 23ai built-in → wrong path).
- `logfile=NMD_LOG:...` — dump mount is read-only; logs must go to a writable dir (`/tmp`).
- `table_exists_action=replace`.

## Stub principals (oracle-init/02_secmgr_stub.sql — applied by phase 1 every run)

The dumps' table DDL references principals that don't exist in the throwaway Oracle, and each one
**aborts `CREATE TABLE`** (the table then silently never loads — see the verify caveat below):

- **Virtual generated columns** calling `SECMGR.SECMGR_UTIL.*` / `VSB.API_DATA_3M_NARRATIVE.*`
  (the NNPI/UNNPI data-masking layer) → `ORA-00904 invalid identifier`. Stubbed with
  `DETERMINISTIC` functions returning NULL, so real column data loads and the derived
  mask columns arrive NULL in Postgres.
- **`GRANT REFERENCES ... TO <user>`** bound to the table create (`exclude=grant` does NOT
  suppress these) → `ORA-01917 user or role does not exist`. Fixed by pre-creating the
  grantees (`NILANK`, `NMDR`, `NMDR_WF`, `ROBIN_JOSEY_RO`, `VSB`, `ETL_STAGE`) as bare users.

The stub file is idempotent and `load_dump.sh` pipes it in on every run — the
`oracle-init/` auto-run only happens on **first** volume init, so never rely on that alone.

---

## Environment notes

- **WSL + Docker Desktop:** reading dumps from `/mnt/c/...` (the Windows mount) is **slow and hangs on
  large dumps** (impdp's random reads stall; `docker stats` shows frozen Block I/O + idle CPU). **Fix:
  copy the dumps onto the WSL filesystem** (e.g. `~/dumps`), set `DUMP_DIR` to that Linux path, and run
  `docker compose` from WSL. This is the single most important perf/reliability step for big dumps.
- **Pure Linux server:** no such issue — point `DUMP_DIR` at a local folder; docker I/O is native.
- If an import wedges and `KILL_JOB` freezes (uninterruptible I/O wait), **`docker compose restart oracle`**
  clears it; then drop leftover `SYS_IMPORT_%` master tables.

---

## How to help (typical asks)

- **Diagnose a failed/short import:** read the impdp **log tail** the script prints, and
  `migrate.py verify`. Map the `ORA-` code using the table below. Don't guess — the log tail is authoritative.
- **Plan a big-schema load:** get per-table sizes from the dump itself — run a metadata-only import
  with `content=metadata_only keep_master=yes`, then read `SIZE_ESTIMATE` per `TABLE_DATA` object
  from the retained `SYSTEM.SYS_IMPORT_%` master table (uncompressed bytes; treat as rough — it can
  be several× off for LOB-heavy tables). Don't use `migrate.py list` row estimates: stats are
  excluded at import, so `num_rows` is always `?`. Bin-pack tables first-fit-decreasing into batches
  of **≤ ~8.5 GB** and ≤ ~60 tables (impdp `tables=` arg length), then run the sequence of
  `load_dump.sh ... 'T1,T2'` calls — with stdin from `/dev/null` if driven from a loop. Resumable,
  so batches are independent. Drop the metadata-only tables + master before starting the real batches.
- **Write a normalization:** follow `docs/NORMALIZATION.md` — inspect `\d schema.table`, apply the
  sensible-default rules, target `canonical.*`, always add `source_system`. Deliver as a `sql/*.sql` file
  run via `psql < file`.
- **Writing files on Windows:** the user's tooling may block writing into OneDrive/redirected `Documents`
  folders. Stage generated files in a plain writable dir (e.g. `C:\some\path`) and have the user copy them
  into their repo, rather than assuming you can write into `Documents\...`.

---

## Failure → fix table

| `ORA-` / symptom | Meaning | Fix |
|---|---|---|
| `ORA-31640 / ORA-27037 file not found` | dumpfile missing/incomplete or wrong `%U` pattern | ensure all of that job's files present; `docker compose exec -T oracle ls /dumps` |
| `ORA-00959 tablespace does not exist` | missing transform | keep `transform=segment_attributes:n` |
| `ORA-12954 exceeds 12 GB` | Oracle full | script frees per run; else drop `SYS_IMPORT_%` + converted tables; batch big schemas |
| `ORA-12954` but `dba_segments` shows the DB nearly empty | `users01.dbf` *allocation* ballooned by earlier batches (drops don't shrink it) | `ALTER DATABASE DATAFILE '/opt/oracle/oradata/FREE/FREEPDB1/users01.dbf' RESIZE 1G;` (phase 5 now does this) |
| `ORA-39083 TABLE ... ORA-00904 "SECMGR"...` (or `"VSB"...`) | virtual column calls a missing masking package → **table silently not created** | apply `oracle-init/02_secmgr_stub.sql` (phase 1 does); re-run the batch |
| `ORA-39083 TABLE ... ORA-01917 user or role 'X' does not exist` | `GRANT REFERENCES` grantee missing → **table silently not created** | add user X to the stub file; re-run the batch |
| `ORA-28110 policy ... has error` during convert | imported VPD/RLS policy references missing package | `exclude=rls_policy` (now in script); for already-imported tables `DBMS_RLS.DROP_POLICY` |
| `ORA-02374 conversion error` / `ORA-12899 value too large` in impdp log | WE8MSWIN1252→UTF8 expands bytes (e.g. `0x96` dash) past `VARCHAR2(n BYTE)` | rows are **skipped, not fatal** — impdp reports `N out of M rows`; note the loss (~52 rows across MFOM+NMDR) |
| `ORA-31693 ... skipped` + `ORA-14400 no partition found for inserted partition key` | table is **reference-partitioned**; a parent row lost to charset skips → child partition can't resolve → impdp aborts the **entire** table's data (millions of rows lost to a few missing parents; table then looks "empty in source") | pre-create a plain non-partitioned copy of the table (no FK/partitioning; virtual cols OK — stubs exist), then `impdp content=data_only table_exists_action=append tables=SCHEMA.TABLE`; convert with `--force`, re-add PK/FK (FK stays NOT VALID over the orphans) |
| table shows 0 rows after import — is it really empty in the dump? | don't guess | run `impdp ... sqlfile=... keep_master=yes` and check the master's `DUMP_LENGTH`/`COMPLETED_ROWS` per `TABLE_DATA` object — actual bytes/rows in the dumpfile (SIZE_ESTIMATE is stats-based and unreliable) |
| `ORA-31693 ... skipped` + `ORA-39840 data stream format error` | that table's direct-path stream trips the decoder (bad segment / format quirk); deterministic | re-import just that table with `access_method=external_table` — different decode path, recovers all but the corrupt chunk |
| convert dies `year 0 is out of range` | corrupt legacy DATE (year 0) that Python datetime can't hold | handled: migrate.py fetches temporal cols via `TO_CHAR` and NULLs year<=0 (prints a `!` warning) |
| convert dies `invalid byte sequence for encoding "UTF8": 0x00` | NUL bytes embedded in legacy free-text | handled: `enc()` strips `\x00` (PG text can't hold NUL) |
| `ORA-39083 ... FGA_POLICY ... SECMGR` | harmless audit metadata | excluded now (`fga_policy`); ignore if seen |
| impdp hangs, frozen Block I/O, idle CPU | slow `/mnt/c` mount (WSL) | move dumps to WSL fs; never read big dumps from `/mnt/c` |
| `KILL_JOB` won't return | stuck worker | `docker compose restart oracle` |
| verify shows `pg=—` or mismatch | table didn't import / convert | re-check impdp log tail for that table; re-run its batch with `--force` |
| verify says **All counts match** but tables are missing | verify only sees tables that exist in Oracle | compare `_mig.migration_state` done-count to the expected list |
| batch loop stops after first iteration | `docker compose exec` ate the `while read` loop's stdin | run inner command `</dev/null`, read the loop on FD 3 |

---

## Rebuilding PK/FK constraints (etl/build_constraints.py)

The load excludes constraints, but the dumps carry the source's own PK/UNIQUE/FK DDL. To restore it:
extract per dumpset with `impdp ... sqlfile='NMD_LOG:cons_X.sql' include=constraint,ref_constraint`,
copy the files to `/state`, then `docker compose exec -T etl python build_constraints.py '/state/cons_*.sql'`.
It applies keys first, then FKs as `NOT VALID`, then validates each — FKs whose data has orphans
(rows impdp skipped on charset errors, cross-export drift) STAY `NOT VALID` rather than being dropped;
source-DISABLEd constraints are never validated. Caveat: `include=constraint` misses PKs that Data Pump
inlines into `CREATE TABLE` on partitioned tables — sweep the full-DDL sqlfiles for
`CONSTRAINT "X" PRIMARY KEY` afterwards (see sql/constraints_from_dumps.sql, the applied result:
~800 keys + ~1,860 FKs incl. 94 cross-schema mfom↔vsb↔nmdr links). The xlsx schema has no source
DDL — its keys are data-inferred (uniqueness-tested before adding).

## Excel sources (etl/load_xlsx.py)

Spreadsheets skip Oracle entirely: drop files in `xlsx/` (mounted read-only at `/xlsx` in the etl
container), run `etl/survey_xlsx.py` to see sheet structure, add tabular sheets to the `MANIFEST`
in `etl/load_xlsx.py`, then `docker compose exec -T etl python load_xlsx.py`. One table per sheet
in Postgres schema `xlsx`, all columns text (raw 1:1 — typing happens at normalization), snake_cased
headers, provenance in a table comment, progress in `_mig.migration_state` under `src_schema='XLSX'`
(resumable; `--force` / `--only t1,t2` to redo). Don't manifest document-style sheets (use-case
forms, narratives) — they aren't tables.

## State model

- Raw per-source data → Postgres schemas named after the Oracle schema (`mfom`, `nmdr`, `vsb`, …);
  Excel sources → schema `xlsx`; the SQL Server AWN database → schema `awn` (loaded from the
  gfi-convert project's pre-translated pg dumps — plain `psql -f`, no Oracle round-trip; its T-SQL
  compat shims/operators were rescoped from `public` into `awn` at load time).
- Migration progress → `_mig.migration_state` in Postgres (resume/skip logic; xlsx loads use
  `src_schema='XLSX'`).
- Source PK/UNIQUE/FK constraints → rebuilt in Postgres from dump DDL (`sql/constraints_from_dumps.sql`
  is what's applied; FKs with orphaned data are present but `NOT VALID`).
- Normalized data → `canonical.*` in Postgres.
- Oracle is **staging only** — nothing persists there long-term (dropped after each convert).

## SWLIN hierarchy + R visualization (added 2026-07-15)

- **`canonical.swlin_hierarchy`** (built by `sql/swlin_hierarchy.sql`, re-runnable): nearest-ancestor
  (longest-prefix) tree over the 4,727 real SWLIN codes in `canonical.equipment` (~18K `T%`
  "CONFIGURATION PLACE HOLDER" codes excluded, junk `-----` kept out at query time). Columns:
  `swlin, parent, root, depth, path (text[]), equipment_rows, maint_actions, nomenclature`
  (most common real equipment name; PLACE?HOLDER/SEE CDM names filtered; 3,543/4,727 named —
  some are still generic "FOR REPORTING…" strings). 431 roots, max depth 5, 91% of nodes linked.
- **Key join fact:** `equipment.swlin = equipment.eswbs` on 99.6% of rows, so
  `maintenance_actions.eswbs` joins straight to the hierarchy — never join maintenance to
  `equipment` on `(eswbs, eic)`: that pair averages ~235 equipment rows (max 257K) → massive fanout.
- **R scripts** (`r/`): `render_swlin_tree.R` = headless (Rscript, writes `r/out/`:
  interactive collapsibleTree HTML + dendrogram/rollup PNGs); `visualize_swlin_tree.R` = same
  views for interactive RStudio use. Tree UX: synthetic super-root + first-char buckets ("2xx"),
  leaves labelled `SWLIN · nomenclature`, HTML tooltips with counts. R 4.5 packages installed from
  P3M noble binaries — **must set `HTTPUserAgent` in `options()` or P3M silently serves source
  tarballs** (`fs` then fails on missing libuv headers).
- **`.claude/launch.json`**: preview servers — `swlin-tree` (:8799, python http.server over
  `r/out`), `pgadmin` (:5050), `neo4j` (:7474), `opa` (:8181).

## Current load state (as of 2026-07-13)

Loaded and verified in Postgres: **mfom** (15 tables, ~42M rows), **nmdr** (518 tables, ~380M rows,
83 GB — junk tables excluded), **vsb** (13 tables, ~14.8M rows), **xlsx** (12 tables, ~418K rows),
**awn** (103 tables + 99 views, ~635K rows — from SQL Server via gfi-convert; PK/FK/indexes came
with the dump; 45 tables empty in source; 6 views broken in source, kept as comments).
Constraints applied: ~506 PKs, ~300 uniques, ~1,867 FKs (94 cross-schema; 20 left `NOT VALID`).
Not loaded (deferred): `NMDR_EXP_2_%U.dmp` → ETL_STAGE (172 tables, regional ESR snapshots),
`NMDR_EXP_METADATA_ECXLD%U.dmp` (~48 empty `*_ATTACH` shells), and 4 document-style use-case
workbooks in `xlsx/`. Known row-loss caveats (charset/corrupt-date/NUL handling) are detailed in
the failure table above and in git history.
