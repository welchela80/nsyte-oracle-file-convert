# nmd/authz_test.rego — run with:  opa test policy/ -v
package nmd.authz_test

import rego.v1

import data.nmd.authz

# an uncleared unit maintainer: free text redacted, nomenclature substituted,
# rows filtered to releasable + their own UIC, and the touch audited.
test_uncleared_unit_user_masks_scopes_audits if {
	d := authz.decision with input as {
		"subject": {"roles": ["UNIT_MAINTAINER"], "nnpi_cleared": false, "citizenship": "US", "uics": ["21687"]},
		"action": "select",
		"resource": {"schema": "mfom", "table": "bt_data_3m_maintenance", "columns": ["jcn", "csmp_narrative_summary", "equipment_nomenclature"]},
		"env": {"enclave": "low_side"},
	}
	d.allow
	d.column_masks.csmp_narrative_summary.kind == "redact"
	d.column_masks.equipment_nomenclature.kind == "substitute"
	d.column_masks.equipment_nomenclature.with == "nmd_ric_nomenclature(fin_key)"
	contains(d.row_filter, "nnpi_flag IN ('C','S')") # VPD row filter
	contains(d.row_filter, "unit_id = ANY(ARRAY['21687'])") # UIC scope
	d.obligations[0].audit == "access"
}

# jcn is not a masked column — must pass through untouched
test_unmasked_column_absent_from_masks if {
	d := authz.decision with input as {
		"subject": {"roles": ["UNIT_MAINTAINER"], "nnpi_cleared": false, "citizenship": "US", "uics": ["21687"]},
		"action": "select",
		"resource": {"schema": "mfom", "table": "bt_data_3m_maintenance", "columns": ["jcn"]},
		"env": {"enclave": "low_side"},
	}
	not d.column_masks.jcn
}

# a cleared fleet analyst on the high side: no masks, no row restriction
test_cleared_fleet_analyst_sees_all if {
	d := authz.decision with input as {
		"subject": {"roles": ["FLEET_ANALYST"], "nnpi_cleared": true, "citizenship": "US", "uics": []},
		"action": "select",
		"resource": {"schema": "mfom", "table": "bt_data_3m_maintenance", "columns": ["csmp_narrative_summary"]},
		"env": {"enclave": "high_side"},
	}
	d.column_masks == {}
	d.row_filter == "TRUE"
}

# clearance requires citizenship AND high-side enclave — cleared claim on low side fails
test_cleared_claim_on_low_side_is_not_cleared if {
	d := authz.decision with input as {
		"subject": {"roles": ["FLEET_ANALYST"], "nnpi_cleared": true, "citizenship": "US", "uics": []},
		"action": "select",
		"resource": {"schema": "mfom", "table": "bt_data_3m_narrative", "columns": ["problem_tx"]},
		"env": {"enclave": "low_side"},
	}
	d.column_masks.problem_tx.kind == "redact"
}

# the model_detail Y/N flag convention differs from the C/S/N job flag
test_model_detail_uses_nuclear_cd_convention if {
	d := authz.decision with input as {
		"subject": {"roles": ["FLEET_ANALYST"], "nnpi_cleared": false, "citizenship": "US", "uics": []},
		"action": "select",
		"resource": {"schema": "mfom", "table": "bt_model_detail", "columns": ["esd_tx", "ric_nomenclature_tx"]},
		"env": {"enclave": "low_side"},
	}
	d.column_masks.esd_tx.unless_row == "nuclear_cd = 'N'"
	d.column_masks.ric_nomenclature_tx.kind == "substitute"
}

# default deny: a non-select action gets the fail-closed decision
test_non_select_denied if {
	d := authz.decision with input as {
		"subject": {"roles": ["FLEET_ANALYST"], "nnpi_cleared": true, "citizenship": "US", "uics": []},
		"action": "update",
		"resource": {"schema": "mfom", "table": "bt_data_3m_maintenance", "columns": ["csmp_narrative_summary"]},
		"env": {"enclave": "high_side"},
	}
	not d.allow
	d.row_filter == "false"
}
