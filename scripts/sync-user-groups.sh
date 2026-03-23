#!/bin/bash
# Скрипт для синхронізації користувачів з OIDC групи в DSpace
# Використовує UUID групи з .env та додає користувачів, які мають email з певним доменом, до цієї групи в базі даних DSpace. 
# Додай рядок, щоб запускати скрипт, наприклад, кожні 10 хвилин (або щогодини):
# crontab -e
# */10 * * * * /home/pinokew/Dspace/DSpace-docker/scripts/sync-user-groups.sh >> /var/log/dspace-sync.log 2>&1  

set -e

# --- Load Environment ---
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ENV_FILE="$SCRIPT_DIR/../.env"

if [ -f "$ENV_FILE" ]; then
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        # Clean value from quotes and spaces
        value=$(echo "$value" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
        export "$key=$value"
    done < <(grep -vE '^\s*#' "$ENV_FILE" | grep -vE '^\s*$')
fi

# --- Configuration ---
GROUP_UUID="${OIDC_LOGIN_GROUP_UUID}"
DOMAIN_SUFFIX="${OIDC_DOMAIN}"

DB_CONTAINER="dspacedb"
DB_USER="${POSTGRES_USER:-dspace}"
DB_NAME="${POSTGRES_DB:-dspace}"
DB_PASSWORD="${POSTGRES_PASSWORD:-dspace}"

# --- Validation ---
if [ -z "$GROUP_UUID" ] || [ -z "$DOMAIN_SUFFIX" ]; then
    echo "❌ Error: OIDC_LOGIN_GROUP_UUID or OIDC_DOMAIN is missing in .env"
    exit 1
fi

TARGET_DOMAIN="@${DOMAIN_SUFFIX}"

echo "🔄 Starting Group Sync..."
echo "   Target Group UUID: $GROUP_UUID"
echo "   Target Domain:     $TARGET_DOMAIN"

# --- SQL Logic (FIXED) ---
# Видалено колонку 'id' та 'gen_random_uuid()',
# оскільки в DSpace 7+ таблиці зв'язків не мають окремого ID.

SQL_QUERY="
INSERT INTO epersongroup2eperson (eperson_group_id, eperson_id)
SELECT 
    '$GROUP_UUID',     -- ID групи
    e.uuid             -- ID користувача
FROM eperson e
WHERE e.email LIKE '%$TARGET_DOMAIN'
  AND NOT EXISTS (
      -- Перевіряємо дублікати
      SELECT 1 FROM epersongroup2eperson link 
      WHERE link.eperson_group_id = '$GROUP_UUID' 
      AND link.eperson_id = e.uuid
  );
"

# --- Execution ---
# Використовуємо Pipe метод для передачі пароля та запиту
echo "$SQL_QUERY" | docker exec -i -e PGPASSWORD="$DB_PASSWORD" "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -w > /tmp/sync_output.txt 2>&1

OUTPUT=$(cat /tmp/sync_output.txt)
rm /tmp/sync_output.txt

# --- Parsing Result ---
# Шукаємо рядок INSERT 0 X
INSERT_LINE=$(echo "$OUTPUT" | grep -o "INSERT 0 [0-9]*" || true)

if [ -n "$INSERT_LINE" ]; then
    COUNT=$(echo "$INSERT_LINE" | awk '{print $3}')
    echo "✅ Sync completed successfully."
    echo "   Users added: ${COUNT:-0}"
else
    echo "⚠️  Sync FAILED or SQL Error:"
    echo "---------------------------------------------------"
    echo "$OUTPUT"
    echo "---------------------------------------------------"
fi