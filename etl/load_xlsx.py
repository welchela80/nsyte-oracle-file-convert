#!/usr/bin/env python3
"""
Excel -> PostgreSQL loader (faithful 1:1, like migrate.py but for /xlsx files).

Loads the tabular sheets listed in MANIFEST into the Postgres schema "xlsx",
one table per sheet, every column text (raw fidelity — type interpretation is
normalization's job, see docs/NORMALIZATION.md). Values get the same hygiene
as the Oracle path: NUL bytes stripped, datetimes ISO-formatted, COPY escaping.

Progress is tracked in _mig.migration_state under src_schema='XLSX', so re-runs
skip sheets already done. Document-style workbooks (use-case forms/narratives)
are deliberately NOT listed — they aren't tables.

Usage:
  python load_xlsx.py            # load everything not yet done
  python load_xlsx.py --force    # reload all manifest entries
  python load_xlsx.py --only icrl_by_niin[,t2]   # just those tables (implies force)

Env: PG_HOST, PG_PORT, PG_DB, PG_USER, PG_PASSWORD (same as migrate.py).
"""
import os, io, re, sys, argparse, datetime
import openpyxl, psycopg2

XLSX_DIR = "/xlsx"
SCHEMA = "xlsx"

# (file, sheet, table, header_row) — header_row is 1-based; data starts the row after.
MANIFEST = [
    ("21687 TWOKILOS-VSB.xlsx",                                    "Sheet1",             "twokilos_21687", 1),
    ("CUI_DDG-57_Aloft_Equipment_Data_2024.08.15.xlsx",            "Equipment Report",   "ddg57_aloft_equipment", 1),
    ("CUI_DDG-57_Tool_Issue_Equipment_Report_Dat_2024.08.15.xlsx", "Equipment Report",   "ddg57_tool_issue_equipment", 1),
    ("DIU Vendor GFI.xlsx",                                        "Aviation",           "diu_vendor_gfi_aviation", 1),
    ("DIU Vendor GFI.xlsx",                                        "Maritime",           "diu_vendor_gfi_maritime", 1),
    ("ICRL IMA - FY26 Q1 ICRL By Niin and ICRL w_Alts by P_N-Fscm.xlsx", "ICRL_by_Niin",  "icrl_by_niin", 1),
    ("ICRL IMA - FY26 Q1 ICRL By Niin and ICRL w_Alts by P_N-Fscm.xlsx", "ICRL_w_Alts_by_P_N_Fscm", "icrl_w_alts_by_pn_fscm", 1),
    ("ICRL IMA Capability Code Descriptions.xlsx",                 "Capability Codes",   "icrl_capability_codes", 1),
    ("Metrology and Calibration - NMMES-TR BPR R-WIPT Finalized Functional Requirements 20180208.xlsx",
                                                                   "Metrology and Calibration", "metcal_functional_requirements", 1),
    ("N-MRO Requirement Replan_Master_01_20_26 1.xlsx",            "NMRO-M",             "nmro_requirements_replan", 1),
    ("N-MRO Requirement Replan_Master_01_20_26 1.xlsx",            "Analysis Results",   "nmro_replan_analysis_results", 1),
    ("SWLINS.xlsx",                                                "Sheet1",             "swlins", 1),
]

def pg_conn():
    return psycopg2.connect(host=os.environ["PG_HOST"], port=os.environ.get("PG_PORT", "5432"),
                            dbname=os.environ["PG_DB"], user=os.environ["PG_USER"],
                            password=os.environ["PG_PASSWORD"])

def colname(raw, i, seen):
    s = "" if raw is None else str(raw)
    s = re.sub(r"[^0-9a-z]+", "_", s.strip().lower()).strip("_")
    if not s: s = f"col_{i+1}"
    if s[0].isdigit(): s = "c_" + s
    base, n = s, 2
    while s in seen:
        s = f"{base}_{n}"; n += 1
    seen.add(s)
    return s

def enc(v):
    if v is None: return "\\N"
    if isinstance(v, bool): s = "t" if v else "f"
    elif isinstance(v, datetime.datetime):
        s = v.date().isoformat() if (v.hour, v.minute, v.second) == (0, 0, 0) else v.isoformat(sep=" ")
    elif isinstance(v, datetime.date): s = v.isoformat()
    elif isinstance(v, float) and v.is_integer(): s = str(int(v))   # avoid '5164.0' artifacts
    else: s = str(v)
    if "\x00" in s: s = s.replace("\x00", "")                        # PG text can't hold NUL
    return s.replace("\\", "\\\\").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")

def set_state(pg, table, status, rows=None, error=None):
    with pg.cursor() as c:
        c.execute("""INSERT INTO _mig.migration_state(src_schema,src_table,status,pg_rows,error,updated_at)
            VALUES('XLSX',%s,%s,%s,%s,now())
            ON CONFLICT(src_schema,src_table) DO UPDATE SET
              status=EXCLUDED.status, pg_rows=EXCLUDED.pg_rows, error=EXCLUDED.error, updated_at=now()""",
            (table, status, rows, error))
    pg.commit()

def load_sheet(pg, fname, sheet, table, header_row):
    path = os.path.join(XLSX_DIR, fname)
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    ws = wb[sheet]
    rows_iter = ws.iter_rows(min_row=header_row, values_only=True)
    header = next(rows_iter)
    while header is not None and all(v is None for v in header):    # tolerate leading blank rows
        header = next(rows_iter)
    seen = set()
    names = [colname(v, i, seen) for i, v in enumerate(header)]
    # drop wholly unnamed trailing columns (formatting spillover)
    while names and names[-1].startswith("col_") and header[len(names)-1] is None:
        names.pop()
    ncols = len(names)

    with pg.cursor() as c:
        c.execute(f'CREATE SCHEMA IF NOT EXISTS "{SCHEMA}"')
        c.execute(f'DROP TABLE IF EXISTS "{SCHEMA}"."{table}"')
        c.execute(f'CREATE TABLE "{SCHEMA}"."{table}" (' + ", ".join(f'"{n}" text' for n in names) + ")")
        c.execute(f"""COMMENT ON TABLE "{SCHEMA}"."{table}" IS %s""",
                  (f"source: {fname} / sheet '{sheet}' (raw 1:1 xlsx load)",))
    pg.commit()

    buf, total = io.StringIO(), 0
    pcur = pg.cursor()
    copy_sql = f'COPY "{SCHEMA}"."{table}" FROM STDIN WITH (FORMAT text)'
    for row in rows_iter:
        vals = list(row[:ncols]) + [None] * max(0, ncols - len(row))
        if all(v is None or (isinstance(v, str) and not v.strip()) for v in vals):
            continue                                                # skip fully-empty rows
        buf.write("\t".join(enc(v) for v in vals) + "\n")
        total += 1
        if total % 50000 == 0:
            buf.seek(0); pcur.copy_expert(copy_sql, buf); buf = io.StringIO()
            print(f"    {table}: {total:,} rows", end="\r")
    buf.seek(0); pcur.copy_expert(copy_sql, buf)
    pg.commit()
    wb.close()
    print(f"  ✓ {table}: {total:,} rows ({ncols} cols)" + " " * 15)
    return total

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--only")
    args = ap.parse_args()
    pg = pg_conn()
    with pg.cursor() as c:   # state table may not exist on a fresh DB
        c.execute("CREATE SCHEMA IF NOT EXISTS _mig")
        c.execute("""CREATE TABLE IF NOT EXISTS _mig.migration_state(
            src_schema text, src_table text, status text, ora_rows bigint, pg_rows bigint,
            error text, updated_at timestamptz DEFAULT now(), PRIMARY KEY (src_schema, src_table))""")
    pg.commit()

    todo = MANIFEST
    if args.only:
        want = {t.strip() for t in args.only.split(",")}
        todo = [m for m in MANIFEST if m[2] in want]
        args.force = True
    if not args.force:
        with pg.cursor() as c:
            c.execute("SELECT src_table FROM _mig.migration_state WHERE src_schema='XLSX' AND status='done'")
            done = {r[0] for r in c.fetchall()}
        todo = [m for m in todo if m[2] not in done]

    print(f"Loading {len(todo)} sheet(s) -> pg schema {SCHEMA}")
    for fname, sheet, table, hdr in todo:
        try:
            set_state(pg, table, "running")
            n = load_sheet(pg, fname, sheet, table, hdr)
            set_state(pg, table, "done", rows=n)
        except Exception as e:
            pg.rollback()
            print(f"  ✗ {table}: {e}")
            set_state(pg, table, "error", error=str(e))

if __name__ == "__main__":
    main()
