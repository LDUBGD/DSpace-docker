## ✅ Runbook DR (Disaster Recovery) — DSpace 9 (KDV) — чеклист для чергового адміна

### 0) Коли застосовувати

* Репозитарій не працює (500/502), база пошкоджена, Solr “мертвий”, або потрібно **DR-тест** на тест-стенді.
* **НЕ запускати на проді**, якщо немає чіткого рішення керівника/відповідального (операція руйнівна).

---

## 1) Перед стартом (5 хв)

1. **Переконайся що це тест-стенд** або погоджено аварійне відновлення на проді.
2. Визнач файл бекапу:

```bash
ls -lh /home/pinokew/Dspace/backups/*.tar.gz | tail -n 5
```

3. Переконайся що є місце на диску (бекап + тимчасова розпаковка):

```bash
df -h
```

4. Перевір SSOT-шляхи томів у `.env`:

```bash
cd /home/pinokew/Dspace/DSpace-docker
grep -E '^(VOL_POSTGRESQL_PATH|VOL_SOLR_PATH|VOL_ASSETSTORE_PATH|VOL_LOGS_PATH)=' .env
```

---

## 2) “Crash simulation” (для DR-тесту) — без видалення

> Робити тільки на тест-середовищі.

1. Зупинити stack:

```bash
cd /home/pinokew/Dspace/DSpace-docker
docker compose --env-file .env down
```

2. Перейменувати дані (імітація втрати):

```bash
sudo mv /srv/DSpace-volumes/postgresql_data /srv/DSpace-volumes/postgresql_data.BROKEN_$(date +%F_%H%M%S)
sudo mv /srv/DSpace-volumes/assetstore      /srv/DSpace-volumes/assetstore.BROKEN_$(date +%F_%H%M%S)
sudo mv /srv/DSpace-volumes/solr_data       /srv/DSpace-volumes/solr_data.BROKEN_$(date +%F_%H%M%S)
```

---

## 3) Відновлення з бекапу (основна процедура)

1. Запустити restore (увага: **він видаляє поточні дані у volumes**, тому Crash simulation вище — опційно):

```bash
cd /home/pinokew/Dspace/DSpace-docker
sudo ./scripts/restore-backup.sh /home/pinokew/Dspace/backups/<backup_file>.tar.gz
```

2. Якщо скрипт успішний — він сам:

* зупиняє контейнери,
* чистить PG/Solr/assetstore (якщо є в архіві),
* відновлює SQL,
* копіює assetstore,
* піднімає stack,
* робить `index-discovery -b`,
* (опційно) `oai import`.

---

## 4) Верифікація (обов’язково після restore)

### 4.1 Перевірити контейнери

```bash
cd /home/pinokew/Dspace/DSpace-docker
docker compose ps
```

Очікування: `dspacedb`, `dspacesolr`, `dspace`, `dspace-angular`, `traefik` — Running/Healthy.

### 4.2 Перевірити API

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://repo.fby.com.ua/server/api/core/sites
```

Очікування: `200`.

### 4.3 Перевірити UI

Відкрити в браузері:

* `https://repo.fby.com.ua/` (головна)
* відкрити 1–2 записи
* відкрити 1–2 PDF (перевірка assetstore)

### 4.4 Перевірити пошук (Solr discovery)

* у UI зробити пошук за словом з відомого запису
* результат має знаходити записи

### 4.5 Перевірити OAI-PMH

* Identify:

  * `https://repo.fby.com.ua/server/oai/request?verb=Identify`
* ListRecords:

  * `https://repo.fby.com.ua/server/oai/request?verb=ListRecords&metadataPrefix=oai_dc`

---

## 5) Де дивитись логи відновлення

Restore-лог записується у папку логів (зазвичай `VOL_LOGS_PATH`), файл типу:

* `dr-restore_YYYY-MM-DD_HHMMSS.log`

Швидкий пошук останнього:

```bash
ls -lt /srv/DSpace-volumes/logs/dr-restore_*.log | head
```

---

## 6) Типові інциденти та швидкі дії

### A) Stack піднявся, але пошук порожній

Запусти переіндексацію вручну:

```bash
cd /home/pinokew/Dspace/DSpace-docker
docker compose --env-file .env exec -T dspace /dspace/bin/dspace index-discovery -b
```

### B) OAI не показує записи після restore

```bash
cd /home/pinokew/Dspace/DSpace-docker
docker compose --env-file .env exec -T dspace /dspace/bin/dspace oai import
```

### C) UI відкривається, але API 502/500

Перевір статус backend:

```bash
docker logs --tail=200 dspace
```

---

## 7) Definition of Done (DR-Test пройдено)

* Restore завершився без помилок.
* API `/server/api/core/sites` дає `200`.
* UI відкривається, PDF відкриваються.
* Пошук працює.
* OAI Identify/ListRecords працює.
* Є лог `dr-restore_*.log` + коротка відмітка “DR-Test OK” у внутрішньому журналі/нотатках.
