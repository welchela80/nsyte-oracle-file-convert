#!/usr/bin/env bash
# export_neo4j_csv.sh — export the canonical schema to neo4j-admin bulk-import CSVs.
#
# Graph model (the structurally-connected core of canonical; bulky text/attribute
# tables — comments, narratives, equipment — are intentionally left out of the graph):
#
#   (MaintenanceAction)-[:ON_SHIP]->(Ship)
#   (MaintenanceAction)-[:DURING]->(Availability)
#   (MaintenanceAction)-[:AT_ACTIVITY]->(Activity)
#   (MaintenanceAction)-[:ACTION_TAKEN]->(ActionTakenCode)
#   (Inspection)-[:FOUND]->(MaintenanceAction)
#   (SupplyRequisition)-[:FOR]->(MaintenanceAction)
#   (User)-[:ASSIGNED_TO]->(Activity)
#
# Node keys are source_system-prefixed where the raw id is not globally unique
# (MFOM/VSB_AD3M reuse awn_sa_id); TWOKILOS rows (NULL id) are excluded.
#
# Then load (DB must be stopped) with:
#   docker compose stop neo4j
#   docker compose run --rm --entrypoint neo4j-admin neo4j database import full neo4j \
#     --overwrite-destination=true --skip-bad-relationships=true --skip-duplicate-nodes=true \
#     --nodes=MaintenanceAction=/import/h_action.csv,/import/action.csv \
#     --nodes=Ship=/import/h_ship.csv,/import/ship.csv \
#     --nodes=Activity=/import/h_activity.csv,/import/activity.csv \
#     --nodes=User=/import/h_user.csv,/import/user.csv \
#     --nodes=Availability=/import/h_avail.csv,/import/avail.csv \
#     --nodes=ActionTakenCode=/import/h_atc.csv,/import/atc.csv \
#     --nodes=Inspection=/import/h_insp.csv,/import/insp.csv \
#     --nodes=SupplyRequisition=/import/h_supply.csv,/import/supply.csv \
#     --relationships=ON_SHIP=/import/h_on_ship.csv,/import/rel_on_ship.csv \
#     --relationships=DURING=/import/h_during.csv,/import/rel_during.csv \
#     --relationships=AT_ACTIVITY=/import/h_at_activity.csv,/import/rel_at_activity.csv \
#     --relationships=ACTION_TAKEN=/import/h_action_taken.csv,/import/rel_action_taken.csv \
#     --relationships=FOUND=/import/h_found.csv,/import/rel_found.csv \
#     --relationships=FOR=/import/h_for.csv,/import/rel_for.csv \
#     --relationships=ASSIGNED_TO=/import/h_assigned.csv,/import/rel_assigned.csv
#   docker compose up -d neo4j
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=neo4j-import
mkdir -p "$OUT"
PSQL=(docker exec -i nmd-postgres psql -U nmd -d nmd -v ON_ERROR_STOP=1)
dump() { "${PSQL[@]}" -tAc "COPY ($1) TO STDOUT WITH (FORMAT csv)" > "$OUT/$2"; echo "  $2  ($(wc -l < "$OUT/$2") rows)"; }

echo "== headers =="
printf 'key:ID(Action),source_system,jcn,unit_id,work_center,summary,priority_code,category_of_work,completion_date\n' > "$OUT/h_action.csv"
printf 'uic:ID(Ship),name,hull_number,ship_type_code,status\n'                       > "$OUT/h_ship.csv"
printf 'id:ID(Activity),uic,name,type_code\n'                                        > "$OUT/h_activity.csv"
printf 'id:ID(User),username,last_name\n'                                            > "$OUT/h_user.csv"
printf 'key:ID(Availability),source_system,avail_code,type_code,start_date,end_date\n' > "$OUT/h_avail.csv"
printf 'code:ID(ActionTakenCode),description\n'                                       > "$OUT/h_atc.csv"
printf 'id:ID(Inspection),jcn,priority_code,safety_code,is_casrep\n'                  > "$OUT/h_insp.csv"
printf 'id:ID(SupplyRequisition),niin,status_code,quantity,unit_price,document_number\n' > "$OUT/h_supply.csv"
# relationship headers carry the ID-group of each endpoint so neo4j-admin resolves them
printf ':START_ID(Action),:END_ID(Ship)\n'            > "$OUT/h_on_ship.csv"
printf ':START_ID(Action),:END_ID(Availability)\n'    > "$OUT/h_during.csv"
printf ':START_ID(Action),:END_ID(Activity)\n'        > "$OUT/h_at_activity.csv"
printf ':START_ID(Action),:END_ID(ActionTakenCode)\n' > "$OUT/h_action_taken.csv"
printf ':START_ID(Inspection),:END_ID(Action)\n'      > "$OUT/h_found.csv"
printf ':START_ID(SupplyRequisition),:END_ID(Action)\n' > "$OUT/h_for.csv"
printf ':START_ID(User),:END_ID(Activity)\n'          > "$OUT/h_assigned.csv"

echo "== nodes =="
dump "SELECT source_system||':'||id, source_system, coalesce(jcn,''), coalesce(unit_id,''), coalesce(work_center,''), regexp_replace(coalesce(summary,''),'[\r\n]+',' ','g'), coalesce(priority_code,''), coalesce(category_of_work,''), to_char(completion_date,'YYYY-MM-DD') FROM canonical.maintenance_actions WHERE id IS NOT NULL" action.csv
dump "SELECT DISTINCT ON (uic) uic, coalesce(name,''), coalesce(hull_number,''), coalesce(ship_type_code,''), coalesce(ship_status_code,'') FROM canonical.ships WHERE uic IS NOT NULL" ship.csv
dump "SELECT id, coalesce(uic,''), coalesce(name,''), coalesce(type_code,'') FROM canonical.activities" activity.csv
dump "SELECT id, coalesce(username,''), coalesce(last_name,'') FROM canonical.users" user.csv
dump "SELECT source_system||':'||id, source_system, coalesce(avail_code,''), coalesce(type_code,''), to_char(start_date,'YYYY-MM-DD'), to_char(end_date,'YYYY-MM-DD') FROM canonical.availabilities" avail.csv
dump "SELECT code, coalesce(description,'') FROM canonical.action_taken_codes" atc.csv
dump "SELECT ticket_id, coalesce(jcn,''), coalesce(priority_code,''), coalesce(safety_code,''), coalesce(is_corrected::text,'') FROM canonical.inspections" insp.csv
dump "SELECT id, coalesce(niin,''), coalesce(status_code,''), coalesce(quantity::text,''), coalesce(unit_price::text,''), coalesce(document_number,'') FROM canonical.supply_requisitions" supply.csv

echo "== relationships =="
dump "SELECT source_system||':'||id, unit_id FROM canonical.maintenance_actions WHERE id IS NOT NULL AND unit_id IS NOT NULL" rel_on_ship.csv
dump "SELECT source_system||':'||id, source_system||':'||avail_id FROM canonical.maintenance_actions WHERE id IS NOT NULL AND avail_id IS NOT NULL" rel_during.csv
dump "SELECT source_system||':'||id, activity_id::text FROM canonical.maintenance_actions WHERE id IS NOT NULL AND activity_id IS NOT NULL" rel_at_activity.csv
dump "SELECT source_system||':'||id, action_taken_code FROM canonical.maintenance_actions WHERE id IS NOT NULL AND action_taken_code IS NOT NULL" rel_action_taken.csv
dump "SELECT ticket_id::text, 'AWN:'||ticket_id FROM canonical.inspections WHERE ticket_id IS NOT NULL" rel_found.csv
dump "SELECT id::text, 'AWN:'||ticket_id FROM canonical.supply_requisitions WHERE ticket_id IS NOT NULL" rel_for.csv
dump "SELECT id::text, activity_id::text FROM canonical.users WHERE activity_id IS NOT NULL" rel_assigned.csv
echo "done -> $OUT"
