#!/bin/bash
set -e

# Paths
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT="$SCRIPT_DIR/.."

# --- 1. Load .env (Robust Mode) ---
ENV_FILE="$SCRIPT_DIR/../.env"

if [ -f "$ENV_FILE" ]; then
    echo "🌍 Loading environment variables..."
    # Читаємо файл порядково, щоб уникнути проблем з пробілами без лапок
    while IFS='=' read -r key value; do
        # Пропускаємо коментарі та порожні рядки (хоча grep їх вже відфільтрував, перестрахуємось)
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        
        # Видаляємо можливі пробіли на початку/кінці значення
        # та прибираємо лапки, якщо вони є (щоб не було подвійних)
        value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")

        # Експортуємо змінну
        export "$key=$value"
    done < <(grep -vE '^\s*#' "$ENV_FILE" | grep -vE '^\s*$')
else
    echo "❌ Error: .env file not found."
    exit 1
fi

# 2. Перевірка критичних змінних
# Якщо ці змінні не задані в .env, скрипт зупиниться
: "${VOL_ASSETSTORE_PATH:?Variable VOL_ASSETSTORE_PATH not set in .env}"
: "${BACKUP_RCLONE_REMOTE:?Variable BACKUP_RCLONE_REMOTE not set in .env}"
: "${DB_SERVICE_NAME:?Variable DB_SERVICE_NAME not set in .env}"

# 3. Налаштування шляхів
BACKUP_DIR="${PROJECT_ROOT}/${BACKUP_LOCAL_DIR:-backups}" 
DATE=$(date +%Y-%m-%d_%H-%M)
LOG_FILE="${BACKUP_DIR}/backup_log.txt"

# Створення папки бекапів
mkdir -p "$BACKUP_DIR"

# Імена файлів
SQL_DUMP="${BACKUP_DIR}/dspace_db_${DATE}.sql"
ARCHIVE_CLOUD="${BACKUP_DIR}/cloud_metadata_${DATE}.tar.gz"  # Тільки база + конфіги
ARCHIVE_LOCAL="${BACKUP_DIR}/full_local_${DATE}.tar.gz"      # Все + файли книг

# Функція для логування
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "=== Starting Backup Routine ==="

# --- КРОК 1: ДАМП БАЗИ ДАНИХ ---
log "[1/5] Dumping Database from service: $DB_SERVICE_NAME..."

# Використовуємо docker compose exec, щоб не шукати ID контейнера вручну
# -T вимикає TTY, щоб не було помилок у cron/scripts
if docker compose -f "$PROJECT_ROOT/docker-compose.yml" exec -T "$DB_SERVICE_NAME" \
    pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" > "$SQL_DUMP"; then
    log "Database dumped successfully."
else
    log "ERROR: Database dump failed!"
    rm -f "$SQL_DUMP"
    exit 1
fi

# --- КРОК 2: АРХІВ ДЛЯ ХМАРИ (Metadata Only) ---
log "[2/5] Creating Cloud Archive (DB + Configs + Env)..."

# Архівуємо SQL, папку конфігів (відносно кореня) та .env
if tar -czf "$ARCHIVE_CLOUD" \
    -C "$BACKUP_DIR" "$(basename "$SQL_DUMP")" \
    -C "$PROJECT_ROOT" .env \
    -C "$PROJECT_ROOT" dspace/config; then
    log "Cloud archive created: $(basename "$ARCHIVE_CLOUD")"
else
    log "ERROR: Cloud archiving failed!"
    exit 1
fi

# --- КРОК 3: ЗАВАНТАЖЕННЯ НА GOOGLE DRIVE ---
log "[3/5] Uploading to Google Drive ($BACKUP_RCLONE_REMOTE)..."

if rclone copy "$ARCHIVE_CLOUD" "${BACKUP_RCLONE_REMOTE}:${BACKUP_RCLONE_FOLDER}"; then
    log "Upload SUCCESS."
else
    log "ERROR: Upload FAILED. Check internet or rclone config."
    # Не виходимо, бо треба зробити локальний повний бекап
fi

# --- КРОК 4: ЛОКАЛЬНИЙ ПОВНИЙ БЕКАП (З Assetstore) ---
log "[4/5] Creating Full Local Archive (incl. Assetstore)..."

# Тут ми використовуємо твою змінну VOL_ASSETSTORE_PATH з .env
if [ -d "$VOL_ASSETSTORE_PATH" ]; then
    # dirname/basename магія потрібна, щоб tar не зберігав повний абсолютний шлях (/home/user/...)
    tar -czf "$ARCHIVE_LOCAL" \
        -C "$BACKUP_DIR" "$(basename "$SQL_DUMP")" \
        -C "$PROJECT_ROOT" .env \
        -C "$PROJECT_ROOT" dspace/config \
        -C "$(dirname "$VOL_ASSETSTORE_PATH")" "$(basename "$VOL_ASSETSTORE_PATH")"
    
    log "Full Local archive created: $(basename "$ARCHIVE_LOCAL")"
else
    log "WARNING: Assetstore path ($VOL_ASSETSTORE_PATH) not found! Skipping assetstore backup."
fi

# --- КРОК 5: ОЧИЩЕННЯ ---
log "[5/5] Cleanup..."

# Видаляємо "сирий" SQL (він вже в архівах)
rm -f "$SQL_DUMP"

# Видаляємо "хмарний" архів з диска (щоб не дублювати місце, бо у нас є повний)
rm -f "$ARCHIVE_CLOUD"

# Видаляємо старі локальні архіви (старше N днів з .env)
RETENTION=${BACKUP_RETENTION_DAYS:-7}
find "$BACKUP_DIR" -name "full_local_*.tar.gz" -mtime +$RETENTION -exec rm {} \;
log "Old backups (older than $RETENTION days) removed."

log "=== Backup Finished ==="
