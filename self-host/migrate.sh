#!/usr/bin/env bash
# Wraps the dump/restore steps from RUNBOOK.md Phase 2/3: pulls the garden schema,
# RLS policies, and auth users out of the Supabase Cloud project and loads them
# into the self-hosted Postgres on the NAS.
#
# Requires: supabase CLI (brew install supabase/tap/supabase), psql.
#
# Connection strings are read from env vars, never passed as CLI args or hardcoded
# here, so they don't end up in shell history or get accidentally committed:
#   CLOUD_DB_URL     postgresql://postgres:<password>@<cloud-host>:5432/postgres
#                     (Supabase dashboard -> Project Settings -> Database -> Connection string)
#   SELFHOST_DB_URL  postgresql://postgres:<POSTGRES_PASSWORD>@<nas-ip-or-host>:5432/postgres
#                     (only reachable if you've temporarily published db's port, or run
#                     this script from a machine/container on the compose's Docker network)
#
# Usage:
#   CLOUD_DB_URL=... ./migrate.sh dump
#   SELFHOST_DB_URL=... ./migrate.sh restore
#   CLOUD_DB_URL=... SELFHOST_DB_URL=... ./migrate.sh verify

set -euo pipefail

DUMP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dumps"
mkdir -p "$DUMP_DIR"

cmd="${1:-}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }
}

case "$cmd" in
  dump)
    require supabase
    : "${CLOUD_DB_URL:?Set CLOUD_DB_URL to the Supabase Cloud connection string}"
    echo "Dumping roles..."
    supabase db dump --db-url "$CLOUD_DB_URL" -f "$DUMP_DIR/roles.sql" --role-only
    echo "Dumping schema (includes garden + auth + RLS policies + harvests_view)..."
    supabase db dump --db-url "$CLOUD_DB_URL" -f "$DUMP_DIR/schema.sql"
    echo "Dumping data..."
    supabase db dump --db-url "$CLOUD_DB_URL" -f "$DUMP_DIR/data.sql" --use-copy --data-only
    echo "Done. Files written to $DUMP_DIR — review them before restoring."
    ;;

  restore)
    require psql
    : "${SELFHOST_DB_URL:?Set SELFHOST_DB_URL to the self-hosted Postgres connection string}"
    for f in roles.sql schema.sql data.sql; do
      [ -f "$DUMP_DIR/$f" ] || { echo "Missing $DUMP_DIR/$f — run './migrate.sh dump' first" >&2; exit 1; }
    done
    echo "Restoring roles + schema + data onto self-hosted Postgres..."
    psql \
      --single-transaction \
      --variable ON_ERROR_STOP=1 \
      --file "$DUMP_DIR/roles.sql" \
      --file "$DUMP_DIR/schema.sql" \
      --command 'SET session_replication_role = replica' \
      --file "$DUMP_DIR/data.sql" \
      --dbname "$SELFHOST_DB_URL"
    echo "Restore complete. Run './migrate.sh verify' to compare row counts."
    ;;

  verify)
    require psql
    : "${CLOUD_DB_URL:?Set CLOUD_DB_URL}"
    : "${SELFHOST_DB_URL:?Set SELFHOST_DB_URL}"
    echo "== garden schema row counts =="
    for table in products locations harvests profiles; do
      cloud_count=$(psql "$CLOUD_DB_URL" -Atc "select count(*) from garden.$table")
      self_count=$(psql "$SELFHOST_DB_URL" -Atc "select count(*) from garden.$table")
      status="OK"
      [ "$cloud_count" != "$self_count" ] && status="MISMATCH"
      printf '%-12s cloud=%-6s self-host=%-6s %s\n' "$table" "$cloud_count" "$self_count" "$status"
    done
    echo "== auth.users count =="
    cloud_users=$(psql "$CLOUD_DB_URL" -Atc "select count(*) from auth.users")
    self_users=$(psql "$SELFHOST_DB_URL" -Atc "select count(*) from auth.users")
    printf 'auth.users   cloud=%-6s self-host=%-6s %s\n' "$cloud_users" "$self_users" \
      "$([ "$cloud_users" = "$self_users" ] && echo OK || echo MISMATCH)"
    echo "== RLS policies on garden schema (self-host) =="
    psql "$SELFHOST_DB_URL" -c "select schemaname, tablename, policyname, cmd from pg_policies where schemaname='garden' order by tablename, policyname"
    ;;

  *)
    echo "Usage: $0 {dump|restore|verify}" >&2
    exit 1
    ;;
esac
