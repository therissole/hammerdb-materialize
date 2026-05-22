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

RDBMS_MODE="${RDBMS:-PGSQL}"
RDBMS_MODE="${RDBMS_MODE^^}"

case "$RDBMS_MODE" in
	PG|PGSQL|POSTGRES|POSTGRESQL)
		PREP_SQL="/work/scripts/materialize/prepare_postgres_for_materialize.sql"
		SETUP_SQL="/work/scripts/materialize/setup_materialize.sql"
		VARS=(
			-v ON_ERROR_STOP=1
			-v "mz_pg_host=${PGHOST:-postgres}"
			-v "mz_pg_port=${POSTGRES_PORT:-5432}"
			-v "mz_pg_db=${POSTGRES_DB:-tpcc}"
			-v "mz_pg_user=${POSTGRES_USER:-postgres}"
			-v "mz_pg_password=${POSTGRES_PASSWORD:-postgres}"
			-v "mz_pg_sslmode=$([[ ${PG_SSLMODE:-prefer} == prefer ]] && printf disable || printf '%s' "${PG_SSLMODE:-prefer}")"
		)
		;;
	MSSQL|MSSQLS|SQLSERVER)
		PREP_SQL="/work/scripts/materialize/prepare_mssql_for_materialize.sql"
		SETUP_SQL="/work/scripts/materialize/setup_materialize_mssql.sql"
		VARS=(
			-v ON_ERROR_STOP=1
			-v "mz_mssql_host=${MSSQL_HOST:-mssql}"
			-v "mz_mssql_port=${MSSQL_PORT:-1433}"
			-v "mz_mssql_db=${MSSQL_DB:-tpcc}"
			-v "mz_mssql_user=${MSSQL_USER:-sa}"
			-v "mz_mssql_password=${MSSQL_SA_PASSWORD:-YourStrong!Passw0rd}"
			-v 'mz_mssql_sslmode=required'
		)
		;;
	*)
		echo "Unsupported RDBMS '$RDBMS_MODE'. Use PGSQL or MSSQL."
		exit 1
		;;
esac

if [[ "$RDBMS_MODE" == "PGSQL" ]]; then
	echo "Preparing Postgres logical publication for Materialize"
	docker compose exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-tpcc}" \
		-v ON_ERROR_STOP=1 \
		-v "mz_pg_host=${PGHOST:-postgres}" \
		-v "mz_pg_port=${POSTGRES_PORT:-5432}" \
		-v "mz_pg_db=${POSTGRES_DB:-tpcc}" \
		-v "mz_pg_user=${POSTGRES_USER:-postgres}" \
		-v "mz_pg_password=${POSTGRES_PASSWORD:-postgres}" \
		-v "mz_pg_sslmode=$([[ ${PG_SSLMODE:-prefer} == prefer ]] && printf disable || printf '%s' "${PG_SSLMODE:-prefer}")" \
		-f "$PREP_SQL"
else
	echo "Preparing SQL Server CDC for Materialize"
	docker compose exec -T mssql bash -lc "/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"${MSSQL_SA_PASSWORD:-YourStrong!Passw0rd}\" -C -b -i $PREP_SQL -v mssql_db='${MSSQL_DB:-tpcc}'"
fi

echo "Applying Materialize SQL setup"
docker compose exec -T materialized psql -h localhost -p 6875 -U materialize -d materialize \
	"${VARS[@]}" \
	-f "$SETUP_SQL"

echo "Running Materialize smoke checks"
docker compose exec -T materialized psql -h localhost -p 6875 -U materialize -d materialize -f /work/scripts/materialize/smokecheck.sql
