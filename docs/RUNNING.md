# Running the pipeline — step by step

A copy‑paste manual for converting Oracle Data Pump dumps to PostgreSQL, from either a **WSL**
terminal (Windows + Docker Desktop) or a **pure Linux** terminal. Commands are identical unless a
step is marked **[WSL]** or **[Linux]**.

Placeholders: replace `USER` with your username, `MYSCHEMA` with the Oracle schema in your dump, and
the dump patterns with your filenames. Examples use the NMD data (`MFOM`, `NMDR`).

---

## 0. Prerequisites

- **Docker** running.
  - **[WSL]** Docker Desktop with WSL integration enabled. Run everything from a WSL shell.
  - **[Linux]** Docker Engine + the compose plugin.
- Disk: room for your dumps **plus** Oracle's working space (Oracle Free caps at 12 GB user data).
- Your `.dmp` files, grouped by export **job** (all files of a job together).

---

## 1. Configure

```bash
cd /path/to/nsyte-oracle-file-convert
cp .env.example .env
```
Edit `.env` and set `DUMP_DIR` (where your `.dmp` files live) — see step 2 for the important
Windows/WSL detail. The other values (passwords, PG db name) are fine as-is for local use.

---

## 2. Put the dump files where Docker can read them fast

This matters a lot for large dumps.

**[Linux]** Just point `DUMP_DIR` at the local folder holding the dumps:
```bash
# in .env
DUMP_DIR=/data/oracle_dumps
```

**[WSL]** Do **not** read them from `/mnt/c/...` — Docker Desktop's Windows file mount is slow and
**hangs on large (10 GB+) dumps**. Copy the dumps onto the WSL filesystem first, then point there:
```bash
mkdir -p ~/dumps
cp -v /mnt/c/path/to/your/dumpfolder/*.dmp ~/dumps/     # one-time; watch it progress
ls -la ~/dumps/
echo "$HOME"                                            # e.g. /home/USER
```
```bash
# in .env  (use the absolute path echo showed)
DUMP_DIR=/home/USER/dumps
```
> **[WSL]** From here on, run `docker compose` **from the WSL shell** so this Linux path resolves.

---

## 3. Start the stack

```bash
docker compose up -d
docker compose ps          # wait until `oracle` shows (healthy) — first boot takes a few minutes
```
> The services use **host networking**: Oracle binds the host's `1521` and Postgres the host's
> `5432` directly (no remapping). If another local Postgres/Oracle already uses those ports, stop
> it first or the containers will fail to bind.

Confirm Oracle can see the dumps:
```bash
docker compose exec -T oracle ls -l /dumps      # should list your .dmp files
```

---

## 4. Load one dumpset (the core command)

```bash
bash load_dump.sh '<dumpfile_pattern>' <SCHEMA> ['T1,T2,...']
```
- `<dumpfile_pattern>` — the filenames of one export **job**. Multi-file jobs use Data Pump's `%U`
  wildcard. **Quote it** so the shell doesn't touch the `%U`.
- `<SCHEMA>` — the Oracle schema inside the dump (becomes the lowercased Postgres schema).
- `['T1,T2']` — *optional* comma list to import only those tables (needed for big schemas — step 6).

**Example — a small, self-contained job:**
```bash
bash load_dump.sh 'mfom_exp_part_%U.dmp' MFOM
```
You'll see 5 phases:
```
==> [1/5] ensure Oracle directories + schema user (MFOM) + stub principals
==> [2/5] impdp ...           # loads into Oracle (+ prints the impdp log tail)
==> [3/5] convert MFOM -> Postgres
==> [4/5] verify row counts   # ora= vs pg= per table
==> [5/5] free Oracle space
==> done.
```
A clean run ends with **`All counts match.`**

> **Reading impdp errors — the one thing to get right.** In the log tail, distinguish:
> - `ORA-39083 Object type TABLE ... failed to create` → that table **did not load at all**, and
>   because it exists in neither DB, verify will *still* say "All counts match". Fix the cause
>   (usually a missing stub principal — see the troubleshooting table) and re-run with that table
>   in the 3rd argument.
> - `... imported "X" N out of M rows` → charset conversion skipped a few rows (`ORA-02374`);
>   noted loss, not fatal.
> - Anything about FGA/audit policies → harmless (and now excluded at import).

Run each job the same way (one job's files present at a time):
```bash
bash load_dump.sh 'mfom_exp_%U.dmp'   MFOM
bash load_dump.sh 'mfom_exp_2_%U.dmp' MFOM
```

---

## 5. Verify / explore the result

```bash
# interactive psql on the target DB
docker compose exec -it postgres psql -U nmd -d nmd
```
```sql
\dn                        -- schemas (one per source: mfom, nmdr, ...)
\dt mfom.*                 -- tables in a source schema
SELECT count(*) FROM mfom.bt_user_information;
\x                         -- expanded display (nice for wide tables)
\q
```
Or from the host: **localhost / port 5432 / db `nmd` / user `nmd` / pass `nmd`** (DBeaver etc.) —
or just open the bundled **pgAdmin** at **http://localhost:5050** (the `nmd (local)` server is
preregistered; enter the DB password on first click).

Re-check counts anytime:
```bash
docker compose exec -T etl python migrate.py verify --schema MFOM
```

---

## 6. Big schemas that exceed the 12 GB cap (table batching)

A schema too large to hold in Oracle at once (e.g. NMDR — a 19.8 GB dumpset holding ~68 GB of
uncompressed data) is imported **a few tables per run**. The whole dumpset must be on disk, but each
run only imports/holds the tables you name, then frees Oracle before the next batch. Postgres
accumulates everything.

**Get real per-table sizes from the dump** (don't trust `migrate.py list` — stats are excluded at
import, so its row estimates are always `?`). A metadata-only import that keeps its master table
records each table's `SIZE_ESTIMATE`:
```bash
docker compose exec -T oracle impdp system/oracle@FREEPDB1 directory=NMD_DUMPS \
  dumpfile='NMDR_EXP_%U.dmp' logfile='NMD_LOG:meta.log' content=metadata_only keep_master=yes \
  exclude=statistics,index,constraint,ref_constraint,grant,trigger,rls_policy,fga_policy

docker compose exec -T oracle sqlplus -s system/oracle@FREEPDB1 <<'SQL'
SET HEADING OFF PAGESIZE 0 LINESIZE 200
SELECT object_name||'|'||NVL(size_estimate,0) FROM SYSTEM.SYS_IMPORT_FULL_01
 WHERE object_schema='NMDR' AND object_type_path LIKE '%TABLE_DATA%' ORDER BY 2 DESC;
SQL
```
(Sizes are uncompressed-byte estimates — treat as rough; LOB-heavy tables can be several× off.
Afterwards drop the created empty tables + the `SYS_IMPORT_%` master before the real batches.)

**Batch and run.** Group tables into batches of **≤ ~8.5 GB and ≤ ~60 tables** (bigger lists overrun
impdp's `tables=` argument), largest-first, each multi-GB table in its own batch:
```bash
bash load_dump.sh 'NMDR_EXP_%U.dmp' NMDR 'CFR,HIST_CFR,CFR_COMMENT'
bash load_dump.sh 'NMDR_EXP_%U.dmp' NMDR 'LOG_TASK,QA_TIP_ENTRY,WSV_PARAGRAPH'
# ... continue until all tables are done; migrate.py is resumable and skips finished ones
```
If you script the batches in a loop, **redirect the inner command's stdin** — `docker compose exec`
otherwise swallows the loop's input and the loop silently stops after one batch:
```bash
while IFS= read -r tables <&3; do
  bash load_dump.sh 'NMDR_EXP_%U.dmp' NMDR "$tables" </dev/null
done 3< batches.txt
```
**When all batches are done, reconcile** (verify alone can't see tables that failed to create):
```bash
docker compose exec -T postgres psql -U nmd -d nmd -c \
  "SELECT status, count(*) FROM _mig.migration_state WHERE src_schema='NMDR' GROUP BY status"
# done-count should equal the number of tables you batched
```

---

## 7. Rebuild PK/FK constraints (optional)

Data loads without keys (excluded at impdp for speed), but the dumps contain the source's
constraint DDL. To restore it, extract per dumpset and run the builder:

```bash
docker compose exec -T oracle impdp system/oracle@FREEPDB1 directory=NMD_DUMPS \
  dumpfile='MYDUMP_%U.dmp' logfile='NMD_LOG:cons_my.log' sqlfile='NMD_LOG:cons_my.sql' \
  include=constraint,ref_constraint
docker cp nmd-oracle:/tmp/cons_my.sql /tmp/ && docker cp /tmp/cons_my.sql nmd-etl:/state/

docker compose exec -T etl python build_constraints.py '/state/cons_*.sql'
```
Keys (PK/UNIQUE) apply first, then FKs as `NOT VALID`, then each FK is validated. FKs whose
data has orphans **stay `NOT VALID`** (still enforced for new writes) and are listed in the
report — as are constraints skipped because their tables were never loaded. Partitioned
tables' PKs can be inlined in `CREATE TABLE` (missed by `include=constraint`); if an FK fails
with "no unique constraint matching given keys", pull the PK from a full-DDL sqlfile
(no `include=`) and add it by hand. The DDL applied to this DB: `sql/constraints_from_dumps.sql`.

---

## 8. Load Excel files (optional)

`.xlsx` sources skip Oracle entirely — drop them in `xlsx/` (mounted read-only at `/xlsx`):

```bash
docker compose exec -T etl python survey_xlsx.py     # sheet structure: tabular vs document-style
# add tabular sheets to MANIFEST in etl/load_xlsx.py, then:
docker compose exec -T etl python load_xlsx.py       # -> schema "xlsx", one table per sheet
```
Resumable like the dump pipeline (`_mig.migration_state`, `src_schema='XLSX'`); `--force` /
`--only table1,table2` to redo. Leave document-style sheets (use-case forms, prose) out of
the manifest.

---

## 9. Normalize into a canonical schema (optional)

Once raw data is in Postgres, map a table into the shared `canonical` schema. Example:
```bash
docker compose exec -T postgres psql -U nmd -d nmd < sql/normalize_example.sql
docker compose exec -T postgres psql -U nmd -d nmd -c "SELECT count(*) FROM canonical.users;"
```
See **[NORMALIZATION.md](NORMALIZATION.md)** for the rules and how to write one for another table.

---

## 10. Stop / reset

```bash
docker compose down            # stop; keep data (volumes persist)
docker compose down -v         # stop and WIPE Oracle + Postgres volumes (fresh start)
```

---

## Troubleshooting quick reference

| Symptom | Cause | Fix |
|---|---|---|
| `ORA-31640 / ORA-27037 ... /dumps/x.dmp No such file` | dumpset incomplete or wrong pattern | ensure **all** of that job's files are present; `docker compose exec -T oracle ls /dumps` |
| impdp `completed with N errors`, only FGA lines | harmless audit policies | ignore; check verify counts |
| `ORA-39083 TABLE ... ORA-00904 "SECMGR"...` / `"VSB"...` | table DDL calls a masking package that doesn't exist locally → **table silently not created** | stub packages should exist (phase 1 applies `oracle-init/02_secmgr_stub.sql`); re-apply it and re-run that table's batch |
| `ORA-39083 TABLE ... ORA-01917 user or role 'X' does not exist` | table carries `GRANT REFERENCES TO X` → **table silently not created** | add `X` to the stub-user list in `02_secmgr_stub.sql`, re-apply, re-run the batch |
| convert fails `ORA-28110: policy ... has error` | VPD/RLS policy imported before `rls_policy` was excluded | drop them: `DBMS_RLS.DROP_POLICY(owner, table, policy)` per row of `dba_policies` |
| `... imported "X" N **out of** M rows` + `ORA-02374`/`ORA-12899` | Windows-1252→UTF-8 widens some chars past `VARCHAR2(n BYTE)` | rows are skipped, not fatal — note the small loss if it matters |
| convert dies `year 0 is out of range` | corrupt legacy date in the source | fixed in `migrate.py` (temporal cols fetched as text, year ≤ 0 → NULL + `!` warning); update if you see it |
| convert dies `invalid byte sequence for encoding "UTF8": 0x00` | NUL bytes hiding in legacy free-text columns | fixed in `migrate.py` (`enc()` strips `\x00` — Postgres `text` can't hold NUL) |
| `ORA-00959 tablespace does not exist` (many) | missing `transform` flag | already handled by `load_dump.sh`; if running impdp by hand add `transform=segment_attributes:n` |
| `ORA-12954: exceeds 12 GB` | Oracle full (accumulated imports) | it self-clears per run now; to free manually see below |
| `ORA-12954` yet `dba_segments` shows almost nothing | `users01.dbf` **allocation** grew during earlier batches; drops don't shrink the file | `ALTER DATABASE DATAFILE '/opt/oracle/oradata/FREE/FREEPDB1/users01.dbf' RESIZE 1G;` (phase 5 now does this automatically) |
| batch loop stops after the first batch | `docker compose exec` consumed the loop's stdin | run the inner command `</dev/null` / read the loop on FD 3 (step 6) |
| verify says match but tables are missing | verify only sees tables that exist in Oracle | reconcile `_mig.migration_state` done-count vs your table list (step 6) |
| impdp **hangs**, `docker stats` Block I/O frozen, CPU idle | reading a large dump over the slow **/mnt/c** mount **[WSL]** | copy dumps to the WSL filesystem (step 2); never read big dumps from `/mnt/c` |
| `KILL_JOB` freezes / job won't die | worker stuck in I/O wait | `docker compose restart oracle` (or `kill` then `up -d`) |
| `nmdr` schema not appearing | still in impdp phase | it's created in phase **[3/5] convert**; wait for that line |

**Free Oracle manually** (if ever needed — this mirrors what phase 5 does):
```bash
docker compose exec -T oracle sqlplus -s system/oracle@FREEPDB1 <<'SQL'
WHENEVER SQLERROR CONTINUE
BEGIN
  FOR r IN (SELECT owner, table_name FROM dba_tables
             WHERE owner IN ('MFOM','NMDR')          -- your staging schemas
                OR (owner='SYSTEM' AND table_name LIKE 'SYS_IMPORT_%')) LOOP
    BEGIN EXECUTE IMMEDIATE 'DROP TABLE "'||r.owner||'"."'||r.table_name||'" CASCADE CONSTRAINTS PURGE';
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
  FOR r IN (SELECT owner, object_name FROM dba_recyclebin) LOOP
    BEGIN EXECUTE IMMEDIATE 'PURGE TABLE "'||r.owner||'"."'||r.object_name||'"';
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END;
/
ALTER DATABASE DATAFILE '/opt/oracle/oradata/FREE/FREEPDB1/users01.dbf' RESIZE 1G;
SELECT ROUND(SUM(bytes)/1024/1024/1024,2) used_gb FROM dba_segments;
SQL
```
