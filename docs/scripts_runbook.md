# Runbook: scripts (DSpace Docker)

## Env-контракти

- CI/CD decrypt flow: shared workflow розшифровує `env.dev.enc` або `env.prod.enc` у тимчасовий файл і передає шлях через `ORCHESTRATOR_ENV_FILE`.
- Autonomous flow: cron/manual скрипти читають `SERVER_ENV` (`dev|prod`) або аргумент `--env dev|prod`, розшифровують `env.<env>.enc` у `/dev/shm` і очищають tmp-файл після завершення.
- Локальний dev fallback на `.env` дозволений тільки для deploy-adjacent скриптів, коли `ORCHESTRATOR_ENV_FILE` не передано.

## Категорія 1а: validation

### `scripts/verify-env.sh`

#### Бізнес-логіка
- Перевіряє, що `env.dev.enc` / `env.prod.enc` розшифровуються через SOPS.
- Порівнює набір ключів із `.env.example`.
- Не створює і не читає plaintext `.env`.

#### Manual execution
```bash
bash scripts/verify-env.sh --env dev
bash scripts/verify-env.sh --env prod
bash scripts/verify-env.sh --all
```

### `scripts/smoke-test.sh`

#### Бізнес-логіка
- Перевіряє UI/API/OAI/security headers/CORS/sitemap.
- Для dry-run готує контекст без мережевих HTTP-викликів.
- Env бере з `ORCHESTRATOR_ENV_FILE`; якщо його немає, визначає середовище через `--env`, `ENVIRONMENT_NAME` або `SERVER_ENV` і розшифровує `env.<env>.enc`.

#### Manual execution
```bash
bash scripts/smoke-test.sh --env dev --dry-run
bash scripts/smoke-test.sh --env dev --modules context,required_checks
```

## Категорія 1б: deploy-adjacent

### `scripts/deploy-orchestrator-swarm.sh`

#### Бізнес-логіка
- Головний Swarm orchestrator для CI/CD.
- Порядок фаз: validation -> deploy-adjacent -> `docker compose config` -> `docker stack deploy` -> post-deploy.
- Запускає `verify-env.sh`, `smoke-test.sh --dry-run`, `init-volumes.sh`, `setup-configs.sh --no-restart`, `bootstrap-admin.sh --no-restart`.
- Якщо backend config змінився або admin створений вперше, виконує `docker service update --force ${STACK_NAME}_dspace`.
- Якщо згенерований stack manifest не змінився, пропускає `docker stack deploy` за checksum у `.orchestrator-state/${STACK_NAME}.stack.sha256`.
- Для примусового redeploy можна передати `ORCHESTRATOR_FORCE_DEPLOY=true`.

#### Manual execution
```bash
ENV_TMP="$(mktemp /dev/shm/dspace-env-XXXXXX)"
chmod 600 "${ENV_TMP}"
sops --decrypt --input-type dotenv --output-type dotenv env.dev.enc > "${ENV_TMP}"

ORCHESTRATOR_MODE=swarm \
ENVIRONMENT_NAME=development \
STACK_NAME=dspace \
ORCHESTRATOR_ENV_FILE="${ENV_TMP}" \
bash scripts/deploy-orchestrator-swarm.sh
```

#### Примусовий redeploy, якщо потрібно оновити live stack попри незмінний manifest:
```bash
ORCHESTRATOR_FORCE_DEPLOY=true \
ORCHESTRATOR_MODE=swarm \
ENVIRONMENT_NAME=development \
STACK_NAME=dspace \
ORCHESTRATOR_ENV_FILE="${ENV_TMP}" \
bash scripts/deploy-orchestrator-swarm.sh

shred -u "${ENV_TMP}" 2>/dev/null || rm -f "${ENV_TMP}"
```

### `scripts/init-volumes.sh`

#### Бізнес-логіка
- Створює bind-mount директорії для PostgreSQL, Solr, assetstore, exports, logs та `BACKUP_LOCAL_DIR`.
- Виставляє ownership/permissions через ephemeral Docker container.
- Для `BACKUP_LOCAL_DIR` виставляє ownership на `BACKUP_UID:BACKUP_GID` з fallback на поточного користувача, який запускає `init-volumes.sh`.
- Ідемпотентний: `mkdir -p`, повторне застосування permissions без дублювання.

#### Manual execution
```bash
ENV_TMP="$(mktemp /dev/shm/dspace-env-XXXXXX)"
chmod 600 "${ENV_TMP}"
sops --decrypt --input-type dotenv --output-type dotenv env.dev.enc > "${ENV_TMP}"
ORCHESTRATOR_ENV_FILE="${ENV_TMP}" bash scripts/init-volumes.sh --dry-run
shred -u "${ENV_TMP}" 2>/dev/null || rm -f "${ENV_TMP}"
```

### `scripts/setup-configs.sh`

#### Бізнес-логіка
- Wrapper для `patch-local.cfg.sh`, `patch-config.yml.sh`, `patch-submission-forms.sh`.
- У CI запускається з `--no-restart`, щоб restart контролював orchestrator.

#### Manual execution
```bash
ORCHESTRATOR_ENV_FILE=/dev/shm/dspace-env bash scripts/setup-configs.sh --no-restart
```

### `scripts/patch-local.cfg.sh`

#### Бізнес-логіка
- Модульно синхронізує `dspace/config/local.cfg`.
- Якщо backend config змінився або виконувався `db_rotation`, може поставити restart flag для orchestrator.

#### Manual execution
```bash
ORCHESTRATOR_ENV_FILE=/dev/shm/dspace-env bash scripts/patch-local.cfg.sh --dry-run --no-restart
ORCHESTRATOR_ENV_FILE=/dev/shm/dspace-env bash scripts/patch-local.cfg.sh --list-modules
```

### `scripts/patch-config.yml.sh`

#### Бізнес-логіка
- Модульно генерує `ui-config/config.yml` для Angular UI.
- Підтримує `--dry-run`, `--modules`, `--no-restart`.

#### Manual execution
```bash
ORCHESTRATOR_ENV_FILE=/dev/shm/dspace-env bash scripts/patch-config.yml.sh --dry-run --no-restart
ORCHESTRATOR_ENV_FILE=/dev/shm/dspace-env bash scripts/patch-config.yml.sh --list-modules
```

### `scripts/patch-submission-forms.sh`

#### Бізнес-логіка
- Забезпечує `dspace/config/submission-forms.xml`.
- Додає українську мову до `common_iso_languages`, якщо її ще немає.
- Ставить backend restart flag, якщо файл створено або змінено.

#### Manual execution
```bash
ORCHESTRATOR_ENV_FILE=/dev/shm/dspace-env bash scripts/patch-submission-forms.sh
```

### `scripts/bootstrap-admin.sh`

#### Бізнес-логіка
- Post-deploy hook для створення DSpace admin.
- Swarm-aware: знаходить running task контейнер сервісу `${STACK_NAME}_dspace`.
- Ідемпотентний: якщо admin email уже існує, завершується без змін.
- Ставить admin-created flag тільки після фактичного створення нового admin.

#### Manual execution
```bash
ORCHESTRATOR_ENV_FILE=/dev/shm/dspace-env STACK_NAME=dspace bash scripts/bootstrap-admin.sh --no-restart
```

## Категорія 2: autonomous

### `scripts/lib/autonomous-env.sh`

#### Бізнес-логіка
- Спільний helper для cron/manual скриптів.
- Визначає env через `SERVER_ENV` або `--env dev|prod`.
- Розшифровує `env.<env>.enc` у `/dev/shm`, завантажує dotenv без shell-виконання значень і очищає tmp-файл.

#### Manual execution
```bash
bash -lc 'source scripts/lib/autonomous-env.sh; load_autonomous_env "$PWD" dev; echo "$DSPACE_HOSTNAME"'
```

### `scripts/backup-dspace.sh`

#### Бізнес-логіка
- Створює SQL dump, metadata cloud archive з checksum та full local archive з assetstore.
- Архівує encrypted `env.<env>.enc`, а не plaintext `.env`.
- Завантажує cloud archive/checksum через `rclone` і перевіряє upload через `rclone check`.
- Синхронізує локальне дзеркало assetstore через `rsync`, зберігаючи видалені файли в `assetstore-deleted/${DATE}`.
- Зберігає metadata archives/checksums локально в `BACKUP_LOCAL_DIR` і чистить `full_local_*`, локальні `cloud_metadata_*` та `assetstore-deleted/*` за окремими retention-змінними.
- Публікує textfile metrics `dspace_backup_*` у `NODE_EXPORTER_TEXTFILE_DIR`; `--dry-run` не оновлює freshness-метрики.
- Очікує, що `BACKUP_LOCAL_DIR` підготовлено через `scripts/init-volumes.sh`; backup-скрипт має fallback-ініціалізацію, але cron-сценарій не повинен залежати від passwordless sudo.

#### Manual execution
```bash
bash scripts/backup-dspace.sh --env dev --dry-run
bash scripts/backup-dspace.sh --env prod --dry-run
SERVER_ENV=dev bash scripts/backup-dspace.sh
SERVER_ENV=prod bash scripts/backup-dspace.sh
```

### `scripts/test-restore.sh`

#### Бізнес-логіка
- Smoke restore: бере найновіший `cloud_metadata_*.tar.gz` або `full_local_*.tar.gz` з `BACKUP_LOCAL_DIR`, якщо archive path не передано.
- Розпаковує SQL dump у тимчасовий каталог і імпортує його в тимчасовий PostgreSQL container.
- Перевіряє, що після імпорту є таблиці, і публікує textfile metrics `dspace_restore_smoke_*`.
- `--dry-run` не запускає контейнер і не оновлює freshness-метрики.

#### Manual execution
```bash
SERVER_ENV=prod bash scripts/test-restore.sh
bash scripts/test-restore.sh --env prod /data/backup/dspace/cloud_metadata_YYYY-MM-DD_HH-MM.tar.gz
bash scripts/test-restore.sh --env prod --dry-run
```

### `scripts/restore-backup.sh`

#### Бізнес-логіка
- Disaster recovery restore: зупиняє stack, очищає PostgreSQL/Solr/assetstore, відновлює DB/files і запускає reindex.
- Руйнівний сценарій із подвійним ручним підтвердженням.
- Міняє тільки env-loading контракт; restore-логіка лишається окремо контрольованою.

#### Manual execution
```bash
bash scripts/restore-backup.sh --help
sudo SERVER_ENV=prod bash scripts/restore-backup.sh /srv/backups/full_local_YYYY-MM-DD_HH-MM.tar.gz
sudo bash scripts/restore-backup.sh --env prod /srv/backups/full_local_YYYY-MM-DD_HH-MM.tar.gz
```

### `scripts/run-maintenance.sh`

#### Бізнес-логіка
- Запускає DSpace maintenance: `filter-media`, `index-discovery`, `oai import`.
- Після maintenance розмонтовує GoogleDrive/SMB, завершує `rclone` і виконує `sudo poweroff`.
- Призначений для cron/manual сценаріїв.

#### Manual execution
```bash
SERVER_ENV=dev bash scripts/run-maintenance.sh
bash scripts/run-maintenance.sh --env prod
```

### `scripts/sync-user-groups.sh`

#### Бізнес-логіка
- Синхронізує користувачів із доменом `OIDC_DOMAIN` у DSpace group `OIDC_LOGIN_GROUP_UUID`.
- SQL має `NOT EXISTS`, тому повторний запуск не дублює зв'язки.

#### Manual execution
```bash
SERVER_ENV=dev bash scripts/sync-user-groups.sh
bash scripts/sync-user-groups.sh --env prod
```

## Runtime/out-of-scope

### `scripts/dspace-start.sh`

#### Бізнес-логіка
- Runtime command backend-контейнера.
- Мапить secret/env aliases, чекає DB з timeout, запускає `dspace database migrate`, потім REST API.
- Міграції DSpace ідемпотентні; за потреби можна вимкнути через `DSPACE_SKIP_DB_MIGRATIONS=true`.

#### Manual execution
```bash
docker exec -it <dspace-container> /opt/dspace/scripts/dspace-start.sh
```

### `scripts/entrypoint.sh`

#### Бізнес-логіка
- Docker ENTRYPOINT: експортує файли з `/run/secrets/*` як env-змінні та виконує команду контейнера.

#### Manual execution
```bash
docker run --rm <image> /opt/dspace/scripts/entrypoint.sh env
```

### `scripts/deploy-orchestrator.sh`

#### Бізнес-логіка
- Legacy compose orchestrator.
- Нові CI/CD інтеграції йдуть через `deploy-orchestrator-swarm.sh`.

#### Manual execution
```bash
bash scripts/deploy-orchestrator.sh
```

### `scripts/validate_sops_encrypted.py`

#### Бізнес-логіка
- Guard script для перевірки, що env-файли справді SOPS-encrypted.

#### Manual execution
```bash
python3 scripts/validate_sops_encrypted.py env.dev.enc env.prod.enc
```
