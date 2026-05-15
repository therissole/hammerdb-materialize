#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

MZ_PG_HOST="${PGHOST:-postgres}"
MZ_PG_PORT="${POSTGRES_PORT:-5432}"
MZ_PG_DB="${POSTGRES_DB:-tpcc}"
MZ_PG_USER="${POSTGRES_USER:-postgres}"
MZ_PG_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
PG_SSLMODE_VAL="${PG_SSLMODE:-prefer}"
if [[ "${PG_SSLMODE_VAL}" == "prefer" ]]; then
	MZ_PG_SSLMODE="disable"
else
	MZ_PG_SSLMODE="${PG_SSLMODE_VAL}"
fi

echo "Applying Materialize SQL setup"
docker compose exec -T postgres psql -h materialized -p 6875 -U materialize -d materialize \
	-v ON_ERROR_STOP=1 \
	-v "mz_pg_host=${MZ_PG_HOST}" \
	-v "mz_pg_port=${MZ_PG_PORT}" \
	-v "mz_pg_db=${MZ_PG_DB}" \
	-v "mz_pg_user=${MZ_PG_USER}" \
	-v "mz_pg_password=${MZ_PG_PASSWORD}" \
	-v "mz_pg_sslmode=${MZ_PG_SSLMODE}" \
	-f /work/scripts/materialize/setup_materialize.sql

echo "Running Materialize smoke checks"
docker compose exec -T postgres psql -h materialized -p 6875 -U materialize -d materialize -f /work/scripts/materialize/smokecheck.sql
