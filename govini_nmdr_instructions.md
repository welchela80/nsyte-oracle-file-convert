# Guide: Convert Oracle Data Pump `.dmp` files to CSV on macOS (Docker + Oracle Free + Python)

This guide documents the complete start-to-finish process used to convert a folder of Oracle Data Pump dump files (`.dmp`) into CSV files on a Mac.

---

## What you’re doing (in plain English)

Oracle `.dmp` files created by **Data Pump** (`expdp`) are not human-readable. You can’t “open” them or convert them directly to CSV. Oracle must interpret them.

So the process is:

1. Run a temporary Oracle database locally (we used **Oracle Free** in Docker).
2. Import the dump data into a staging schema using `impdp`.
3. Export the imported tables to CSV using Python.
4. Because Oracle Free is limited to **12GB max database size**, import/export **one table at a time** (or tiny batches) and drop the table after exporting to keep the DB small.

---

## Prerequisites

- macOS
- Docker Desktop installed and running
- Python 3 installed (system Python or Anaconda is fine)
- Enough disk space for dump files + CSV output

---

## Step 1 — Install Docker Desktop and verify it’s running

1. Download Docker Desktop for Mac and install it.
2. Open Docker Desktop and wait for it to fully start.

Verify from Terminal:

```bash
docker version
docker ps
```

If Docker isn’t running, you’ll see errors about not being able to connect to the Docker socket.

---

## Step 2 — Put all `.dmp` files into one folder on your Mac

Example:

```bash
mkdir -p ~/dumps
# copy your *.dmp files into ~/dumps
ls -lah ~/dumps | head
```

Your dump set may have multiple pieces like:

- `NMDR_EXP_01.dmp`
- `NMDR_EXP_02.dmp`
- ...
- `NMDR_EXP_07.dmp`

---

## Step 3 — Start Oracle Free in Docker and mount the dump folder

Run:

```bash
docker run -d --name oracle-free \
  -p 1521:1521 -p 5500:5500 \
  -e ORACLE_PASSWORD='Passw0rd!' \
  -v "$HOME/dumps":/opt/oracle/dumps \
  gvenzl/oracle-free:23-slim
```

Wait for initialization:

```bash
docker logs -f oracle-free
```

Verify that Oracle can see your dumps inside the container:

```bash
docker exec -it oracle-free bash -lc 'ls -lah /opt/oracle/dumps | head'
```

---

## Step 4 — Confirm the database service name (PDB)

Run:

```bash
docker exec -it oracle-free lsnrctl status
```

In the “Services Summary” section, look for the PDB service name (commonly `freepdb1`).

You will connect using:

- `...@//localhost:1521/freepdb1`

---

## Step 5 — Create the Oracle DIRECTORY object (required for `impdp`)

Data Pump reads files only through a database DIRECTORY object. Create it like this:

```bash
docker exec -i oracle-free sqlplus 'system/Passw0rd!@//localhost:1521/freepdb1' <<'SQL'
CREATE OR REPLACE DIRECTORY DMPDIR AS '/opt/oracle/dumps';
exit
SQL
```

This makes `DIRECTORY=DMPDIR` point to `/opt/oracle/dumps` inside the container.

---

## Step 6 — Create a staging schema (`STAGE`) to import into

We import into `STAGE` (instead of the original schema) so export is straightforward and isolated.

```bash
docker exec -i oracle-free sqlplus 'system/Passw0rd!@//localhost:1521/freepdb1' <<'SQL'
BEGIN
  EXECUTE IMMEDIATE 'CREATE USER STAGE IDENTIFIED BY "StagePass1"';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1920 THEN RAISE; END IF; -- already exists
END;
/
GRANT CREATE SESSION, RESOURCE TO STAGE;
ALTER USER STAGE DEFAULT TABLESPACE USERS TEMPORARY TABLESPACE TEMP;
ALTER USER STAGE QUOTA UNLIMITED ON USERS;
exit
SQL
```

---

## Step 7 — Install the Python Oracle driver on your Mac

```bash
pip install -U oracledb
```

---

## Step 8 — Prepare a file containing the table names to export

Create a text file named `nmdr_tables.txt`:

- one table per line
- table name only (no schema prefix)

Example:

```text
TABLE_A
TABLE_B
TABLE_C
```

This is the list the script will iterate over.

---

## Step 9 — Run the import → CSV export → drop automation script

### Why we import one table at a time
Oracle Free has a hard 12GB database limit. Importing everything at once triggers:

- `ORA-12954: request exceeds the maximum allowed database size of 12 GB`

Importing one table at a time avoids that limit because we export it immediately and then drop it.

### Script: `batch_dmp_to_csv.py`

Save this as `batch_dmp_to_csv.py` on your Mac:

```python
#!/usr/bin/env python3
import argparse, csv, os, subprocess
from pathlib import Path
import oracledb

def dates_as_strings_outconverter(cursor, name, default_type, length, precision, scale):
    # Fetch DATE/TIMESTAMP as strings to avoid Python datetime errors (e.g., year 0 out of range)
    if default_type in (
        oracledb.DB_TYPE_DATE,
        oracledb.DB_TYPE_TIMESTAMP,
        oracledb.DB_TYPE_TIMESTAMP_TZ,
        oracledb.DB_TYPE_TIMESTAMP_LTZ,
    ):
        try:
            return cursor.var(oracledb.DB_TYPE_VARCHAR, size=64, arraysize=cursor.arraysize)
        except TypeError:
            return cursor.var(oracledb.DB_TYPE_VARCHAR, maxlength=64, arraysize=cursor.arraysize)
    return None

def set_export_nls_formats(conn):
    with conn.cursor() as cur:
        cur.execute("ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS'")
        cur.execute("ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF6'")
        cur.execute("ALTER SESSION SET NLS_TIMESTAMP_TZ_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF6 TZH:TZM'")

def docker_exec(container, bash_cmd):
    cmd = ["docker","exec","-i",container,"bash","-lc",bash_cmd]
    return subprocess.run(cmd, text=True, capture_output=True)

def log_has_text(container, log_path, needle):
    return docker_exec(container, f"grep -q '{needle}' '{log_path}'").returncode == 0

def impdp_one(container, connect, directory_obj, dumpfile_pattern, logfile,
              schema_from, schema_to, table_name, remap_tablespaces, excludes):
    tables_arg = f"TABLES={schema_from}.{table_name}"
    cmd = [
        "docker","exec","-i",container,
        "impdp", connect,
        f"DIRECTORY={directory_obj}",
        f"DUMPFILE={dumpfile_pattern}",
        f"LOGFILE={logfile}",
        f"REMAP_SCHEMA={schema_from}:{schema_to}",
        "TABLE_EXISTS_ACTION=REPLACE",
        tables_arg,
    ]
    for ex in excludes:
        cmd.append(f"EXCLUDE={ex}")
    for rt in remap_tablespaces:
        cmd.append(f"REMAP_TABLESPACE={rt}")

    print("CMD:", " ".join(cmd))
    p = subprocess.run(cmd)

    # 0 = success, 5 = completed with errors (acceptable for CSV workflow)
    if p.returncode not in (0,5):
        raise RuntimeError(f"impdp failed rc={p.returncode} log={logfile}")

def export_table_to_csv(conn, table, out_csv, arraysize=2000):
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_csv.with_suffix(out_csv.suffix + ".tmp")
    if tmp.exists():
        tmp.unlink()

    with conn.cursor() as cur:
        cur.arraysize = arraysize
        cur.execute(f'SELECT * FROM "{table}"')
        cols = [d[0] for d in cur.description]

        with open(tmp, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(cols)

            while True:
                rows = cur.fetchmany(arraysize)
                if not rows:
                    break

                out_rows = []
                for r in rows:
                    rr = []
                    for v in r:
                        if v is None:
                            rr.append(None)
                        elif isinstance(v,(bytes,bytearray)):
                            rr.append(v.hex())     # RAW/BLOB -> hex text
                        elif isinstance(v,(int,float,str)):
                            rr.append(v)
                        else:
                            rr.append(str(v))
                    out_rows.append(rr)
                w.writerows(out_rows)

    os.replace(tmp, out_csv)

def drop_table(conn, table):
    with conn.cursor() as cur:
        cur.execute(f'DROP TABLE "{table}" PURGE')
    conn.commit()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tables-file", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--start", type=int, default=1, help="Resume from this table number (1-based)")
    ap.add_argument("--container", default="oracle-free")
    ap.add_argument("--impdp-connect", default="system/Passw0rd!@//localhost:1521/freepdb1")
    ap.add_argument("--dumpfile", default="NMDR_EXP_%U.dmp")
    ap.add_argument("--directory", default="DMPDIR")
    ap.add_argument("--schema-from", default="NMDR")
    ap.add_argument("--schema-to", default="STAGE")
    ap.add_argument("--db-user", default="STAGE")
    ap.add_argument("--db-pass", required=True)
    ap.add_argument("--db-dsn", default="127.0.0.1:1521/freepdb1")
    args = ap.parse_args()

    tables = [l.strip() for l in Path(args.tables_file).read_text().splitlines()
              if l.strip() and not l.strip().startswith("#")]
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # Remap source tablespaces to USERS (add more if your dump references more tablespaces)
    remap_ts = [
        "NMDR_DATA:USERS",
        "NMDR_FLASH:USERS",
        "NMDR_WFDATA:USERS",
        "NMDR_LOG_DATA:USERS",
        "NMDR_INDEX:USERS",
    ]

    # Exclude objects not needed for CSV and which fail in partial imports
    excludes = ["PROFILE","OBJECT_GRANT","REF_CONSTRAINT","TRIGGER","INDEX"]

    conn = oracledb.connect(user=args.db_user, password=args.db_pass, dsn=args.db_dsn)
    conn.outputtypehandler = dates_as_strings_outconverter
    set_export_nls_formats(conn)

    try:
        total = len(tables)
        for i, t in enumerate(tables, start=1):
            if i < args.start:
                continue

            logfile = f"table_{i:04d}.log"
            print(f"\n=== Table {i}/{total}: {t} ===")

            # 1) import one table
            impdp_one(args.container, args.impdp_connect, args.directory, args.dumpfile, logfile,
                      args.schema_from, args.schema_to, t, remap_ts, excludes)

            # Stop if the Oracle Free 12GB cap is hit
            if log_has_text(args.container, f"/opt/oracle/dumps/{logfile}", "ORA-12954"):
                raise RuntimeError(f"Hit ORA-12954 at table {i}. Restart DB and resume with --start {i}")

            # 2) export table to CSV (on Mac)
            out_csv = out_dir / f"{t}.csv"
            export_table_to_csv(conn, t, out_csv)

            # 3) drop to free space
            drop_table(conn, t)

    finally:
        conn.close()

if __name__ == "__main__":
    main()
```

### Run the script

```bash
python batch_dmp_to_csv.py \
  --tables-file nmdr_tables.txt \
  --out-dir "$HOME/nmdr_csv" \
  --db-pass 'StagePass1'
```

### Resume if interrupted

If it stops at some table number (example 200), resume like:

```bash
python batch_dmp_to_csv.py \
  --tables-file nmdr_tables.txt \
  --out-dir "$HOME/nmdr_csv" \
  --db-pass 'StagePass1' \
  --start 200
```

---

## Step 10 — Confirm CSV output on your Mac

```bash
ls -lah "$HOME/nmdr_csv" | head
```

You’ll see one CSV per table.

---

## Step 11 — Cleanup (optional)

When finished:

```bash
docker rm -f oracle-free
```

Your `.dmp` files and exported CSVs remain on your Mac.

---

## Notes / common issues (brief)

- **`impdp` exit code 5** (“completed with errors”) is normal here and not fatal for CSV export.
- **Missing tablespace errors** are avoided by `REMAP_TABLESPACE=...:USERS` and excluding indexes.
- **Python `year 0` errors** are avoided by exporting Oracle dates/timestamps as strings using the output type handler.
- If Docker isn’t running, you’ll see docker socket / API connection errors—start Docker Desktop again.
