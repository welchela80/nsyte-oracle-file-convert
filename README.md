# nsyte-oracle-file-convert

A small, self-contained pipeline for turning **Oracle Data Pump (`expdp`) dump files** into
**PostgreSQL** — and, optionally, normalizing the loaded tables into a clean canonical schema so
data from several different Oracle sources can be analyzed together.

It stands up a local Oracle (to read the proprietary `.dmp` files), a Python ETL, and a target
Postgres — all in Docker — and drives them with one script.

> **Why the round-trip through Oracle?** Data Pump `.dmp` files are a proprietary binary format;
> nothing can read them directly. The only supported way to extract their data is to `impdp` them
> into an Oracle database. This pipeline does that, then streams the tables out to Postgres.

---

## What one run does

`bash load_dump.sh '<dumpfile_pattern>' <SCHEMA> ['T1,T2,...']`

1. **Ensure** the Oracle directory objects, the target staging user (grants applied idempotently),
   and the stub packages/users the dump DDL references (`oracle-init/02_secmgr_stub.sql`).
2. **`impdp`** the dumpset into Oracle (data-only, tablespace-agnostic — see *Design notes*).
3. **Convert** each imported table to Postgres via the Python ETL (`oracledb` thin mode → `COPY`),
   creating a Postgres schema named after the Oracle schema (e.g. `mfom`, `nmdr`).
4. **Verify** row counts (Oracle vs Postgres) for every table.
5. **Free** the space in Oracle (drop the just-converted tables) so the next chunk fits under
   Oracle Free's 12 GB cap. Postgres keeps everything.

Progress is tracked in Postgres (`_mig.migration_state`), so the ETL is **resumable** — re-running
skips tables already done.

---

## Architecture

```
 .dmp files ──(bind mount /dumps)──►  Oracle Free 23ai        ──► Python ETL ──►  PostgreSQL
                                      (impdp: staging only,        (oracledb thin      (target:
                                       dropped after convert)       + COPY)             one schema
                                                                                        per source)
                          load_dump.sh  orchestrates all of the above, per dumpset.
```

Six containers (see `docker-compose.yml`):
- **oracle** — `gvenzl/oracle-free:23-slim`; the dump folder is mounted read-only at `/dumps`.
- **postgres** — `timescale/timescaledb-ha:pg18` (PG 18.4 + TimescaleDB), on the host's native port **5432** (services use host networking); the conversion target.
- **etl** — a tiny Python image running `migrate.py` (no Oracle client needed — `oracledb` thin mode).
- **pgadmin** — web UI at **http://localhost:5050** (desktop mode, no login; the `nmd` connection is
  preregistered — enter the DB password on first click).
- **opa** — Open Policy Agent at **http://localhost:8181**, serving the `nmd/authz` policy (an
  ABAC/OPA design for replacing the source SECMGR masking layer; see `policy/` and `sql/secmgr.sql`).
- **neo4j** — graph view of the `canonical` schema at **http://localhost:7474** (bolt on 7687).
  ~3.9M nodes / 9.2M relationships; (re)load with `etl/export_neo4j_csv.sh` + `neo4j-admin import`
  (see that script's header).

---

## Repo layout

```
├── README.md                 # this file
├── CLAUDE.md                 # full context for AI-assisted runs (hand this to Claude)
├── docker-compose.yml        # the 3-container stack
├── .env.example              # copy to .env; set DUMP_DIR
├── load_dump.sh              # the pipeline: one dumpset -> Postgres, end to end
├── oracle-init/
│   ├── 01_init.sql           # first-boot convenience (directory objects)
│   └── 02_secmgr_stub.sql    # stub packages/users the dump DDL references (see Design notes);
│                             #   applied by load_dump.sh phase 1 on every run
├── etl/
│   ├── migrate.py            # Oracle -> Postgres migrator (list / migrate / verify)
│   ├── load_xlsx.py          # Excel -> Postgres loader (schema "xlsx"; see its MANIFEST)
│   ├── survey_xlsx.py        # dump sheet structure of /xlsx files (to classify before loading)
│   ├── build_constraints.py  # rebuild source PK/UNIQUE/FKs in Postgres from dump-extracted DDL
│   ├── Dockerfile
│   └── requirements.txt
├── xlsx/                     # drop folder for .xlsx sources (mounted read-only into etl)
├── sql/
│   ├── normalize_example.sql # worked normalization template (raw -> canonical)
│   ├── canonical.sql         # THE canonical build: 8 cross-source entity tables (re-runnable)
│   ├── constraints_from_dumps.sql  # generated: the PK/UNIQUE/FK DDL applied to the DB
│   ├── secmgr.sql            # faithful rebuild of the source NNPI-masking layer (session-flag
│   │                         #   driven masking views over the raw tables)
│   └── secmgr_demo.sql       # runnable tour of where SECMGR masking applied
├── policy/                   # OPA/Rego — an ABAC design to replace SECMGR (opa service = PDP)
│   └── nmd/authz.rego        #   + authz_test.rego;  test: docker compose run --rm opa test /policy -v
├── state/                    # runtime artifacts (docker-written; gitignored)
└── docs/
    ├── RUNNING.md            # step-by-step manual (WSL and pure Linux), copy-paste
    └── NORMALIZATION.md      # the raw -> canonical pattern, explained
```

---

## Quickstart

```bash
cp .env.example .env          # then edit DUMP_DIR to your dump folder
docker compose up -d          # wait for `docker compose ps` to show oracle (healthy)
bash load_dump.sh 'MYDUMP_%U.dmp' MYSCHEMA
```
The full, careful walkthrough (including the Windows/WSL storage caveat and big-schema batching) is
in **[docs/RUNNING.md](docs/RUNNING.md)**.

---

## Design notes (why the flags are the way they are)

These were learned the hard way; they're baked into `load_dump.sh`:

- **`impdp` uses `transform=segment_attributes:n`** — strips the source tablespace/storage clauses so
  tables land in the staging user's default tablespace. Without it, every `CREATE TABLE` fails with
  `ORA-00959: tablespace ... does not exist` and nothing loads.
- **`exclude=statistics,index,constraint,ref_constraint,grant,trigger,rls_policy,fga_policy`** — we
  only need the table + its rows; indexes/keys can be added in Postgres if wanted. `rls_policy` is
  load-bearing: imported VPD policies reference security packages absent locally, and then every
  `SELECT` on the table fails (`ORA-28110`) so nothing converts.
- **Stub principals (`oracle-init/02_secmgr_stub.sql`)** — the dumps' table DDL references users and
  packages that only exist in the source DB: virtual columns call `SECMGR`/`VSB` masking functions
  (`ORA-00904`), and `GRANT REFERENCES` grantees must exist (`ORA-01917`) — either aborts
  `CREATE TABLE` and the table **silently never loads**. The stub file creates bare users and
  NULL-returning packages so the real data loads (derived mask columns arrive NULL).
  `load_dump.sh` applies it on every run; it's idempotent.
- **Directory is `NMD_DUMPS`, not `DUMP_DIR`** — `DUMP_DIR` collides with an Oracle 23ai built-in.
- **Log goes to `NMD_LOG` (`/tmp`)** — the dump mount is read-only, so impdp can't write its log there.
- **Drop-after-convert (+ datafile shrink)** — Oracle Free caps user data at **12 GB** and never
  reclaims automatically. The pipeline drops each converted chunk (`CASCADE CONSTRAINTS`, plus stray
  Data Pump master tables and recyclebin leftovers), then shrinks `users01.dbf` back to 1 GB — the
  cap counts the file's *allocated* size, which dropping tables alone never reduces. Set
  `KEEP_ORACLE=1` to keep the Oracle copy for inspection.
- **Charset row loss is possible** — these dumps are `WE8MSWIN1252`; converting to the local DB's
  UTF-8 can expand characters (e.g. the `0x96` en-dash) past a `VARCHAR2(n BYTE)` limit. impdp
  **skips those rows** (`ORA-02374`/`ORA-12899`, "N out of M rows") rather than failing — check the
  log tail when exactness matters.
- **Corrupt legacy dates are survivable** — a stored year-0 `DATE` would kill a whole table's
  conversion (Python `datetime` can't hold it), so `migrate.py` fetches temporal columns as text
  server-side and NULLs year ≤ 0 values, printing a `!` warning with the count.
- **NUL bytes in text are stripped** — legacy free-text columns can embed `0x00`, which Postgres
  `text` rejects outright (`invalid byte sequence for encoding "UTF8"`); `migrate.py` removes them
  during encoding.
- **`RAW(16)` keys become `uuid`** — the sources key nearly everything on `SYS_GUID()` values
  (`*_sa_id` columns). `migrate.py` maps `RAW(16)` → `uuid` directly; the already-loaded schemas
  were converted in place (`etl/convert_uuid.py`, with `etl/check_uuid_candidates.py` first
  verifying every candidate column holds only 16-byte values). 8-byte `hist_*.xid` transaction
  ids stay `bytea`.

### Three hard constraints to know
- **A Data Pump *job* imports as a whole set.** Every dumpfile of a job must be present and fully
  written before `impdp`. A partial set → `file not found` / fatal errors. Group by *job*.
- **Big schemas exceed the 12 GB cap.** For a schema too large to hold at once, import it **a few
  tables at a time** (the script's 3rd argument) — each batch converts then frees Oracle. Postgres
  accumulates the full result. (The complete dumpset must still be present on disk. Note the dump's
  on-disk size is compressed — the real data can be 3×+ larger.)
- **A "clean" verify doesn't prove a table loaded.** `verify` compares tables that exist in Oracle;
  a table whose `CREATE` failed exists in *neither* DB and is invisible to it. After a big load,
  reconcile `_mig.migration_state` against the expected table list.

---

## Excel sources (optional)

Spreadsheets skip the Oracle round-trip: drop `.xlsx` files into `xlsx/`, inspect them with
`docker compose exec -T etl python survey_xlsx.py`, list the tabular sheets in the `MANIFEST`
of `etl/load_xlsx.py`, and run `docker compose exec -T etl python load_xlsx.py`. Each sheet
becomes a table in the Postgres schema **`xlsx`** (all-text columns, snake_cased headers,
provenance in a table comment, progress in `_mig.migration_state`). Document-style sheets
(use-case forms, narratives) don't belong in the manifest — they aren't tables.

---

## Restoring PK/FK relationships (optional)

The load imports data without constraints, but the dumps carry the source's own key DDL.
`etl/build_constraints.py` restores it: extract per dumpset with
`impdp ... sqlfile=... include=constraint,ref_constraint`, put the files in `state/`, and run
`docker compose exec -T etl python build_constraints.py '/state/cons_*.sql'`. Keys apply first,
then FKs as `NOT VALID`, then each FK is validated — ones whose data has orphans (rows impdp
skipped, cross-export drift) stay `NOT VALID` instead of being dropped. The DDL applied to this
DB is checked in as `sql/constraints_from_dumps.sql` (~800 keys, ~1,870 FKs, 94 of them
cross-schema). Caveat: Data Pump inlines some partitioned tables' PKs into `CREATE TABLE`,
which `include=constraint` misses — see CLAUDE.md for the sweep that catches those.

---

## Normalization (optional stage)

Loading gives you a faithful 1:1 copy per source (schemas `mfom`, `nmdr`, `vsb`, `xlsx`). To analyze
multiple sources *together*, you then map them into a shared **canonical** schema: clean column
names/types, standardize codes, drop secrets, and tag each row with `source_system`.

**`sql/canonical.sql` is the live build** — re-runnable (drops + rebuilds the schema), producing 11
cross-source entity tables (~39M rows): `users`, `activities`, `ships`, `maintenance_actions`
(4 sources unified on JCN, incl. AWN's ticket system), `maintenance_narratives`,
`maintenance_comments`, `availabilities`, `action_taken_codes`, `equipment` (17M: MFOM's
class-wide config model + ASI A1 + DDG-57 xlsx; ~98% of AWN RICs resolve in the MFOM model),
`supply_requisitions` (AWN parts orders, joinable to their tickets), and `inspections`
(INSURV findings, 1:1 with AWN tickets). Run it with
`docker exec -i nmd-postgres psql -U nmd -d nmd -v ON_ERROR_STOP=1 < sql/canonical.sql`.
`sql/normalize_example.sql` is the original single-table worked example; the pattern and rules are
in **[docs/NORMALIZATION.md](docs/NORMALIZATION.md)**.

---

## Working with Claude

`CLAUDE.md` contains everything needed to resume this with AI assistance — architecture, the exact
commands, the failure modes and their fixes, and how to plan a big-schema batch load. Point Claude at
it and describe what you're loading.
