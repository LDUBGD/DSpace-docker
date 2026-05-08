#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="${ROOT_DIR}/scripts"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/autonomous-env.sh"

ENVIRONMENT_ARG=""
DRY_RUN=false
BACKUP_PATH=""

usage() {
  cat <<'EOF'
Usage: scripts/test-restore.sh [--env dev|prod] [--dry-run] [backup-archive.tar.gz]

Smoke test restore DSpace SQL dump у тимчасовий PostgreSQL container + textfile metrics.
EOF
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
}

read_env_or_default() {
  local key="$1"
  local default_value="$2"
  local env_value="${!key:-}"

  if [[ -n "$env_value" ]]; then
    printf '%s\n' "$env_value"
    return 0
  fi

  printf '%s\n' "$default_value"
}

abs_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$ROOT_DIR" "$path"
  fi
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      ;;
    --env)
      shift
      [[ "$#" -gt 0 ]] || {
        echo "ERROR: --env requires value" >&2
        usage
        exit 1
      }
      ENVIRONMENT_ARG="$1"
      ;;
    --env=*)
      ENVIRONMENT_ARG="${1#--env=}"
      ;;
    dev|development|prod|production)
      ENVIRONMENT_ARG="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "$BACKUP_PATH" ]]; then
        BACKUP_PATH="$1"
      else
        echo "ERROR: unexpected argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
  shift
done

load_autonomous_env "${ROOT_DIR}" "${ENVIRONMENT_ARG}"
cd "${ROOT_DIR}"

require_command docker
require_command find
require_command tar
require_command mktemp

POSTGRES_VERSION="$(read_env_or_default POSTGRES_VERSION 15)"
POSTGRES_DB="$(read_env_or_default POSTGRES_DB dspace)"
POSTGRES_USER="$(read_env_or_default POSTGRES_USER dspace)"
BACKUP_LOCAL_DIR="$(read_env_or_default BACKUP_LOCAL_DIR /data/backup/dspace)"
NODE_EXPORTER_TEXTFILE_DIR="$(read_env_or_default NODE_EXPORTER_TEXTFILE_DIR /data/node-exporter-textfile)"
RESTORE_SMOKE_METRICS_FILE="$(read_env_or_default RESTORE_SMOKE_METRICS_FILE dspace_restore_smoke.prom)"
RESTORE_SMOKE_ENV_LABEL="$(read_env_or_default RESTORE_SMOKE_ENV_LABEL prod)"
RESTORE_SMOKE_SERVICE_LABEL="$(read_env_or_default RESTORE_SMOKE_SERVICE_LABEL dspace)"
RESTORE_SMOKE_TIMEOUT_SECONDS="$(read_env_or_default RESTORE_SMOKE_TIMEOUT_SECONDS 90)"

if ! [[ "$RESTORE_SMOKE_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$RESTORE_SMOKE_TIMEOUT_SECONDS" -lt 10 ]]; then
  echo "ERROR: RESTORE_SMOKE_TIMEOUT_SECONDS must be an integer >= 10" >&2
  exit 1
fi

BACKUP_DIR_ABS="$(abs_path "$BACKUP_LOCAL_DIR")"
if [[ -n "$BACKUP_PATH" ]]; then
  if [[ "$BACKUP_PATH" != /* ]]; then
    BACKUP_PATH="$(abs_path "$BACKUP_PATH")"
  fi
else
  BACKUP_PATH="$(
    find "$BACKUP_DIR_ABS" -maxdepth 1 -type f \
      \( -name 'cloud_metadata_*.tar.gz' -o -name 'full_local_*.tar.gz' \) \
      -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr \
      | head -n1 \
      | awk '{print $2}' || true
  )"
fi

if [[ -z "$BACKUP_PATH" ]]; then
  echo "ERROR: backup archive not found. Pass archive path or create a backup in $BACKUP_DIR_ABS" >&2
  exit 1
fi

if [[ ! -f "$BACKUP_PATH" ]]; then
  echo "ERROR: backup archive not found: $BACKUP_PATH" >&2
  exit 1
fi

if [[ "$BACKUP_PATH" != *.tar.gz ]]; then
  echo "ERROR: unsupported backup format. Use .tar.gz" >&2
  exit 1
fi

run_timestamp="$(date +%s)"
success_timestamp="0"
restore_status="0"
emit_metrics_on_exit="1"

if [[ "$DRY_RUN" == true ]]; then
  emit_metrics_on_exit="0"
fi

ensure_metrics_dir() {
  local dir="$1"
  if mkdir -p "$dir" >/dev/null 2>&1; then
    return 0
  fi

  local parent_dir
  local base_name
  parent_dir="$(dirname "$dir")"
  base_name="$(basename "$dir")"

  if [[ ! -d "$parent_dir" ]]; then
    echo "ERROR: metrics parent directory does not exist: $parent_dir" >&2
    return 1
  fi

  docker run --rm \
    -v "$parent_dir:/parent" \
    alpine:3.20 \
    sh -c "mkdir -p '/parent/$base_name'" >/dev/null
}

emit_restore_metrics() {
  ensure_metrics_dir "$NODE_EXPORTER_TEXTFILE_DIR" || {
    echo "WARN: failed to prepare metrics dir: $NODE_EXPORTER_TEXTFILE_DIR" >&2
    return 0
  }

  local metrics_payload
  metrics_payload="$(cat <<EOF
# HELP dspace_restore_smoke_last_run_timestamp_seconds Unix timestamp of the last DSpace restore smoke test attempt.
# TYPE dspace_restore_smoke_last_run_timestamp_seconds gauge
dspace_restore_smoke_last_run_timestamp_seconds{env="$RESTORE_SMOKE_ENV_LABEL",service="$RESTORE_SMOKE_SERVICE_LABEL"} $run_timestamp
# HELP dspace_restore_smoke_last_success_timestamp_seconds Unix timestamp of the last successful DSpace restore smoke test.
# TYPE dspace_restore_smoke_last_success_timestamp_seconds gauge
dspace_restore_smoke_last_success_timestamp_seconds{env="$RESTORE_SMOKE_ENV_LABEL",service="$RESTORE_SMOKE_SERVICE_LABEL"} $success_timestamp
# HELP dspace_restore_smoke_last_status Last DSpace restore smoke test status (1=success, 0=failure).
# TYPE dspace_restore_smoke_last_status gauge
dspace_restore_smoke_last_status{env="$RESTORE_SMOKE_ENV_LABEL",service="$RESTORE_SMOKE_SERVICE_LABEL"} $restore_status
EOF
)"

  printf '%s\n' "$metrics_payload" | docker run --rm -i \
    -v "$NODE_EXPORTER_TEXTFILE_DIR:/metrics" \
    alpine:3.20 \
    sh -c "cat > /metrics/$RESTORE_SMOKE_METRICS_FILE"
}

tmp_dir="$(mktemp -d)"
container_name="dspace-restore-smoke-$(date +%s)"
smoke_password="dspace_restore_smoke_pass"

cleanup() {
  local exit_code=$?
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  rm -rf "$tmp_dir" >/dev/null 2>&1 || true
  if [[ "$emit_metrics_on_exit" == "1" ]]; then
    emit_restore_metrics
  fi
  exit "$exit_code"
}
trap cleanup EXIT

echo "[restore-smoke] backup archive: $BACKUP_PATH"
echo "[restore-smoke] metrics file: $NODE_EXPORTER_TEXTFILE_DIR/$RESTORE_SMOKE_METRICS_FILE"

if [[ "$DRY_RUN" == true ]]; then
  echo "[restore-smoke] DRY RUN: restore smoke test and metrics update are skipped"
  echo "[restore-smoke][dry-run] tar -xzf \"$BACKUP_PATH\" -C \"$tmp_dir/extract\""
  echo "[restore-smoke][dry-run] docker run postgres:${POSTGRES_VERSION} and import SQL dump"
  exit 0
fi

mkdir -p "$tmp_dir/extract" "$tmp_dir/pgdata"
tar -xzf "$BACKUP_PATH" -C "$tmp_dir/extract"

sql_dump="$(find "$tmp_dir/extract" -maxdepth 6 -type f -name '*.sql' | head -n1 || true)"
if [[ -z "$sql_dump" ]]; then
  echo "ERROR: SQL dump (*.sql) not found in archive: $BACKUP_PATH" >&2
  exit 1
fi

echo "[restore-smoke] SQL dump: $sql_dump"
echo "[restore-smoke] starting temporary PostgreSQL container: $container_name"
docker run -d --name "$container_name" \
  -e "POSTGRES_PASSWORD=$smoke_password" \
  -e "POSTGRES_USER=$POSTGRES_USER" \
  -e "POSTGRES_DB=$POSTGRES_DB" \
  -v "$tmp_dir/pgdata:/var/lib/postgresql/data" \
  "docker.io/postgres:${POSTGRES_VERSION}" >/dev/null

max_attempts=$((RESTORE_SMOKE_TIMEOUT_SECONDS / 2))
for attempt in $(seq 1 "$max_attempts"); do
  if docker exec "$container_name" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" -eq "$max_attempts" ]]; then
    echo "ERROR: temporary PostgreSQL did not become ready within ${RESTORE_SMOKE_TIMEOUT_SECONDS}s" >&2
    docker logs "$container_name" --tail 100 || true
    exit 1
  fi
  sleep 2
done

echo "[restore-smoke] importing SQL dump into temporary database"
docker exec -i "$container_name" psql \
  -v ON_ERROR_STOP=1 \
  -q \
  -U "$POSTGRES_USER" \
  -d "$POSTGRES_DB" < "$sql_dump" >/dev/null

table_count="$(
  docker exec "$container_name" psql \
    -At \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema');"
)"

if ! [[ "$table_count" =~ ^[0-9]+$ ]] || [[ "$table_count" -lt 1 ]]; then
  echo "ERROR: restore smoke sanity check failed (table count: ${table_count:-n/a})" >&2
  exit 1
fi

restore_status="1"
success_timestamp="$(date +%s)"
echo "[restore-smoke] completed successfully (tables restored: $table_count)"
