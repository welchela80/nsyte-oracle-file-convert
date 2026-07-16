#!/usr/bin/env python3
"""
Convert Oracle RAW(16) GUID columns (loaded as bytea) to native uuid.

Input: /state/uuid_candidates.tsv (from check_uuid_candidates.py — columns verified
to hold only 16-byte values or NULL). Postgres can't keep an FK across a uuid/bytea
mismatch, so the order is:

  1. snapshot every FK that touches a candidate column (definition + validated flag)
  2. drop those FKs
  3. per table: one ALTER TABLE rewriting all its candidate columns to uuid
     (USING encode(col,'hex')::uuid)
  4. re-add the FKs from the snapshot (pg_get_constraintdef preserves NOT VALID)

The FK snapshot is written to /state/uuid_fk_snapshot.sql first, so if anything dies
mid-run the constraints can be restored by hand. Failures are reported, not fatal.
"""
import os, sys
from collections import defaultdict
import psycopg2

pg = psycopg2.connect(host=os.environ["PG_HOST"], port=os.environ.get("PG_PORT", "5432"),
                      dbname=os.environ["PG_DB"], user=os.environ["PG_USER"],
                      password=os.environ["PG_PASSWORD"])
pg.autocommit = True
cur = pg.cursor()

cand = set()
by_table = defaultdict(list)
for line in open("/state/uuid_candidates.tsv"):
    sch, tbl, col = line.rstrip("\n").split("\t")
    cand.add((sch, tbl, col))
    by_table[(sch, tbl)].append(col)
print(f"{len(cand)} columns in {len(by_table)} tables to convert")

# ---- 1. snapshot FKs touching any candidate column ----
cur.execute("""
SELECT c.oid, n.nspname::text, t.relname::text, c.conname::text,
       pg_get_constraintdef(c.oid), c.convalidated
FROM pg_constraint c
JOIN pg_class t  ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE c.contype = 'f' AND n.nspname IN ('mfom','nmdr','vsb')""")
fks = []
for oid, sch, tbl, con, condef, validated in cur.fetchall():
    cur.execute("""
      SELECT DISTINCT nl.nspname::text, tl.relname::text, al.attname::text
      FROM pg_constraint c
      LEFT JOIN LATERAL unnest(c.conkey)  k(attnum) ON true
      JOIN pg_class tl ON tl.oid=c.conrelid JOIN pg_namespace nl ON nl.oid=tl.relnamespace
      JOIN pg_attribute al ON al.attrelid=c.conrelid AND al.attnum=k.attnum
      WHERE c.oid=%s
      UNION
      SELECT DISTINCT nr.nspname::text, tr.relname::text, ar.attname::text
      FROM pg_constraint c
      LEFT JOIN LATERAL unnest(c.confkey) k(attnum) ON true
      JOIN pg_class tr ON tr.oid=c.confrelid JOIN pg_namespace nr ON nr.oid=tr.relnamespace
      JOIN pg_attribute ar ON ar.attrelid=c.confrelid AND ar.attnum=k.attnum
      WHERE c.oid=%s""", (oid, oid))
    if any((s, t, a) in cand for s, t, a in cur.fetchall()):
        fks.append((sch, tbl, con, condef, validated))
print(f"{len(fks)} FKs touch candidate columns -> snapshot + drop")

with open("/state/uuid_fk_snapshot.sql", "w") as f:
    for sch, tbl, con, condef, _ in fks:
        f.write(f'ALTER TABLE "{sch}"."{tbl}" ADD CONSTRAINT "{con}" {condef.replace("FOREIGN KEY", "FOREIGN KEY", 1)};\n')
print("snapshot written: /state/uuid_fk_snapshot.sql")

# ---- 2. drop ----
for sch, tbl, con, _, _ in fks:
    cur.execute(f'ALTER TABLE "{sch}"."{tbl}" DROP CONSTRAINT "{con}"')
print("FKs dropped")

# ---- 3. convert, one rewrite per table (largest last so progress shows early) ----
failed_tables = []
tables = sorted(by_table.items(), key=lambda kv: kv[0])
for i, ((sch, tbl), cols) in enumerate(tables, 1):
    actions = ", ".join(
        f'ALTER COLUMN "{c}" TYPE uuid USING encode("{c}", \'hex\')::uuid' for c in cols)
    try:
        cur.execute(f'ALTER TABLE "{sch}"."{tbl}" {actions}')
    except Exception as e:
        failed_tables.append((sch, tbl, str(e).split(chr(10))[0]))
    if i % 40 == 0:
        print(f"  converted {i}/{len(tables)} tables"); sys.stdout.flush()
print(f"converted {len(tables)-len(failed_tables)}/{len(tables)} tables")

# ---- 4. re-add FKs ----
fk_fail = []
for sch, tbl, con, condef, validated in fks:
    try:
        cur.execute(f'ALTER TABLE "{sch}"."{tbl}" ADD CONSTRAINT "{con}" {condef}')
    except Exception as e:
        fk_fail.append((con, str(e).split(chr(10))[0]))
print(f"re-added {len(fks)-len(fk_fail)}/{len(fks)} FKs")

if failed_tables:
    print("\n-- TABLE FAILURES --")
    for sch, tbl, e in failed_tables: print(f"  {sch}.{tbl}: {e}")
if fk_fail:
    print("\n-- FK RE-ADD FAILURES --")
    for con, e in fk_fail[:40]: print(f"  {con}: {e}")
print("\ndone.")
