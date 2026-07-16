# Normalization: raw → canonical

Loading gives you a **faithful 1:1 copy** of each Oracle source in its own Postgres schema
(`mfom`, `nmdr`, …). That's the right first step — but to analyze several sources **as one dataset**,
you map them into a shared **`canonical`** schema with consistent names, types, and codes.

This is deliberately a **second, separate stage**: keep raw untouched, build canonical on top of it in
Postgres with plain SQL. It's re-runnable and easy to review.

---

## The sensible-default rules

Applied per table (see `sql/normalize_example.sql` for a full worked example):

1. **Target schema `canonical`, clean entity names** — e.g. `mfom.bt_user_information` → `canonical.users`.
2. **Column names** — drop Oracle-isms:
   - `*_tx` (text) → drop the suffix (`title_tx` → `title`)
   - `*_cd` (code) → `*_code` (`status_cd` → `status_code`)
   - `*_key` (numeric id) → `*_id` (`port_key` → `port_id`)
   - ad-hoc fixups (`logincount` → `login_count`, `us_state` → `state_code`)
3. **Values** — `btrim()` whitespace; empty string → `NULL`; lowercase emails; uppercase code/state fields.
4. **Surrogate keys** — Oracle `RAW`/`bytea` keys become readable **hex text** (`encode(col,'hex')`).
5. **Drop secrets / internal audit columns** — passwords, session cookies, PINs, internal audit
   pointers. They're not analytical and shouldn't be copied around.
6. **Provenance** — add `source_system` (e.g. `'MFOM'`). This is what lets you `UNION` the same entity
   from multiple sources and still know where each row came from.

---

## Worked example

`sql/normalize_example.sql` normalizes `mfom.bt_user_information` (49 raw columns) into
`canonical.users`. Run it:

```bash
docker compose exec -T postgres psql -U nmd -d nmd < sql/normalize_example.sql
docker compose exec -T postgres psql -U nmd -d nmd -c \
  "SELECT id, source_system, first_name, last_name, email, state_code, status_code FROM canonical.users LIMIT 5;"
```

A representative column, before → after:

| raw (`mfom.bt_user_information`) | canonical (`canonical.users`) | transform |
|---|---|---|
| `user_sa_id` (`bytea`) | `id` (`text`) | `encode(user_sa_id,'hex')`, primary key |
| `us_state` (`text`) | `state_code` | `upper(nullif(btrim(...),''))` |
| `status_cd` | `status_code` | rename + clean |
| `title_tx` | `title` | drop `_tx`, clean |
| `password`, `cert_cookie`, `pin_tx` | — | dropped (secret) |
| — | `source_system` | constant `'MFOM'` |

---

## Writing one for another table

1. Look at the raw table:
   ```bash
   docker compose exec -T postgres psql -U nmd -d nmd -c "\d mfom.bt_role"
   ```
2. Copy `sql/normalize_example.sql`, point it at the raw table, apply the rules above, and pick a
   canonical target name.
3. Run it, then sanity-check the row count matches the raw table and spot-check values.

---

## Merging sources (the end goal)

When the "same" entity exists in multiple sources, build the canonical table as a `UNION ALL` of each
source's cleaned projection, each tagged with its `source_system` — then de-duplicate/reconcile on a
shared natural key if one exists. Example shape:

```sql
CREATE TABLE canonical.users AS
SELECT ... , 'MFOM' AS source_system FROM mfom.bt_user_information
UNION ALL
SELECT ... , 'NMDR' AS source_system FROM nmdr.some_user_table;
```

Designing that shared model (which entities overlap, which keys align, how codes map) is the analysis
step to do **after** the sources are loaded and profiled — not something to guess up front.
