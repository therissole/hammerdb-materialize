#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

load_dotenv() {
  local dotenv_file="$ROOT_DIR/.env"
  if [[ ! -f "$dotenv_file" ]]; then
    return 0
  fi

  while IFS='=' read -r key value; do
    [[ -z "${key:-}" ]] && continue
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    key="${key%%[[:space:]]*}"
    value="${value%$'\r'}"
    if [[ -z "${!key+x}" ]]; then
      export "$key=$value"
    fi
  done < "$dotenv_file"
}

load_dotenv

HAMMERDB_CLI="${HAMMERDB_CLI:-/home/HammerDB-5.0/hammerdbcli}"
RDBMS_MODE="${RDBMS:-PGSQL}"
RDBMS_MODE="${RDBMS_MODE^^}"

run_hammerdb() {
  docker compose exec -T hammerdb bash -lc "$1"
}

wait_for_service() {
  local service_name="$1"
  local check_command="$2"
  local attempt=1
  local max_attempts=30

  while true; do
    if docker compose exec -T "$service_name" bash -lc "$check_command" >/dev/null 2>&1; then
      return 0
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "$service_name did not become ready in time" >&2
      return 1
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
}

case "$RDBMS_MODE" in
  PG|PGSQL|POSTGRES|POSTGRESQL)
    RDBMS_MODE="PGSQL"
    COMPOSE_PROFILE="pgsql"
    DB_SERVICE="postgres"
    HAMMERDB_BUILD_SCRIPT="/work/scripts/hammerdb/custom/pg_tprocc_buildschema_docker.tcl"
    HAMMERDB_CHECK_SCRIPT="/work/scripts/hammerdb/custom/pg_tprocc_checkschema_docker.tcl"
    HAMMERDB_RUN_SCRIPT="/work/scripts/hammerdb/custom/pg_tprocc_run_profile_docker.tcl"
    PREP_SQL="/work/scripts/materialize/prepare_postgres_for_materialize.sql"
    SETUP_SQL="/work/scripts/materialize/setup_materialize.sql"
    PG_SSLMODE_VAL="${PG_SSLMODE:-prefer}"
    if [[ "$PG_SSLMODE_VAL" == "prefer" ]]; then
      MZ_PG_SSLMODE="disable"
    else
      MZ_PG_SSLMODE="$PG_SSLMODE_VAL"
    fi
    ;;
  MSSQL|MSSQLS|SQLSERVER)
    RDBMS_MODE="MSSQL"
    COMPOSE_PROFILE="mssql"
    DB_SERVICE="mssql"
    HAMMERDB_BUILD_SCRIPT="/work/scripts/hammerdb/custom/mssqls_tprocc_buildschema_docker.tcl"
    HAMMERDB_CHECK_SCRIPT="/work/scripts/hammerdb/custom/mssqls_tprocc_checkschema_docker.tcl"
    HAMMERDB_RUN_SCRIPT="/work/scripts/hammerdb/custom/mssqls_tprocc_run_profile_docker.tcl"
    PREP_SQL="/work/scripts/materialize/prepare_mssql_for_materialize.sql"
    SETUP_SQL="/work/scripts/materialize/setup_materialize_mssql.sql"
    ;;
  *)
    echo "Unsupported RDBMS '$RDBMS_MODE'. Use PGSQL or MSSQL."
    exit 1
    ;;
esac

echo "Stopping containers and removing data volumes"
docker compose --profile pgsql --profile mssql down -v --remove-orphans

echo "Starting containers"
docker compose --profile "$COMPOSE_PROFILE" up -d

echo "Waiting for ${RDBMS_MODE} to be ready"
if [[ "$RDBMS_MODE" == "PGSQL" ]]; then
  wait_for_service "$DB_SERVICE" "pg_isready -U \"${POSTGRES_USER:-postgres}\" -d \"${POSTGRES_DB:-tpcc}\""
else
  wait_for_service "$DB_SERVICE" 'if command -v /opt/mssql-tools18/bin/sqlcmd >/dev/null 2>&1; then /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "SELECT 1" -b >/dev/null 2>&1; elif command -v /opt/mssql-tools/bin/sqlcmd >/dev/null 2>&1; then /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q "SELECT 1" -b >/dev/null 2>&1; else exit 1; fi'
fi

echo "Building TPROC-C schema in ${RDBMS_MODE} via HammerDB"
run_hammerdb "mkdir -p /work/tmp; ${HAMMERDB_CLI} auto ${HAMMERDB_BUILD_SCRIPT}"

echo "Checking TPCC schema"
run_hammerdb "${HAMMERDB_CLI} auto ${HAMMERDB_CHECK_SCRIPT}"

if [[ "$RDBMS_MODE" == "PGSQL" ]]; then
  echo "Preparing Postgres logical publication for Materialize"
  docker compose exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-tpcc}" \
    -v ON_ERROR_STOP=1 \
    -v "mz_pg_host=${PGHOST:-postgres}" \
    -v "mz_pg_port=${POSTGRES_PORT:-5432}" \
    -v "mz_pg_db=${POSTGRES_DB:-tpcc}" \
    -v "mz_pg_user=${POSTGRES_USER:-postgres}" \
    -v "mz_pg_password=${POSTGRES_PASSWORD:-postgres}" \
    -v "mz_pg_sslmode=${MZ_PG_SSLMODE}" \
    -f "$PREP_SQL"

  echo "Setting up Materialize source in schema tpcc (all publication tables)"
  docker compose exec -T materialized psql -h localhost -p 6875 -U materialize -d materialize \
    -v ON_ERROR_STOP=1 \
    -v "mz_pg_host=${PGHOST:-postgres}" \
    -v "mz_pg_port=${POSTGRES_PORT:-5432}" \
    -v "mz_pg_db=${POSTGRES_DB:-tpcc}" \
    -v "mz_pg_user=${POSTGRES_USER:-postgres}" \
    -v "mz_pg_password=${POSTGRES_PASSWORD:-postgres}" \
    -v "mz_pg_sslmode=${MZ_PG_SSLMODE}" \
    -f "$SETUP_SQL"
else
  echo "Preparing SQL Server CDC for Materialize"
  docker compose exec -T mssql bash -lc "/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"${MSSQL_SA_PASSWORD:-YourStrong!Passw0rd}\" -C -b -i /work/scripts/materialize/prepare_mssql_for_materialize.sql -v mssql_db='${MSSQL_DB:-tpcc}'"

  echo "Setting up Materialize source in schema tpcc (all CDC tables)"
  docker compose exec -T materialized psql -h localhost -p 6875 -U materialize -d materialize \
    -v ON_ERROR_STOP=1 \
    -v "mz_mssql_host=${MSSQL_HOST:-mssql}" \
    -v "mz_mssql_port=${MSSQL_PORT:-1433}" \
    -v "mz_mssql_db=${MSSQL_DB:-tpcc}" \
    -v "mz_mssql_user=${MSSQL_USER:-sa}" \
    -v "mz_mssql_password=${MSSQL_SA_PASSWORD:-YourStrong!Passw0rd}" \
    -v "mz_mssql_sslmode=required" \
    -f "$SETUP_SQL"
fi

echo "Running TPCC workload"
run_hammerdb "${HAMMERDB_CLI} auto ${HAMMERDB_RUN_SCRIPT}"

echo "Cycle complete. HammerDB output files are in ./tmp"
