# CHANGELOG 2026 VOL 01

## Анотація тому

- Контекст: стабілізація production-інфраструктури DSpace 9 (Compose + Traefik + Cloudflare Tunnel).
- Зміст: безпека, CI/CD gates, операційні скрипти, документація архітектури.
- Ключові напрямки: hardening ingress, контроль вразливостей, стандартизація процесу змін.

## [2026-03-04] Діагностика нічного cron-запуску `run-maintenance.sh`

### Знайдено
- Cron entry для `run-maintenance.sh` активний і тригериться щодня о `00:00` (є записи `CRON ... CMD` до `2026-03-04 00:00:01`).
- У `crontab` редірект логів налаштовано на неіснуючий шлях:
`/home/pinokew/Dspace/DSpace-volumes/logs/...`.
- Фактичний каталог логів зараз:
`/srv/DSpace-volumes/logs`.
- Через помилку редіректу (`cannot create ... Directory nonexistent`) shell завершує команду до старту скрипта.
- Історичний `maintenance.log` містить помилку `line 35: ---: command not found` (зафіксовано у запуску від `2026-02-18`), але поточний файл `scripts/run-maintenance.sh` проходить `bash -n` (синтаксично валідний).

### Перевірено
- `git status` (локально змінені лише `.gitignore`, `docker-compose.yml`).
- `docker compose ps` (усі ключові сервіси `Up (healthy)`).
- `crontab -l` (активні nightly/hourly задачі присутні).
- `journalctl -u cron` (щоденні виклики `run-maintenance.sh`, `No MTA installed` після помилки редіректу).
- `bash -n scripts/run-maintenance.sh` (поточний скрипт без синтаксичних помилок).
- Дані логів:
`/srv/DSpace-volumes/logs/maintenance.log` останній успішний запис `2026-02-18 00:00`,
`/home/pinokew/Dspace/DSpace-volumes` відсутній.

## [2026-03-03] Нормалізація архітектурної документації та changelog-індексу

### Додано
- Повністю оновлено `ARCHITECTURE.md` під фактичний стан репозиторію `DSpace-docker`.
- На початок тому додано обов'язкову анотацію (контекст, зміст, ключові напрямки).
- Заповнено `CHANGELOG.md` як короткий індекс томів з позначенням активного.

### Змінено
- Видалено з `ARCHITECTURE.md` шаблонний контент іншого проєкту (Koha).
- Формалізовано в документації модель роботи з томами changelog (soft/hard ліміти, формат іменування).

### Перевірено
- `git status` перед змінами.
- `docker compose ps` (усі ключові сервіси стеку в стані `Up (healthy)`).
- Обсяг поточного тому після оновлення залишається значно нижче soft limit.

## [2026-03-03] Оновлення CI/CD workflow за еталоном checks-моделі

### Змінено
- Перебудовано `.github/workflows/ci-cd.yml` у підході, сумісному з `archive/ci-cd-checks.yml` (структура `permissions`, `concurrency`, `env`, розділення `ci-checks`/`cd-deploy`).
- Версії CI-утиліт винесено в `env` з digest-пінами:
`SHELLCHECK_IMAGE`, `TRIVY_IMAGE`.
- CI-утиліти переведено на запуск через Docker Hub images (`docker pull` + `docker run`) замість локальної установки через `apt`.
- Оновлено pin-версії дій у workflow:
`actions/checkout` на commit SHA, `tailscale/github-action@v4`, `appleboy/ssh-action@v1.2.5`.

### Видалено
- Видалено крок `Trivy Image Scan (Critical gate)` з CI-потоку.

### Залишено
- Збережено `Trivy Config Scan (Critical gate)` як обов'язковий security gate.
- Збережено основний CD-контур деплою: patch configs -> `docker compose pull/up` -> `smoke-test.sh`.

### Перевірено
- У workflow відсутній `Trivy Image Scan`.
- Наявні digest-посилання на CI utility images у `env`.
- Конфігурація `Trivy Config Scan (Critical gate)` збережена.

## [2026-02-23] Посилення безпеки + security gates у CI/CD

### Додано
- Додано middleware безпеки Traefik для UI та API маршрутів:
`X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Content-Security-Policy-Report-Only`.
- Додано примусове встановлення forwarded-заголовків на рівні проксі:
`X-Forwarded-Proto=https`, `X-Forwarded-Port=443`.
- Додано `Trivy image` gate у CI для `CRITICAL` знахідок у всіх образах compose.
- Додано керований реєстр винятків Trivy у `.trivyignore.yaml` з полями:
`id`, `expired_at`, `statement`.
- Додано перевірку політики в CI для прострочених винятків Trivy (`expired_at`).
- Додано явну діагностику Trivy по кожному образу в CI:
список проблемних образів + витяг неігнорованих `CVE-*`.
- Додано security-перевірки у `scripts/smoke-test.sh`:
заголовки UI/API, захист від CORS-антипатерну (`ACAO=*` + credentials), стабільний регістронезалежний парсинг заголовків.

### Змінено
- Змінено host-binding Traefik на безпечний локальний дефолт:
`${TRAEFIK_BIND_IP:-127.0.0.1}:${TRAEFIK_ENTRYPOINT_PORT:-8080}:80`.
- Змінено патчинг backend у `scripts/patch-local.cfg.sh`:
встановлюється `server.forward-headers-strategy=framework` для коректної обробки проксі-заголовків.
- Змінено валідацію env у `scripts/verify-env.sh`:
додано вимогу до прав `.env` = `600` (поза CI mock mode).
- Змінено режим Trivy image scan на перевірку лише вразливостей (`--scanners vuln`) для чіткішого gate та швидшого виконання.

### Видалено
- Видалено legacy-файл `.trivyignore` (plain text).
- Мігровано на керований формат `.trivyignore.yaml`.

### Нотатки з безпеки
- CI/CD тепер падає на неігнорованих `CRITICAL` знахідках у конфігах та образах.
- Прийняття ризику стало явним, обмеженим у часі та контрольованим через `.trivyignore.yaml`.
- Security headers тепер автоматично перевіряються під час deploy smoke-тестів.

### Операційний вплив
- Публічна пряма експозиція Traefik більше не є дефолтом.
- Реліз/деплой може блокуватися через:
нові `CRITICAL` CVE, прострочені security-винятки, відсутні обов'язкові заголовки, небезпечну CORS-політику.
