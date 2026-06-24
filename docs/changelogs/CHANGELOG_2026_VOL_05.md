## 2026-05-11 — Assetstore orphan cleanup wrapper

### Зроблено
- Додано `scripts/cleanup-assetstore-orphans.sh` для запуску штатного DSpace cleanup через `/dspace/bin/dspace cleanup --verbose`.
- Скрипт використовує існуючий autonomous env-loading (`--env dev|prod` / `SERVER_ENV`) і Swarm-aware runtime helper `scripts/lib/docker-runtime.sh`.
- Додано `--dry-run`, який друкує команду без змін в assetstore.
- `docs/scripts_runbook.md` доповнено manual execution для cleanup-скрипта.

### Перевірено
- `bash -n scripts/cleanup-assetstore-orphans.sh` — OK.
- `shellcheck scripts/cleanup-assetstore-orphans.sh` — OK.
- `bash scripts/cleanup-assetstore-orphans.sh --env prod --dry-run` — OK, mutation не виконувалась.
- `bash scripts/cleanup-assetstore-orphans.sh --env prod` — OK; DSpace cleanup завершився без крешів, знайдено `0` deleted bitstream.

### Data/impact
- Реальний cleanup виконано в prod-контексті штатною командою DSpace; orphan/deleted bitstreams для видалення не знайдено.
