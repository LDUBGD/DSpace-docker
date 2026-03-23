#!/usr/bin/env bash
# init-volumes.sh
# Ініціалізує директорії томів для DSpace stack та виставляє безпечні права.
# Принципи:
# - SSOT: шляхи беремо з .env (VOL_*).
# - Безпека: для PostgreSQL PGDATA не допускаємо 777 (директорії 700, файли 600).
# - Передбачуваність: ownership задаємо numeric UID:GID, які відповідають користувачам у контейнерах.
#
# Використання:
#   ./scripts/init-volumes.sh
#   ./scripts/init-volumes.sh --fix-existing   # (ОБЕРЕЖНО) також нормалізує права у вже існуючих каталогах

set -euo pipefail

FIX_EXISTING=false
if [[ "${1:-}" == "--fix-existing" ]]; then
  FIX_EXISTING=true
fi

# --- 1) Load .env (robust) ---
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
ENV_FILE="$SCRIPT_DIR/../.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ Error: .env file not found at: $ENV_FILE" >&2
  exit 1
fi

echo "🌍 Loading environment variables from .env..."
while IFS='=' read -r key value; do
  [[ "$key" =~ ^\s*# ]] && continue
  [[ -z "${key//[[:space:]]/}" ]] && continue

  # trim ключ
  key=$(echo "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

  # значення: trim + strip quotes
  value=$(echo "${value:-}" | sed \
    -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    -e 's/^"//' -e 's/"$//' \
    -e "s/^'//" -e "s/'$//")

  export "$key=$value"
done < <(grep -vE '^\s*#' "$ENV_FILE" | grep -vE '^\s*$')

# --- 2) Validate required paths (SSOT) ---
: "${VOL_POSTGRESQL_PATH:?VOL_POSTGRESQL_PATH is required in .env}"
: "${VOL_SOLR_PATH:?VOL_SOLR_PATH is required in .env}"
: "${VOL_ASSETSTORE_PATH:?VOL_ASSETSTORE_PATH is required in .env}"
: "${VOL_EXPORTS_PATH:?VOL_EXPORTS_PATH is required in .env}"
: "${VOL_LOGS_PATH:?VOL_LOGS_PATH is required in .env}"

VOL_PG="$VOL_POSTGRESQL_PATH"
VOL_SOLR="$VOL_SOLR_PATH"
VOL_ASSET="$VOL_ASSETSTORE_PATH"
VOL_EXPORT="$VOL_EXPORTS_PATH"
VOL_LOGS="$VOL_LOGS_PATH"

# --- 3) UID/GID mapping (overrideable via .env) ---
# Порада: якщо у вас кастомні образи/UID, просто перевизначте у .env:
#   POSTGRES_UID=999
#   POSTGRES_GID=999
#   SOLR_UID=8983
#   SOLR_GID=8983
#   DSPACE_UID=1000
#   DSPACE_GID=1000
POSTGRES_UID="${POSTGRES_UID:-999}"
POSTGRES_GID="${POSTGRES_GID:-999}"
SOLR_UID="${SOLR_UID:-8983}"
SOLR_GID="${SOLR_GID:-8983}"
DSPACE_UID="${DSPACE_UID:-1000}"
DSPACE_GID="${DSPACE_GID:-1000}"

# --- 4) Create directories (needs sudo for /srv) ---
echo "==> Creating volume directories..."
for p in "$VOL_PG" "$VOL_SOLR" "$VOL_ASSET" "$VOL_EXPORT" "$VOL_LOGS"; do
  sudo mkdir -p "$p"
done

# --- 5) Set ownership + baseline permissions ---
echo "==> Setting ownership + baseline permissions..."

# PostgreSQL: найсуворіше
# - каталог PGDATA: 700
# - файли всередині: 600 (але лише якщо --fix-existing)
# - директорії всередині: 700 (але лише якщо --fix-existing)

echo " -> PostgreSQL PGDATA (${POSTGRES_UID}:${POSTGRES_GID})"
sudo chown -R "${POSTGRES_UID}:${POSTGRES_GID}" "$VOL_PG"
sudo chmod 700 "$VOL_PG"

# Solr: можна 775 (читання для групи, якщо зручно для адміністрування)
# Якщо хочете суворіше — ставте 750.
echo " -> Solr (${SOLR_UID}:${SOLR_GID})"
sudo chown -R "${SOLR_UID}:${SOLR_GID}" "$VOL_SOLR"
sudo chmod 775 "$VOL_SOLR"

# DSpace: assetstore/exports/logs
# Логи/експорти часто треба читати адміну — 775 ок. Якщо хочете суворіше — 750.
echo " -> DSpace assets/exports/logs (${DSPACE_UID}:${DSPACE_GID})"
sudo chown -R "${DSPACE_UID}:${DSPACE_GID}" "$VOL_ASSET" "$VOL_EXPORT" "$VOL_LOGS"
sudo chmod 775 "$VOL_ASSET" "$VOL_EXPORT" "$VOL_LOGS"

# --- 6) Optional: fix existing perms (remove 777 etc.) ---
if $FIX_EXISTING; then
  echo "==> --fix-existing enabled: normalizing permissions inside volumes (careful)."

  # PostgreSQL: прибираємо 777, робимо як очікує Postgres
  # Директорії 700, файли 600. Це безпечно для більшості установок.
  echo " -> Fixing PostgreSQL PGDATA modes (dirs=700, files=600)"
  sudo find "$VOL_PG" -type d -exec chmod 700 {} +
  sudo find "$VOL_PG" -type f -exec chmod 600 {} +

  # Solr: dirs 775, files 664 (або 644). Обираємо 664 для групового читання.
  echo " -> Fixing Solr modes (dirs=775, files=664)"
  sudo find "$VOL_SOLR" -type d -exec chmod 775 {} +
  sudo find "$VOL_SOLR" -type f -exec chmod 664 {} +

  # DSpace: dirs 775, files 664
  echo " -> Fixing DSpace modes (dirs=775, files=664)"
  sudo find "$VOL_ASSET" "$VOL_EXPORT" "$VOL_LOGS" -type d -exec chmod 775 {} +
  sudo find "$VOL_ASSET" "$VOL_EXPORT" "$VOL_LOGS" -type f -exec chmod 664 {} +
fi

echo "==> Done! Volumes are ready."
ls -ld "$VOL_PG" "$VOL_SOLR" "$VOL_ASSET" "$VOL_EXPORT" "$VOL_LOGS"
