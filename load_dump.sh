#!/usr/bin/env bash
# load_dump.sh — load one Oracle Data Pump dumpset into Postgres, end to end.
#
# Run from WSL (the stack must be up: `docker compose up -d`).
#   bash load_dump.sh '<dumpfile_pattern>' <ORACLE_SCHEMA> ['T1,T2,...']
#
# Examples:
#   bash load_dump.sh 'mfom_exp_part_%U.dmp' MFOM             # whole dumpset -> schema "mfom"
#   bash load_dump.sh 'NMDR_EXP_%U.dmp'      NMDR 'CFR,LOG_TASK'   # just those tables
#
# Notes:
#   * %U is Data Pump's multi-file wildcard — QUOTE the pattern so the shell leaves it alone.
#   * Re-runnable. With no table list it converts every table in the schema not yet done;
#     with a table list it re-does exactly those.
#   * FGA/RLS security policies are excluded at import (they reference packages that don't
#     exist locally); oracle-init/02_secmgr_stub.sql (applied in phase 1) stubs the
#     packages/users that table DDL itself references.
#   * If you drive this in a loop, feed it </dev/null (or read the loop on FD 3):
#     `docker compose exec` swallows the loop's stdin and the loop stops after one pass.
set -uo pipefail

PATTERN="${1:?usage: bash load_dump.sh '<dumpfile_pattern>' <SCHEMA> ['T1,T2']}"
SCHEMA="$(printf '%s' "${2:?usage: bash load_dump.sh '<dumpfile_pattern>' <SCHEMA> ['T1,T2']}" | tr '[:lower:]' '[:upper:]')"
TABLES="${3:-}"
LOGFILE="imp_$(printf '%s' "$PATTERN" | tr -cd '[:alnum:]_').log"

cd "$(dirname "$0")"                       # the pipeline/ dir (holds docker-compose.yml)
dc() { docker compose "$@"; }

echo "==> [1/5] ensure Oracle directories + schema user ($SCHEMA) + stub principals"
dc exec -T oracle sqlplus -s system/oracle@FREEPDB1 <<SQL
WHENEVER SQLERROR CONTINUE
CREATE OR REPLACE DIRECTORY NMD_DUMPS AS '/dumps';
CREATE OR REPLACE DIRECTORY NMD_LOG   AS '/tmp';
DECLARE n NUMBER; BEGIN
  SELECT COUNT(*) INTO n FROM dba_users WHERE username='$SCHEMA';
  IF n = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER $SCHEMA IDENTIFIED BY $SCHEMA';
  END IF;
  -- Grants/quota unconditionally (idempotent): the user may pre-exist as a bare stub
  -- grantee (02_secmgr_stub.sql) with no quota, which would fail the load with ORA-01950.
  EXECUTE IMMEDIATE 'ALTER USER $SCHEMA QUOTA UNLIMITED ON USERS';
  EXECUTE IMMEDIATE 'GRANT CREATE SESSION, CREATE TABLE TO $SCHEMA';
END;
/
EXIT
SQL
# Stub users/packages the dump DDL references (SECMGR virtual columns, GRANT REFERENCES
# grantees, VSB package). Idempotent; without them CREATE TABLE fails *silently* for the
# affected tables (they then look "matching" in verify because they exist nowhere).
dc exec -T oracle sqlplus -s system/oracle@FREEPDB1 < oracle-init/02_secmgr_stub.sql >/dev/null

# schema-qualify the optional table list -> tables=SCHEMA.T1,SCHEMA.T2
TABLES_ARG=""
if [ -n "$TABLES" ]; then
  q=""; IFS=',' read -ra arr <<< "$TABLES"
  for t in "${arr[@]}"; do t="${t// /}"; [ -n "$t" ] && q="$q,${SCHEMA}.${t}"; done
  TABLES_ARG="tables=${q#,}"
fi

echo "==> [2/5] impdp $PATTERN  ($SCHEMA) ${TABLES_ARG}"
dc exec -T oracle impdp system/oracle@FREEPDB1 \
  directory=NMD_DUMPS dumpfile="$PATTERN" logfile="NMD_LOG:$LOGFILE" \
  table_exists_action=replace transform=segment_attributes:n \
  exclude=statistics,index,constraint,ref_constraint,grant,trigger,rls_policy,fga_policy \
  $TABLES_ARG \
  && echo "   impdp OK" || echo "   impdp returned errors (see log tail below)"

echo "   ---- impdp log tail (real import result) ----"
dc exec -T oracle tail -n 20 "/tmp/$LOGFILE" 2>/dev/null || true
echo "   ---------------------------------------------"

echo "==> [3/5] convert $SCHEMA -> Postgres"
if [ -n "$TABLES" ]; then
  dc exec -T etl python migrate.py migrate --schema "$SCHEMA" --tables "$TABLES" --force
else
  dc exec -T etl python migrate.py migrate --schema "$SCHEMA"
fi

echo "==> [4/5] verify row counts"
dc exec -T etl python migrate.py verify --schema "$SCHEMA"

# [5/5] reclaim Oracle space so the 12 GB cap doesn't fill across chunks.
# The data is now in Postgres; Oracle is only a staging area. Set KEEP_ORACLE=1 to skip
# (e.g. to inspect in Oracle before dropping).
if [ "${KEEP_ORACLE:-0}" != "1" ]; then
  echo "==> [5/5] free Oracle space (drop converted $SCHEMA tables + purge)"
  dc exec -T oracle sqlplus -s system/oracle@FREEPDB1 <<SQL
WHENEVER SQLERROR CONTINUE
-- Drop converted staging tables. CASCADE CONSTRAINTS: these schemas have FKs between
-- tables (e.g. child->parent), so a bare DROP hits ORA-02449; cascade removes the FK too.
-- PURGE (not recyclebin): reclaim the 12 GB immediately. Per-table exception handling so
-- one stubborn table can't abort the whole sweep and strand space across batches.
BEGIN
  FOR r IN (SELECT table_name FROM all_tables WHERE owner='$SCHEMA') LOOP
    BEGIN EXECUTE IMMEDIATE 'DROP TABLE "$SCHEMA"."'||r.table_name||'" CASCADE CONSTRAINTS PURGE';
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
  FOR r IN (SELECT table_name FROM dba_tables WHERE owner='SYSTEM' AND table_name LIKE 'SYS_IMPORT_%') LOOP
    BEGIN EXECUTE IMMEDIATE 'DROP TABLE SYSTEM."'||r.table_name||'" CASCADE CONSTRAINTS PURGE';
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END;
/
-- Mop up any recyclebin objects that slipped through (SYSTEM can't PURGE DBA_RECYCLEBIN
-- directly -> ORA-01031, so purge per object). Keeps space from leaking across batches.
BEGIN
  FOR r IN (SELECT owner, object_name FROM dba_recyclebin) LOOP
    BEGIN EXECUTE IMMEDIATE 'PURGE TABLE "'||r.owner||'"."'||r.object_name||'"';
    EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
END;
/
-- Shrink the USERS datafile back down. The 12 GB cap counts *allocated* datafile size,
-- and dropping tables never shrinks the file — so big batches balloon it until later
-- batches die with ORA-12954 even though the DB is "empty". Fails harmlessly (ORA-03297)
-- if live extents still sit past the 1 GB mark.
ALTER DATABASE DATAFILE '/opt/oracle/oradata/FREE/FREEPDB1/users01.dbf' RESIZE 1G;
EXIT
SQL
else
  echo "==> [5/5] KEEP_ORACLE=1 — leaving Oracle data in place"
fi
echo "==> done."
