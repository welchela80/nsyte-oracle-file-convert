#!/usr/bin/env python3
"""Verify which bytea columns hold exclusively 16-byte values (Oracle RAW(16) GUIDs)
and are therefore safe to convert to uuid. One scan per table covers all its bytea
columns. Writes the verdict to /state/uuid_candidates.tsv."""
import os, psycopg2

pg = psycopg2.connect(host=os.environ["PG_HOST"], port=os.environ.get("PG_PORT", "5432"),
                      dbname=os.environ["PG_DB"], user=os.environ["PG_USER"],
                      password=os.environ["PG_PASSWORD"])
cur = pg.cursor()
cur.execute("""SELECT table_schema::text, table_name::text, array_agg(column_name::text ORDER BY ordinal_position)
               FROM information_schema.columns
               WHERE table_schema IN ('mfom','nmdr','vsb') AND data_type='bytea'
               GROUP BY 1,2 ORDER BY 1,2""")
tables = cur.fetchall()

ok, empty, bad = [], [], []
for i, (sch, tbl, cols) in enumerate(tables, 1):
    exprs = ", ".join(f'min(octet_length("{c}")), max(octet_length("{c}"))' for c in cols)
    cur.execute(f'SELECT {exprs} FROM "{sch}"."{tbl}"')
    row = cur.fetchone()
    for j, c in enumerate(cols):
        lo, hi = row[2*j], row[2*j+1]
        if lo is None:            empty.append((sch, tbl, c))          # all NULL (or 0 rows)
        elif lo == 16 and hi == 16: ok.append((sch, tbl, c))
        else:                     bad.append((sch, tbl, c, lo, hi))
    if i % 50 == 0: print(f"  scanned {i}/{len(tables)} tables")

print(f"\n16-byte only (uuid-safe): {len(ok)}")
print(f"all-NULL (convert-safe):  {len(empty)}")
print(f"NOT uuid (other lengths): {len(bad)}")
for b in bad: print(f"  {b[0]}.{b[1]}.{b[2]}: len {b[3]}..{b[4]}")

with open("/state/uuid_candidates.tsv", "w") as f:
    for sch, tbl, c in ok + empty:
        f.write(f"{sch}\t{tbl}\t{c}\n")
print("written: /state/uuid_candidates.tsv")
