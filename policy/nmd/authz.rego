# nmd/authz.rego — OPA policy that would replace the source SECMGR NNPI-masking layer.
#
# The PDP: a PostgreSQL extension (the PEP) sends one query per (subject, table) and
# gets back a decision it compiles into SQL — row_filter -> WHERE, column_masks -> CASE.
# The per-row classification stays in SQL (releasable_predicate strings), so OPA decides
# the RULE once and the database applies it per row, exactly as SECMGR's $ columns did.
#
# See sql/secmgr.sql for the SQL-side reconstruction this mirrors.
package nmd.authz

import rego.v1

# ── clearance (replaces SYS_CONTEXT('UNNPI_CTX','UNNPI')) ─────────────────────
# Attribute-driven and enclave-aware — the modern form of SECMGR's single flag.
nnpi_cleared if {
	input.subject.nnpi_cleared
	input.subject.citizenship == "US"
	input.env.enclave == "high_side"
}

# ── the three flag conventions, verbatim from the dump CASE expressions ───────
releasable_predicate := {
	"bt_data_3m_maintenance": "nnpi_flag IN ('C','S')", # C/S releasable, N nuclear
	"bt_data_3m_narrative": "nnpi_flag IN ('C','S')", # inherited from parent job
	"bt_model_detail": "nuclear_cd = 'N'", # Y redact / N releasable
	"bt_level_indent": "nnpi_flag <> 'Y'", # Y/N domain
}

redactable := {
	"bt_data_3m_maintenance": {"csmp_narrative_summary", "block_35_remark", "equipment", "equipment_desc"},
	"bt_data_3m_narrative": {"problem_tx", "solution_tx", "execution_info_tx"},
	"bt_model_detail": {"esd_tx", "efd_tx"},
}

substitutable := {
	"bt_data_3m_maintenance": {"equipment_nomenclature"},
	"bt_model_detail": {"ric_nomenclature_tx"},
	"bt_level_indent": {"level_indent_description"},
}

substitute_fn := {
	"bt_data_3m_maintenance": "nmd_ric_nomenclature(fin_key)",
	"bt_model_detail": "nmd_ric_nomenclature(fin_key_sa_id)",
	"bt_level_indent": "nmd_ric_nomenclature(level_indent_key)",
}

# columns SECMGR audited (from the dump DBMS_FGA.ADD_POLICY calls)
fga_columns := {
	"bt_data_3m_maintenance": {"csmp_narrative_summary", "equipment_nomenclature", "block_35_remark", "equipment", "equipment_desc"},
	"bt_data_3m_narrative": {"problem_tx", "solution_tx", "execution_info_tx"},
	"bt_model_detail": {"esd_tx", "efd_tx"},
}

# ── row filter (replaces the VPD UNNPI_SEL_SEC_PKG policies) ───────────────────
default row_filter := "false" # fail closed

row_filter := concat(" AND ", sort([c | some c in conditions])) if count(conditions) > 0

conditions contains "TRUE" if nnpi_cleared

# uncleared: on a sensitive table, only releasable rows; elsewhere no row restriction
conditions contains releasable_predicate[input.resource.table] if {
	not nnpi_cleared
	releasable_predicate[input.resource.table]
}

conditions contains "TRUE" if {
	not nnpi_cleared
	not releasable_predicate[input.resource.table]
}

# command scoping (which SECMGR had no equivalent for) — see only your own unit's work
conditions contains uic_scope if {
	not "FLEET_ANALYST" in input.subject.roles
	count(input.subject.uics) > 0
	uic_scope := sprintf("unit_id = ANY(ARRAY[%s])", [concat(",", [sprintf("'%s'", [u]) | some u in input.subject.uics])])
}

# ── column masking (replaces the $ virtual shadow columns) ────────────────────
default column_masks := {}

column_masks := object.union(redact_masks, substitute_masks) if not nnpi_cleared

redact_masks[col] := {"kind": "redact", "unless_row": releasable_predicate[input.resource.table]} if {
	some col in input.resource.columns
	col in redactable[input.resource.table]
}

substitute_masks[col] := {
	"kind": "substitute",
	"unless_row": releasable_predicate[input.resource.table],
	"with": substitute_fn[input.resource.table],
} if {
	some col in input.resource.columns
	col in substitutable[input.resource.table]
}

# ── obligations = the FGA audit replacement ───────────────────────────────────
default obligations := []

obligations := [{"audit": "access", "columns": audited}] if {
	audited := sort([c | some c in input.resource.columns; c in fga_columns[input.resource.table]])
	count(audited) > 0
}

# ── the decision the extension fetches (fail closed by default) ───────────────
default decision := {"allow": false, "row_filter": "false", "column_masks": {}, "obligations": []}

decision := {
	"allow": true,
	"row_filter": row_filter,
	"column_masks": column_masks,
	"obligations": obligations,
} if input.action == "select"
