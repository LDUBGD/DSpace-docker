# 📚 DSpace KDV - Інфраструктура та Runbook

Репозиторій інфраструктури для DSpace 9, розгорнутого через Docker Compose з проксуванням через Traefik і Cloudflare Tunnel.

## 1. 🏛 Архітектура системи (Architecture Overview)

### Мережевий потік (Traffic Flow)

`Користувач -> Cloudflare (WAF/CDN) -> Cloudflare Tunnel -> Traefik (127.0.0.1) -> DSpace UI / DSpace REST API`

У поточному стеку cloudflared працює як окремий контейнер `tunnel`, а Traefik за замовчуванням прив’язаний до localhost (`127.0.0.1:${TRAEFIK_ENTRYPOINT_PORT:-8080}`).

### Стек компонентів

- DSpace Backend: Java/Tomcat (`dspace`)
- DSpace Angular UI: Node.js (`dspace-angular`)
- PostgreSQL 15 (`dspacedb`)
- Solr 8 (`dspacesolr`)
- Traefik v3 (`dspace-traefik`)
- Cloudflare Tunnel (`dspace-tunnel`)

### Безпека (Zero Trust модель)

- Немає обов’язкової публічної експозиції DSpace сервісів назовні: вхідний трафік йде через Cloudflare Tunnel.
- SSH-доступ має бути лише через Tailscale VPN, з ключовою автентифікацією (Ed25519).
- На рівні хоста рекомендовано та очікується активний `UFW` і `fail2ban` (перевіряти періодично за аудит-чеклистом).
- У CI/CD діють security gates (Trivy CRITICAL).

### Автентифікація

- OIDC через Microsoft Entra ID (ключі та endpoint-и в `.env`).
- Парольна самореєстрація вимкнена патчем `local.cfg`:
  - `user.registration = false`
  - `user.forgot-password = false`

## 2. 🚀 CI/CD та Розгортання (Deployment Flow)

### Базовий принцип деплою

Адміністратор пушить зміни в `main`:

```bash
git push origin main
```

Усі ручні правки на сервері в робочому дереві репозиторію вважаються забороненими, оскільки CD-процес виконує примусову синхронізацію коду (`git fetch` + `git reset --hard` для `main`).

### Етап CI (перевірки)

Workflow: `.github/workflows/ci-cd.yml`

- Shellcheck для всіх `scripts/*.sh`
- Валідація `docker-compose.yml` (включно з перевіркою unresolved `${...}`)
- Валідація `.env` через `scripts/verify-env.sh --ci-mock`
- Dry-run `scripts/patch-local.cfg.sh`
- Trivy Config Scan (`CRITICAL` gate)
- Trivy Image Scan (`CRITICAL` gate) з урахуванням `.trivyignore.yaml` і контролем `expired_at`

Якщо виявлено неігноровані `CRITICAL` вразливості, деплой блокується.

### Етап CD (деплой)

- GitHub Actions підключається до сервера через Tailscale.
- Далі через SSH виконується:
  1. Перевірка наявності `.env` (SSOT)
  2. `git fetch --prune --tags origin`
  3. `git checkout -f main && git reset --hard origin/main` (для `main`)
  4. `./scripts/patch-local.cfg.sh`
  5. `docker compose pull`
  6. `docker compose up -d --remove-orphans`
  7. `./scripts/smoke-test.sh`

## 3. ⚙️ Конфігурація (Configuration & SSOT)

### `.env` як Single Source of Truth

Файл `.env` є єдиним джерелом правди для:

- URL/hostname
- мережевих параметрів
- секретів OIDC/SMTP/DB
- шляхів до volume (`VOL_*`)
- backup-політик
- GA4 параметрів

### Автогенерація конфігів з `.env`

Скрипт `scripts/patch-local.cfg.sh` автоматично синхронізує `dspace/config/local.cfg`:

- SMTP
- OIDC (Entra ID)
- CORS
- Upload limits
- Proxy/forwarded headers
- GA4
- auth-політики

Додатково:

- `scripts/patch-config.yml.sh` генерує `ui-config/config.yml`
- `scripts/patch-submission-forms.sh` патчить `submission-forms.xml`
- `scripts/setup-configs.sh` запускає патчери пакетно

## 4. 🛠 Щоденне адміністрування (Day-2 Operations)

### Доступ до сервера

1. Увімкнути Tailscale на робочій станції.
2. Підключитися:

```bash
ssh <user>@<tailscale-ip>
```

### Логи

- DSpace і Traefik пишуть у:
  - `/srv/DSpace-volumes/logs/`
- Для docker `json-file` логування обмежене:
  - `max-size: 10m`
  - `max-file: 3`
- Для файлових логів Traefik використовується системний `logrotate` (див. `Traefik-logrotate.md`, конфіг: `/etc/logrotate.d/dspace-traefik`).

Швидкі команди:

```bash
docker compose ps
docker logs --tail=200 dspace
docker logs --tail=200 dspace-traefik
```

### Моніторинг

- Uptime Kuma (окремий сервіс/інстанс)
- Google Analytics 4 (native інтеграція в DSpace, конфігується через `.env` + `patch-local.cfg.sh`)

## 5. 💾 Резервне копіювання (Backups)

### Скрипт `scripts/backup-dspace.sh`

Скрипт робить:

1. SQL dump БД (`pg_dump`)
2. Cloud-архів (SQL + `.env` + `dspace/config`)
3. Завантаження cloud-архіву через `rclone`
4. Повний локальний архів (SQL + конфіги + `assetstore`)
5. Cleanup і retention

### Куди зберігаються бекапи

- Локально: `${BACKUP_LOCAL_DIR}` відносно кореня репозиторію (типово `../backups`, тобто поруч з `DSpace-docker`)
- Повний локальний файл: `full_local_YYYY-MM-DD_HH-MM.tar.gz`
- Лог бекапу: `backup_log.txt` у каталозі backup

Запуск:

```bash
./scripts/backup-dspace.sh
```

## 6. 🆘 Аварійне відновлення (Disaster Recovery Runbook) - КРИТИЧНИЙ РОЗДІЛ

Детальний DR-чеклист знаходиться в корені репозиторію:

- `RunbookDR.md`

Основний автоматизований скрипт відновлення:

- `scripts/restore-backup.sh`

Увага: процедура руйнівна (очищає поточні дані PG/Solr, а за наявності в backup і `assetstore`).

## 7. 🧰 Довідник скриптів (Scripts Directory)

- `init-volumes.sh` — створення volume-директорій та hardening прав доступу.
- `patch-local.cfg.sh` — автоконфігурація `dspace/config/local.cfg` з `.env`.
- `verify-env.sh` — CI/CD-валідатор `.env` проти `example.env`.
- `smoke-test.sh` — перевірка життєздатності UI/API/OAI/security headers після деплою.
- `sync-user-groups.sh` — синхронізація OIDC-користувачів у групи DSpace.

Додатково корисні:

- `backup-dspace.sh` — створення backup-архівів.
- `restore-backup.sh` — DR restore з `.tar.gz`.
- `setup-configs.sh` — пакетний запуск патчерів конфігів.
- `bootstrap-admin.sh` — неінтерактивне створення першого адміністратора.
- `run-maintenance.sh` — регламентні задачі (індексація/OAI тощо).

