#!/usr/bin/env bash
# Скрипт для запуску регулярного обслуговування DSpace та безпечного вимкнення.
# Всі логи пишуться в stdout/stderr, які Cron перенаправляє в єдиний лог-файл.
#     crontab -e
#     0 13 * * * /home/user/шлях/до/папки/scripts/run-maintenance.sh >> /home/user/шлях/до/папки/cron.log 2>&1
#     *Пояснення:*
#     * `0 13 * * *` — 0 хвилин, 13 годин, кожен день, кожен місяць.
#     * `>> .../cron.log` — записувати результат у файл, щоб ти міг перевірити, чи воно працювало.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT="$SCRIPT_DIR/.."
ENVIRONMENT_ARG="${1:-}"

if [[ "${1:-}" == "--env" ]]; then
    [[ $# -ge 2 ]] || { echo "ERROR: Missing value for --env" >&2; exit 1; }
    ENVIRONMENT_ARG="$2"
    shift 2
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0 [--env dev|prod] [--dry-run]"
    exit 0
fi

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    shift
fi

# --- 1. Load env.<env>.enc через локальну SOPS-розшифровку ---
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/autonomous-env.sh"
load_autonomous_env "$PROJECT_ROOT" "$ENVIRONMENT_ARG"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/docker-runtime.sh"

run_dspace_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[dry-run] docker_runtime_exec dspace $*"
    else
        docker_runtime_exec dspace "$@"
    fi
}

echo "[$(date)] --- Starting DSpace Maintenance ---"

# 1. Витягуємо текст з нових файлів (Filter Media)
# ПРИБРАНО: прапорець -v (verbose), щоб не засмічувати лог текстом книг.
# -m 1000: обмежує кількість оброблених за раз файлів.
echo "[$(date)] Running Filter Media..."
run_dspace_cmd /dspace/bin/dspace filter-media -m 1000

# 2. Оновлюємо пошуковий індекс (Discovery)
# -b: build index (оптимізує індекс)
echo "[$(date)] Running Index Discovery..."
run_dspace_cmd /dspace/bin/dspace index-discovery -b

echo "[$(date)] Indexing completed. Checking for OAI updates..."

# 3. Імпортуємо OAI (якщо є нові записи)
echo "[$(date)] OAI import: start"
run_dspace_cmd /dspace/bin/dspace oai import
echo "[$(date)] Imported OAI records"

