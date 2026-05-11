#!/usr/bin/env bash
# Запускає штатний DSpace cleanup для видалення orphan/deleted bitstreams з assetstore.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." &> /dev/null && pwd -P)
ENVIRONMENT_ARG=""
DRY_RUN=false
VERBOSE=true

usage() {
  cat <<'EOF'
Usage: scripts/cleanup-assetstore-orphans.sh [--env dev|prod] [--dry-run] [--no-verbose]

Options:
  --env dev|prod   Вибрати env.<env>.enc. Також можна задати SERVER_ENV.
  --dry-run        Показати команду без запуску cleanup.
  --no-verbose     Запустити DSpace cleanup без прапорця --verbose.
  -h, --help       Показати цю довідку.
EOF
}

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
    --no-verbose)
      VERBOSE=false
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    dev|development|prod|production)
      ENVIRONMENT_ARG="$1"
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/autonomous-env.sh"
load_autonomous_env "$PROJECT_ROOT" "$ENVIRONMENT_ARG"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/docker-runtime.sh"

cleanup_cmd=(/dspace/bin/dspace cleanup)
if [[ "$VERBOSE" == true ]]; then
  cleanup_cmd+=(--verbose)
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting DSpace assetstore cleanup for env=${AUTONOMOUS_ENVIRONMENT}"

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] docker_runtime_exec dspace'
  printf ' %q' "${cleanup_cmd[@]}"
  printf '\n'
  exit 0
fi

docker_runtime_exec dspace "${cleanup_cmd[@]}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] DSpace assetstore cleanup completed"
