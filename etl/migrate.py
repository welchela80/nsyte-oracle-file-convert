#!/usr/bin/env python3
"""
Oracle -> PostgreSQL table migrator (faithful 1:1, per-source schema).

Reads tables out of the Oracle staging DB (python-oracledb THIN mode — no Oracle
client needed) and bulk-loads them into Postgres via COPY. Resumable: progress is
tracked in Postgres (_mig.migration_state), so re-running skips completed tables.

Commands:
  list    --schema MFOM                 list Oracle tables + row estimates
  migrate --schema MFOM [--tables a,b]  create + COPY each table into pg schema "mfom"
          [--exclude x,y] [--force] [--limit N]
  verify  --schema MFOM                 compare Oracle vs Postgres row counts

Env: ORA_DSN, ORA_USER, ORA_PASSWORD, PG_HOST, PG_PORT, PG_DB, PG_USER, PG_PASSWORD.
"""
import os, sys, io, argparse, datetime
import oracledb, psycopg2

oracledb.defaults.fetch_lobs = False          # CLOB->str, BLOB->bytes directly
BATCH = int(os.environ.get("BATCH", "50000"))

def ora_conn():
    return oracledb.connect(user=os.environ["ORA_USER"], password=os.environ["ORA_PASSWORD"],
                            dsn=os.environ["ORA_DSN"])

# Corrupt legacy rows can hold dates Python's datetime can't represent (e.g. year 0 ->
# "year 0 is out of range" mid-fetch, killing the whole table). oracledb thin mode decodes
# DATE client-side into datetime (server NLS/output type handlers can't avoid it), so we
# convert temporal columns to text server-side with TO_CHAR and sanitize the strings.
def _sel_expr(col):
    t, name = col["ora_type"], f'"{col["name"]}"'
    if t == "DATE":
        return f"TO_CHAR({name},'SYYYY-MM-DD HH24:MI:SS')"
    if t.startswith("TIMESTAMP"):
        fmt = "SYYYY-MM-DD HH24:MI:SS.FF6" + (" TZH:TZM" if "TIME ZONE" in t else "")
        return f"TO_CHAR({name},'{fmt}')"
    return name

def _sane_date(s):
    # NULL out dates Postgres can't store: year 0 or BC ('S' format emits '-' for BC).
    v = s.lstrip()
    return None if v.startswith("-") or v[:4] == "0000" else s

def pg_conn():
    return psycopg2.connect(host=os.environ["PG_HOST"], port=os.environ.get("PG_PORT", "5432"),
                            dbname=os.environ["PG_DB"], user=os.environ["PG_USER"],
                            password=os.environ["PG_PASSWORD"])

# ── type mapping ──────────────────────────────────────────────────────────────
def ora_to_pg(dtype, length, prec, scale):
    t = dtype.upper()
    if t == "NUMBER":
        if scale in (None, 0):
            if prec is None:      return "numeric"
            if prec <= 9:         return "integer"
            if prec <= 18:        return "bigint"
            return f"numeric({prec})"
        return f"numeric({prec},{scale})" if prec else "numeric"
    if t in ("FLOAT", "BINARY_DOUBLE"):           return "double precision"
    if t == "BINARY_FLOAT":                        return "real"
    if t in ("VARCHAR2", "NVARCHAR2", "VARCHAR", "CHAR", "NCHAR", "CLOB", "NCLOB", "LONG",
             "ROWID", "UROWID"):                   return "text"
    if t.startswith("TIMESTAMP"):
        return "timestamptz" if "TIME ZONE" in t else "timestamp"
    if t == "DATE":                                return "timestamp"
    if t == "RAW" and length == 16:                return "uuid"    # SYS_GUID() keys
    if t in ("BLOB", "RAW", "LONG RAW", "BFILE"):  return "bytea"
    return "text"                                  # safe fallback

def get_columns(ocur, schema, table):
    ocur.execute("""
        SELECT column_name, data_type, data_length, data_precision, data_scale, nullable
          FROM all_tab_columns WHERE owner=:o AND table_name=:t ORDER BY column_id""",
        o=schema, t=table)
    cols = []
    for name, dtype, length, prec, scale, nullable in ocur.fetchall():
        cols.append(dict(name=name, pg_type=ora_to_pg(dtype, length, prec, scale),
                         ora_type=dtype.upper(), nullable=(nullable == "Y")))
    return cols

def list_tables(ocur, schema):
    ocur.execute("""SELECT table_name, NVL(num_rows,-1) FROM all_tables
                     WHERE owner=:o ORDER BY table_name""", o=schema)
    return ocur.fetchall()

# ── COPY-text encoding ────────────────────────────────────────────────────────
def enc(v):
    if v is None:                     return "\\N"
    if isinstance(v, bytes):          s = "\\x" + v.hex()
    elif isinstance(v, bool):         s = "t" if v else "f"
    elif isinstance(v, datetime.datetime): s = v.isoformat(sep=" ")
    elif isinstance(v, datetime.date):     s = v.isoformat()
    else:                             s = str(v)
    if "\x00" in s:                   s = s.replace("\x00", "")   # PG text can't hold NUL
    return s.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")

# ── state table ───────────────────────────────────────────────────────────────
def init_state(pg):
    with pg.cursor() as c:
        c.execute("CREATE SCHEMA IF NOT EXISTS _mig")
        c.execute("""CREATE TABLE IF NOT EXISTS _mig.migration_state(
            src_schema text, src_table text, status text, ora_rows bigint, pg_rows bigint,
            error text, updated_at timestamptz DEFAULT now(),
            PRIMARY KEY (src_schema, src_table))""")
    pg.commit()

def set_state(pg, schema, table, status, ora_rows=None, pg_rows=None, error=None):
    with pg.cursor() as c:
        c.execute("""INSERT INTO _mig.migration_state(src_schema,src_table,status,ora_rows,pg_rows,error,updated_at)
            VALUES(%s,%s,%s,%s,%s,%s,now())
            ON CONFLICT(src_schema,src_table) DO UPDATE SET
              status=EXCLUDED.status, ora_rows=EXCLUDED.ora_rows, pg_rows=EXCLUDED.pg_rows,
              error=EXCLUDED.error, updated_at=now()""",
            (schema, table, status, ora_rows, pg_rows, error))
    pg.commit()

def done_tables(pg, schema):
    with pg.cursor() as c:
        c.execute("SELECT src_table FROM _mig.migration_state WHERE src_schema=%s AND status='done'", (schema,))
        return {r[0] for r in c.fetchall()}

# ── per-table migration ───────────────────────────────────────────────────────
def migrate_table(ora, pg, schema, table):
    pgschema = schema.lower()
    pgtable = table.lower()
    ocur = ora.cursor()
    cols = get_columns(ocur, schema, table)
    if not cols:
        print(f"  ! {table}: no columns (skipped)"); return
    set_state(pg, schema, table, "running")
    with pg.cursor() as c:
        c.execute(f'CREATE SCHEMA IF NOT EXISTS "{pgschema}"')
        c.execute(f'DROP TABLE IF EXISTS "{pgschema}"."{pgtable}"')
        coldefs = ", ".join(f'"{x["name"].lower()}" {x["pg_type"]}' for x in cols)
        c.execute(f'CREATE TABLE "{pgschema}"."{pgtable}" ({coldefs})')
    pg.commit()

    collist = ", ".join(f'"{x["name"].lower()}"' for x in cols)
    copy_sql = f'COPY "{pgschema}"."{pgtable}" ({collist}) FROM STDIN WITH (FORMAT text)'
    ocur.arraysize = BATCH
    select_list = ", ".join(_sel_expr(x) for x in cols)
    ocur.execute(f'SELECT {select_list} FROM "{schema}"."{table}"')
    date_idx = [i for i, x in enumerate(cols)
                if x["ora_type"] == "DATE" or x["ora_type"].startswith("TIMESTAMP")]
    uuid_idx = [i for i, x in enumerate(cols) if x["pg_type"] == "uuid"]
    total = 0
    bad_dates = 0
    pcur = pg.cursor()
    while True:
        rows = ocur.fetchmany(BATCH)
        if not rows: break
        buf = io.BytesIO()
        for row in rows:
            if date_idx or uuid_idx:
                row = list(row)
                for i in date_idx:
                    if row[i] is not None:
                        clean = _sane_date(row[i])
                        if clean is None: bad_dates += 1
                        row[i] = clean
                for i in uuid_idx:      # RAW(16) bytes -> hex text (valid uuid input)
                    if row[i] is not None:
                        row[i] = row[i].hex()
            buf.write(("\t".join(enc(v) for v in row) + "\n").encode("utf-8"))
        buf.seek(0)
        pcur.copy_expert(copy_sql, buf)
        total += len(rows)
        print(f"    {table}: {total:,} rows", end="\r")
    pg.commit()
    print(f"  ✓ {table}: {total:,} rows" + " " * 20)
    if bad_dates:
        print(f"    ! {table}: {bad_dates} unrepresentable date value(s) (year<=0) set to NULL")
    set_state(pg, schema, table, "done", pg_rows=total)

def cmd_migrate(args):
    ora, pg = ora_conn(), pg_conn()
    init_state(pg)
    ocur = ora.cursor()
    all_tables = [t for t, _ in list_tables(ocur, args.schema)]
    if args.tables:
        want = {x.strip().upper() for x in args.tables.split(",")}
        all_tables = [t for t in all_tables if t in want]
    if args.exclude:
        ex = {x.strip().upper() for x in args.exclude.split(",")}
        all_tables = [t for t in all_tables if t not in ex]
    if not args.force:
        skip = done_tables(pg, args.schema)
        all_tables = [t for t in all_tables if t not in skip]
    if args.limit:
        all_tables = all_tables[: args.limit]
    print(f"Migrating {len(all_tables)} table(s) from {args.schema} -> pg schema {args.schema.lower()}")
    for t in all_tables:
        try:
            migrate_table(ora, pg, args.schema, t)
        except Exception as e:
            pg.rollback()
            print(f"  ✗ {t}: {e}")
            set_state(pg, args.schema, t, "error", error=str(e))

def cmd_list(args):
    ora = ora_conn()
    for name, nrows in list_tables(ora.cursor(), args.schema):
        print(f"{name:<40} {('?' if nrows < 0 else f'{nrows:,}'):>15} rows (est)")

def cmd_verify(args):
    ora, pg = ora_conn(), pg_conn()
    ocur, pcur = ora.cursor(), pg.cursor()
    bad = 0
    for name, _ in list_tables(ocur, args.schema):
        try:
            ocur.execute(f'SELECT COUNT(*) FROM "{args.schema}"."{name}"'); o = ocur.fetchone()[0]
        except Exception: continue
        try:
            pcur.execute(f'SELECT COUNT(*) FROM "{args.schema.lower()}"."{name.lower()}"'); p = pcur.fetchone()[0]
        except Exception: p = None
        flag = "" if p == o else "  <-- MISMATCH"
        if p != o: bad += 1
        print(f"{name:<40} ora={o:>12,}  pg={('—' if p is None else f'{p:,}'):>12}{flag}")
    print(f"\n{bad} mismatch(es)." if bad else "\nAll counts match.")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("list", "migrate", "verify"):
        p = sub.add_parser(name); p.add_argument("--schema", required=True)
        if name == "migrate":
            p.add_argument("--tables"); p.add_argument("--exclude")
            p.add_argument("--force", action="store_true"); p.add_argument("--limit", type=int)
    args = ap.parse_args()
    {"list": cmd_list, "migrate": cmd_migrate, "verify": cmd_verify}[args.cmd](args)
