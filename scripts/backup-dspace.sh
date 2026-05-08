#!/usr/bin/env bash
set -euo pipefail

# Paths
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." &> /dev/null && pwd -P)
ENVIRONMENT_ARG=""
DRY_RUN=false
backup_status="0"
run_timestamp="$(date +%s)"
success_timestamp="0"
emit_metrics_on_exit="1"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --env)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: Missing value for --env" >&2; exit 1; }
      ENVIRONMENT_ARG="$1"
      ;;
    --env=*)
      ENVIRONMENT_ARG="${1#--env=}"
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    -h|--help)
      echo "Usage: $0 [--env dev|prod] [--dry-run]"
      exit 0
      ;;
    dev|development|prod|production)
      ENVIRONMENT_ARG="$1"
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

# --- 1. Load env.<env>.enc через локальну SOPS-розшифровку ---
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/autonomous-env.sh"
load_autonomous_env "$PROJECT_ROOT" "$ENVIRONMENT_ARG"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/docker-runtime.sh"

# 2. Перевірка критичних змінних
# Якщо ці змінні не задані в env.<env>.enc, скрипт зупиниться
: "${VOL_ASSETSTORE_PATH:?Variable VOL_ASSETSTORE_PATH not set in env file}"
: "${BACKUP_RCLONE_REMOTE:?Variable BACKUP_RCLONE_REMOTE not set in env file}"
: "${DB_SERVICE_NAME:?Variable DB_SERVICE_NAME not set in env file}"
: "${BACKUP_ASSETSTORE_MIRROR:?Variable BACKUP_ASSETSTORE_MIRROR not set in env file}"

NODE_EXPORTER_TEXTFILE_DIR="${NODE_EXPORTER_TEXTFILE_DIR:-/data/node-exporter-textfile}"
BACKUP_METRICS_FILE="${BACKUP_METRICS_FILE:-dspace_backup.prom}"
BACKUP_METRICS_ENV_LABEL="${BACKUP_METRICS_ENV_LABEL:-prod}"
BACKUP_METRICS_SERVICE_LABEL="${BACKUP_METRICS_SERVICE_LABEL:-dspace}"

if [[ "$DRY_RUN" == true ]]; then
    emit_metrics_on_exit="0"
fi

resolve_absolute_path() {
    local raw_path="$1"
    local path="$raw_path"
    local dir
    local suffix

    if [[ "$path" != /* ]]; then
        path="${PROJECT_ROOT}/${path}"
    fi

    dir="$(dirname "$path")"
    suffix="$(basename "$path")"
    while [[ ! -d "$dir" && "$dir" != "/" ]]; do
        suffix="$(basename "$dir")/${suffix}"
        dir="$(dirname "$dir")"
    done

    if [[ "$dir" == "/" ]]; then
        printf '/%s\n' "$suffix"
    else
        printf '%s/%s\n' "$(cd "$dir" &> /dev/null && pwd -P)" "$suffix"
    fi
}

init_backup_dir() {
    local dir="$1"
    local mode="0750"
    local owner_uid
    local owner_gid

    owner_uid="$(id -u)"
    owner_gid="$(id -g)"
    if [[ "$owner_uid" == "0" && -n "${SUDO_UID:-}" ]]; then
        owner_uid="$SUDO_UID"
        owner_gid="${SUDO_GID:-$owner_gid}"
    fi

    if [[ "$(id -u)" == "0" ]]; then
        install -d -m "$mode" -o "$owner_uid" -g "$owner_gid" "$dir"
        return 0
    fi

    if install -d -m "$mode" "$dir" 2> /dev/null; then
        return 0
    fi

    if command -v sudo > /dev/null && sudo -n true 2> /dev/null; then
        sudo -n install -d -m "$mode" -o "$owner_uid" -g "$owner_gid" "$dir"
        return 0
    fi

    printf 'ERROR: Cannot create backup directory with required permissions: %s\n' "$dir" >&2
    printf '       Run once with a user that can create it, or configure passwordless sudo for install -d.\n' >&2
    exit 1
}

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

emit_backup_metrics() {
    ensure_metrics_dir "$NODE_EXPORTER_TEXTFILE_DIR" || {
        echo "WARN: failed to prepare metrics dir: $NODE_EXPORTER_TEXTFILE_DIR" >&2
        return 0
    }

    local metrics_payload
    metrics_payload="$(cat <<EOF
# HELP dspace_backup_last_run_timestamp_seconds Unix timestamp of the last DSpace backup attempt.
# TYPE dspace_backup_last_run_timestamp_seconds gauge
dspace_backup_last_run_timestamp_seconds{env="$BACKUP_METRICS_ENV_LABEL",service="$BACKUP_METRICS_SERVICE_LABEL"} $run_timestamp
# HELP dspace_backup_last_success_timestamp_seconds Unix timestamp of the last successful DSpace backup.
# TYPE dspace_backup_last_success_timestamp_seconds gauge
dspace_backup_last_success_timestamp_seconds{env="$BACKUP_METRICS_ENV_LABEL",service="$BACKUP_METRICS_SERVICE_LABEL"} $success_timestamp
# HELP dspace_backup_last_status Last DSpace backup status (1=success, 0=failure).
# TYPE dspace_backup_last_status gauge
dspace_backup_last_status{env="$BACKUP_METRICS_ENV_LABEL",service="$BACKUP_METRICS_SERVICE_LABEL"} $backup_status
EOF
)"

    printf '%s\n' "$metrics_payload" | docker run --rm -i \
        -v "$NODE_EXPORTER_TEXTFILE_DIR:/metrics" \
        alpine:3.20 \
        sh -c "cat > /metrics/$BACKUP_METRICS_FILE"
}

on_exit() {
    local exit_code=$?
    if [[ "$emit_metrics_on_exit" == "1" ]]; then
        if [[ "$exit_code" -eq 0 && "$backup_status" != "1" ]]; then
            backup_status="1"
            success_timestamp="$(date +%s)"
        fi
        emit_backup_metrics
    fi
    exit "$exit_code"
}

# 3. Налаштування шляхів
BACKUP_LOCAL_DIR_RAW="${BACKUP_LOCAL_DIR:-backups}"
BACKUP_DIR="$(resolve_absolute_path "$BACKUP_LOCAL_DIR_RAW")"
DATE=$(date +%Y-%m-%d_%H-%M)

# Створення папки бекапів
if [[ "$DRY_RUN" != true ]]; then
    init_backup_dir "$BACKUP_DIR"
    BACKUP_DIR=$(cd "$BACKUP_DIR" &> /dev/null && pwd -P)
fi
LOG_FILE="${BACKUP_DIR}/backup_log.txt"
export BACKUP_DIR DATE LOG_FILE DRY_RUN PROJECT_ROOT

# Імена файлів
SQL_DUMP="${BACKUP_DIR}/dspace_db_${DATE}.sql"
ARCHIVE_CLOUD="${BACKUP_DIR}/cloud_metadata_${DATE}.tar.gz"  # Тільки база + конфіги
ARCHIVE_LOCAL="${BACKUP_DIR}/full_local_${DATE}.tar.gz"      # Все + файли книг
ENV_ARCHIVE_FILE="env.${AUTONOMOUS_ENVIRONMENT}.enc"
export SQL_DUMP ARCHIVE_CLOUD ARCHIVE_LOCAL ENV_ARCHIVE_FILE

# Функція для логування
log() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    else
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
    fi
}

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/backup-metadata.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/backup-assetstore.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/backup-cleanup.sh"

check_prerequisites() {
    local missing=()

    command -v rclone &> /dev/null || missing+=("rclone")
    command -v rsync &> /dev/null || missing+=("rsync")
    command -v sha256sum &> /dev/null || missing+=("sha256sum")

    if [[ ${#missing[@]} -gt 0 ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            log "WARNING: Missing required tools for real run: ${missing[*]}"
        else
            log "ERROR: Missing required tools: ${missing[*]}"
            exit 1
        fi
    fi

    local df_target="$BACKUP_DIR"
    while [[ ! -e "$df_target" && "$df_target" != "/" ]]; do
        df_target="$(dirname "$df_target")"
    done

    local free_kb
    free_kb=$(df --output=avail "$df_target" | tail -1)
    if (( free_kb < 10485760 )); then
        log "WARNING: Less than 10 GB free on backup filesystem (${free_kb} KB available)."
    fi
}

partial_cleanup() {
    log "ERROR: Backup aborted. Removing partial artifacts."
    [[ -n "${SQL_DUMP:-}" ]] && rm -f "$SQL_DUMP"
    [[ -n "${ARCHIVE_CLOUD:-}" ]] && rm -f "$ARCHIVE_CLOUD" "${ARCHIVE_CLOUD}.sha256"
    [[ -n "${ARCHIVE_LOCAL:-}" ]] && rm -f "$ARCHIVE_LOCAL"
}

trap partial_cleanup ERR
trap on_exit EXIT

log "=== Starting Backup Routine ==="

check_prerequisites
backup_metadata
backup_assetstore
backup_cleanup

backup_status="1"
success_timestamp="$(date +%s)"

log "=== Backup Finished ==="
