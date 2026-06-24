## 2026-04-26 — Category 2 autonomous scripts switched to Swarm runtime

### Контекст
- Автономні скрипти Категорії 2 мали працювати поза CI/CD через `SERVER_ENV`/SOPS і production Swarm runtime, а не напряму через compose або hardcoded container names.

### Оновлено
- `scripts/lib/docker-runtime.sh`
- `scripts/backup-dspace.sh`
- `scripts/restore-backup.sh`
- `scripts/run-maintenance.sh`
- `scripts/sync-user-groups.sh`

### Зміни
- Додано runtime helper з default `DOCKER_RUNTIME_MODE=swarm`, `STACK_NAME=dspace` і compose fallback для локального dev.
- `backup-dspace.sh` виконує DB dump через `docker_runtime_exec dspacedb`; додано `--dry-run` без dump/upload/archive.
- `restore-backup.sh` підтримує `--dry-run` без confirmation prompts і моделює Swarm scale/restore/reindex кроки без зміни даних.
- `run-maintenance.sh` виконує DSpace CLI через Swarm service `dspace`; `--dry-run` не виконує CLI, unmount, killall або poweroff.
- `sync-user-groups.sh` виконує SQL через Swarm service `dspacedb`; `--dry-run` друкує SQL без mutation.

### Перевірено
- `bash -n` і `shellcheck` для змінених DSpace скриптів — OK.
- `backup-dspace.sh --env dev --dry-run` — OK.
- `run-maintenance.sh --env dev --dry-run` — OK, poweroff не виконувався.
- `sync-user-groups.sh --env dev --dry-run` — OK, SQL mutation не виконувалась.
- `restore-backup.sh --env dev --dry-run <tmp-test-archive>` — OK, destructive кроки тільки надруковані.
- Read-only Swarm DB check: `docker_runtime_exec dspacedb pg_isready` — OK.

## 2026-04-30 — Backup refactor iteration 1: metadata module extraction

### Зроблено
- Виправлено parsing bug у `scripts/backup-dspace.sh`: `ENVIRONMENT_ARG` тепер ініціалізується порожнім значенням перед argument loop.
- Винесено metadata-частину backup flow (`DB dump -> cloud archive -> rclone upload/check -> full local archive`) у `scripts/lib/backup-metadata.sh`.
- Додано каркасні файли для наступних ітерацій:
  - `scripts/lib/backup-assetstore.sh`;
  - `scripts/lib/backup-cleanup.sh`.
- Cleanup у `backup-dspace.sh` тепер також прибирає локальний `${ARCHIVE_CLOUD}.sha256`, який створює metadata-модуль.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK, реальні dump/upload/archive не виконувались.

### Data/impact
- Реальні backup/restore/destructive операції не запускались.
- `env.dev.enc` і `env.prod.enc` у цій ітерації не змінювались.

## 2026-04-30 — Backup refactor iteration 2: `.env.example` contract placeholders

### Зроблено
- У кінець `.env.example` додано блок `BACKUP REFACTORING SETTINGS` з новими змінними:
  - `BACKUP_RETENTION_META_LOCAL`;
  - `BACKUP_RETENTION_META_CLOUD`;
  - `BACKUP_RETENTION_DELETED`;
  - `BACKUP_ASSETSTORE_MIRROR`.

### Перевірено
- `tail -n 30 .env.example` підтвердив, що блок додано саме в кінець файлу.

### Data/impact
- `env.dev.enc` і `env.prod.enc` не змінювались; значення буде перенесено вручну окремо.

## 2026-04-30 — Backup refactor iteration 3: assetstore mirror module

### Зроблено
- Реалізовано `scripts/lib/backup-assetstore.sh`.
- `scripts/backup-dspace.sh` підключає assetstore-модуль і викликає `backup_assetstore` після metadata backup та перед поточним cleanup.
- Assetstore mirror використовує `rsync --archive --checksum --delete --backup` з `--backup-dir="${BACKUP_DIR}/assetstore-deleted/${DATE}"`.
- Якщо `VOL_ASSETSTORE_PATH` відсутній, mirror-крок завершується warning-ом без падіння.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK, rsync/mutation кроки не виконувались.

### Data/impact
- Реальний `rsync`, backup upload або видалення файлів не виконувались.
- `env.dev.enc` містить нові backup-змінні; `env.prod.enc` у цій ітерації не змінювався.

## 2026-04-30 — Backup refactor iteration 4: cleanup module and retention split

### Зроблено
- Реалізовано `scripts/lib/backup-cleanup.sh`.
- `scripts/backup-dspace.sh` підключає cleanup-модуль і викликає `backup_cleanup` після metadata та assetstore-кроків.
- Retention розділено на:
  - `BACKUP_RETENTION_META_LOCAL` для `full_local_*.tar.gz`;
  - `BACKUP_RETENTION_META_CLOUD` для cloud metadata/checksum через `rclone delete`;
  - `BACKUP_RETENTION_DELETED` для `assetstore-deleted/*`.
- Для `BACKUP_RETENTION_META_LOCAL` збережено fallback на deprecated `BACKUP_RETENTION_DAYS`.
- Cloud cleanup обмежено include-фільтрами `cloud_metadata_*.tar.gz` і `cloud_metadata_*.tar.gz.sha256`.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK; cleanup показав retention `local=30d`, `cloud=90d`, `deleted-assets=180d`.

### Data/impact
- Реальні backup/upload/rsync/delete операції не виконувались.
- `env.prod.enc` у цій ітерації не змінювався.

## 2026-04-30 — Backup refactor iteration 5: prerequisites and partial cleanup hardening

### Зроблено
- У `scripts/backup-dspace.sh` додано `check_prerequisites` перед orchestration.
- Перевіряються required tools: `rclone`, `rsync`, `sha256sum`.
- У `--dry-run` відсутні tools логуються як warning, без fail.
- Додано попередження, якщо у filesystem для `BACKUP_DIR` менше 10 GB вільного місця.
- Додано `ERR` trap із безпечним partial cleanup для `SQL_DUMP`, `ARCHIVE_CLOUD`, `${ARCHIVE_CLOUD}.sha256`, `ARCHIVE_LOCAL`.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK.

### Data/impact
- Реальні backup/upload/rsync/delete операції не виконувались.

## 2026-04-30 — Backup refactor iteration 6: prod env contract validation

### Зроблено
- Після додавання backup-змінних у `env.prod.enc` увімкнено hard check для `BACKUP_ASSETSTORE_MIRROR` у `scripts/backup-dspace.sh`.
- Перевірено, що `env.dev.enc`, `env.prod.enc` і `.env.example` містять новий backup contract:
  - `BACKUP_RETENTION_META_LOCAL`;
  - `BACKUP_RETENTION_META_CLOUD`;
  - `BACKUP_RETENTION_DELETED`;
  - `BACKUP_ASSETSTORE_MIRROR`.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK.
- `bash scripts/backup-dspace.sh --env prod --dry-run` — OK.

### Data/impact
- Реальні backup/upload/rsync/delete операції не виконувались.
- `env.prod.enc` був оновлений вручну поза агентом; агент лише перевірив наявність потрібних ключів і dry-run поведінку.

## 2026-04-30 — Backup refactor iteration 7: absolute `BACKUP_LOCAL_DIR`

### Зроблено
- `scripts/backup-dspace.sh` тепер нормалізує `BACKUP_LOCAL_DIR` у завжди абсолютний `BACKUP_DIR`.
- Якщо `BACKUP_LOCAL_DIR` absolute, він використовується як є; якщо relative, прив'язується до `PROJECT_ROOT`.
- У `--dry-run` скрипт більше не створює backup-dir і не пише `backup_log.txt`, щоб dry-run для absolute prod paths не вимагав прав на `/data`.
- `.env.example` оновлено: `BACKUP_LOCAL_DIR=/data/backup/dspace`.
- `docs/backup-dspace-refactoring.md` синхронізовано з новою path setup логікою.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK.
- `bash scripts/backup-dspace.sh --env prod --dry-run` — OK; backup paths мають вигляд `/data/backup/dspace/...`.

### Data/impact
- Реальні backup/upload/rsync/delete операції не виконувались.
- У `/opt/Dspace/backups` виявлено наявний старий backup archive, тому каталог не очищався.

## 2026-04-30 — Scripts runbook sync після backup refactor

### Зроблено
- Оновлено секцію `scripts/backup-dspace.sh` у `docs/scripts_runbook.md`:
  - уточнено checksum/rclone check;
  - додано assetstore rsync mirror;
  - описано розділений retention;
  - оновлено manual execution приклади з `--env dev|prod --dry-run` та `SERVER_ENV`.

### Перевірено
- Переглянуто diff документації.

## 2026-04-30 — Backup directory initialization hardening

### Зроблено
- У `scripts/backup-dspace.sh` додано ідемпотентний helper `init_backup_dir`.
- Реальний запуск створює `BACKUP_DIR` з правами `0750`.
- Якщо поточний користувач не може створити системний каталог напряму, скрипт пробує `sudo -n install -d -m 0750 -o <uid> -g <gid>`.
- Для запуску через `sudo` ownership виставляється на `SUDO_UID:SUDO_GID`, щоб подальші запуски від cron-користувача могли писати в каталог.
- `docs/scripts_runbook.md` доповнено приміткою про автоматичну ініціалізацію backup-директорії.
- Примітка: наступною ітерацією основну підготовку `BACKUP_LOCAL_DIR` перенесено в `scripts/init-volumes.sh`, щоб cron backup не залежав від passwordless sudo.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK.
- `bash scripts/backup-dspace.sh --env prod --dry-run` — OK.

### Data/impact
- Реальні backup/upload/rsync/delete операції не виконувались.

## 2026-04-30 — Init volumes керує `BACKUP_LOCAL_DIR`

### Зроблено
- `scripts/init-volumes.sh` тепер вимагає `BACKUP_LOCAL_DIR` разом з іншими volume path variables.
- `BACKUP_LOCAL_DIR` додано до існуючого ідемпотентного create loop через `ensure_dir`.
- Для backup-директорії додано baseline ownership/permissions:
  - owner: `BACKUP_UID:BACKUP_GID`;
  - fallback: UID/GID поточного користувача, який запускає `init-volumes.sh`;
  - mode: `750`.
- Для `--fix-existing` додано нормалізацію backup-директорії: dirs `750`, files `640`.
- `docs/scripts_runbook.md` оновлено: cron backup має покладатися на `init-volumes.sh` для підготовки `BACKUP_LOCAL_DIR`, а не на passwordless sudo в backup-скрипті.

### Перевірено
- `bash -n scripts/init-volumes.sh` — OK.
- `shellcheck scripts/init-volumes.sh` — OK.
- `ORCHESTRATOR_ENV_FILE=.env.example bash scripts/init-volumes.sh --dry-run` — OK; dry-run показав створення `/data/backup/dspace` і permissions `1000:1000`, mode `750`.

### Data/impact
- Реальні директорії/permissions не змінювались у перевірці, бо запуск був у `--dry-run`.

## 2026-04-30 — Backup rclone verification/filter fix

### Контекст
- Під час реального `bash scripts/backup-dspace.sh --env dev` upload проходив, але `rclone check` падав із `is a file not a directory`, бо remote file path передавався як rclone filesystem root.
- Cloud cleanup показував warning про одночасне використання `--include` і `--exclude`.

### Зроблено
- У `scripts/lib/backup-metadata.sh` `rclone check` переведено на перевірку local directory проти remote directory з filter-ами на конкретні archive/checksum файли:
  - `cloud_metadata_<DATE>.tar.gz`;
  - `cloud_metadata_<DATE>.tar.gz.sha256`.
- У `scripts/lib/backup-cleanup.sh` cloud cleanup переведено з `--include/--exclude` на ordered `--filter` правила.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK; dry-run показав новий `rclone check <local-dir> <remote-dir> --one-way --filter ...`.

### Data/impact
- Реальні backup/upload/rsync/delete операції в цій перевірці не виконувались.

## 2026-04-30 — Local metadata archive retention

### Зроблено
- `scripts/lib/backup-cleanup.sh` більше не видаляє локальний `cloud_metadata_<DATE>.tar.gz` і `.sha256` одразу після upload.
- Локальні metadata archives/checksums тепер зберігаються в `BACKUP_LOCAL_DIR`.
- Для `cloud_metadata_*.tar.gz` і `cloud_metadata_*.tar.gz.sha256` додано cleanup за `BACKUP_RETENTION_META_LOCAL`.
- `.env.example`, `docs/scripts_runbook.md` і `docs/backup-dspace-refactoring.md` синхронізовано з новою поведінкою.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK; dry-run показав `Keeping local metadata archive` і retention cleanup для `cloud_metadata_*`.

### Data/impact
- Реальні backup/upload/rsync/delete операції в цій перевірці не виконувались.

## 2026-04-30 — Split full-local and metadata-local retention

### Зроблено
- Додано окрему env-змінну `BACKUP_RETENTION_FULL_LOCAL` для локальних `full_local_*.tar.gz`.
- `BACKUP_RETENTION_META_LOCAL` тепер керує тільки локальними `cloud_metadata_*.tar.gz` і `.sha256`.
- Deprecated `BACKUP_RETENTION_DAYS` лишено fallback-ом тільки для `BACKUP_RETENTION_FULL_LOCAL`.
- Оновлено `.env.example`, `docs/scripts_runbook.md` і `docs/backup-dspace-refactoring.md`.

### Перевірено
- `bash -n scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `shellcheck scripts/backup-dspace.sh scripts/lib/backup-metadata.sh scripts/lib/backup-assetstore.sh scripts/lib/backup-cleanup.sh` — OK.
- `bash scripts/backup-dspace.sh --env dev --dry-run` — OK; summary показав `full-local=30d | meta-local=30d | meta-cloud=90d | deleted-assets=180d`.

### Data/impact
- Реальні backup/upload/rsync/delete операції в цій перевірці не виконувались.
- `env.dev.enc` і `env.prod.enc` потрібно доповнити `BACKUP_RETENTION_FULL_LOCAL`, якщо потрібне значення відмінне від fallback `BACKUP_RETENTION_DAYS`/`30`.

## 2026-04-30 — Deploy setup-configs no-chmod hardening

### Контекст
- GitHub Actions deploy через `ansible_usr` падав у `scripts/setup-configs.sh` на `chmod +x scripts/patch-local.cfg.sh` з `Operation not permitted`.
- Причина: `ansible_usr` може мати право читати/виконувати файли через group/ACL, але не бути власником файлів; `chmod` вимагає ownership або root.

### Зроблено
- Прибрано обов'язковий `chmod +x` для patch-скриптів із `scripts/setup-configs.sh`.
- Додано helper запуску patch-скриптів: executable файли запускаються напряму, non-executable файли — через `bash`.

### Перевірено
- `bash -n scripts/setup-configs.sh scripts/deploy-orchestrator-swarm.sh scripts/patch-local.cfg.sh scripts/patch-config.yml.sh scripts/patch-submission-forms.sh` — OK.
- `shellcheck scripts/setup-configs.sh scripts/deploy-orchestrator-swarm.sh scripts/patch-local.cfg.sh scripts/patch-config.yml.sh scripts/patch-submission-forms.sh` — OK.
- `bash scripts/setup-configs.sh --help` — OK.

## 2026-05-07 — Versioned Swarm env secrets renderer

### Зроблено
- Додано `scripts/render-versioned-env-secret.sh` за Koha-патерном immutable Docker secrets із hash suffix.
- Renderer створює:
  - `DSPACE_POSTGRES_PASSWORD_SECRET_NAME` з hash значення `POSTGRES_PASSWORD`;
  - `DSPACE_APP_ENV_PAYLOAD_SECRET_NAME` з hash runtime env payload без generated `*_SECRET_NAME`.
- `scripts/deploy-orchestrator-swarm.sh` тепер викликає renderer перед `docker compose config`, щоб Swarm manifest отримував актуальні versioned secret names.
- `.env.example` доповнено generated secret contract із placeholder hash-назвами та secret base variables.

### Перевірено
- `bash -n scripts/render-versioned-env-secret.sh scripts/deploy-orchestrator-swarm.sh` — OK.
- `shellcheck scripts/render-versioned-env-secret.sh scripts/deploy-orchestrator-swarm.sh` — OK.
- Renderer перевірено з mock `docker secret`: `POSTGRES_PASSWORD=change_me` зрендерив `dspace_postgres_password_fb86fb757d12`, payload secret отримав hash suffix, обидві назви записались у test env file.
- `docker compose --env-file <test-env> -f docker-compose.yml -f docker-compose.swarm.yml config` — OK; manifest підставив versioned names для `app_env_payload` і `postgres_password`.

### Data/impact
- Реальні Docker secrets не створювались під час тесту; використовувався mock `docker`.
- Реальні `env.dev.enc` і `env.prod.enc` не змінювались.

## 2026-05-08 — DSpace backup/restore textfile metrics and smoke restore

### Зроблено
- `scripts/backup-dspace.sh` тепер публікує `dspace_backup_*` textfile metrics у `NODE_EXPORTER_TEXTFILE_DIR`.
- `--dry-run` для backup не оновлює freshness-метрики, щоб не маскувати відсутність реального backup.
- Додано `scripts/test-restore.sh`: smoke restore імпортує SQL dump із найновішого backup archive у тимчасовий PostgreSQL container і публікує `dspace_restore_smoke_*`.
- `.env.example` доповнено `NODE_EXPORTER_TEXTFILE_DIR`, `BACKUP_METRICS_FILE`, `RESTORE_SMOKE_METRICS_FILE`.
- `docs/scripts_runbook.md` оновлено manual execution для backup metrics і smoke restore.

### Перевірено
- `SERVER_ENV=prod bash scripts/backup-dspace.sh` успішно створив `cloud_metadata_2026-05-08_21-22.tar.gz`, `full_local_2026-05-08_21-22.tar.gz`, виконав rclone upload/check і записав `dspace_backup.prom`.
- `SERVER_ENV=prod bash scripts/test-restore.sh` успішно імпортував SQL у тимчасовий PostgreSQL container; sanity check показав `63` таблиці і записав `dspace_restore_smoke.prom`.
- Node exporter читає `dspace_backup_*` і `dspace_restore_smoke_*` зі status `1`.
- VictoriaMetrics бачить обидві success-метрики з labels `job="node-exporter"`, `service="host"`, `exported_service="dspace"`.

### Data/impact
- Реальний backup/upload і restore smoke test виконано в prod-контексті, але restore smoke використовував тільки тимчасовий PostgreSQL container і не змінював production DSpace DB.

