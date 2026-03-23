#!/bin/bash
set -e

# --- 1. Load .env (Robust Mode) ---
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
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

TARGET_FILE="$SCRIPT_DIR/../ui-config/config.yml"
mkdir -p "$(dirname "$TARGET_FILE")"

echo "🔧 Patching Frontend (config.yml)..."

# --- 2. Parse Public REST URL ---
# Нам треба розібрати DSPACE_REST_BASEURL (напр. https://repo.fby.com.ua/server)
# щоб правильно налаштувати браузер клієнта.

URL="${DSPACE_REST_BASEURL:-http://localhost:8081/server}"

# 1. Витягуємо протокол
if [[ "$URL" == https* ]]; then
    REST_SSL="true"
    DEFAULT_PORT="443"
else
    REST_SSL="false"
    DEFAULT_PORT="80"
fi

# 2. Прибираємо протокол (http:// або https://)
URL_NO_PROTO=$(echo "$URL" | sed -E 's|^\w+://||')

# 3. Витягуємо хост:порт (все до першого слеша)
HOST_PORT=$(echo "$URL_NO_PROTO" | cut -d/ -f1)

# 4. Витягуємо Namespace (все після першого слеша)
REST_NAMESPACE="/$(echo "$URL_NO_PROTO" | cut -d/ -f2-)"
# Якщо namespace пустий (корінь), ставимо /
if [[ "$REST_NAMESPACE" == "/" ]]; then REST_NAMESPACE="/"; fi

# 5. Розділяємо Хост і Порт
if [[ "$HOST_PORT" == *":"* ]]; then
    REST_HOST=$(echo "$HOST_PORT" | cut -d: -f1)
    REST_PORT=$(echo "$HOST_PORT" | cut -d: -f2)
else
    REST_HOST="$HOST_PORT"
    REST_PORT="$DEFAULT_PORT"
fi

echo "   Detected REST Config: $REST_HOST:$REST_PORT (SSL: $REST_SSL)"

# --- 3. Generate YAML ---

cat <<EOF > "$TARGET_FILE"
ui:
  # UI (Angular) сервер слухає всередині контейнера завжди по HTTP
  ssl: false
  host: 0.0.0.0
  port: 8081
  nameSpace: /
  # Публічний URL для генерації посилань
  baseUrl: ${DSPACE_UI_BASEURL}
  useProxies: true

rest:
  # Налаштування для БРАУЗЕРА (куди стукати за даними)
  ssl: ${REST_SSL}
  host: ${REST_HOST}
  port: ${REST_PORT}
  nameSpace: ${REST_NAMESPACE}
  ssrBaseUrl: http://dspace:8080/server

themes:
  - name: dspace
    headTags:
      - tagName: link
        attributes:
          rel: icon
          href: assets/dspace/images/favicons/favicon.ico
          sizes: any
      - tagName: link
        attributes:
          rel: icon
          href: assets/dspace/images/favicons/favicon.svg
          type: image/svg+xml
      - tagName: link
        attributes:
          rel: manifest
          href: assets/dspace/images/favicons/manifest.webmanifest

#  Fallback language in which the UI will be rendered if the user's browser language is not an active language
fallbackLanguage: uk

# Languages. DSpace Angular holds a message catalog for each of the following languages.
# When set to active, users will be able to switch to the use of this language in the user interface.
languages:
  - code: uk
    label: Yкраї́нська
    active: true
  - code: en
    label: English
    active: true
  - code: ar
    label: العربية
    active: true
  - code: bn
    label: বাংলা
    active: true
  - code: ca
    label: Català
    active: true
  - code: cs
    label: Čeština
    active: true
  - code: de
    label: Deutsch
    active: true
  - code: el
    label: Ελληνικά
    active: true
  - code: es
    label: Español
    active: true
  - code: fa
    label: فارسی
    active: true
  - code: fi
    label: Suomi
    active: true
  - code: fr
    label: Français
    active: true
  - code: gd
    label: Gàidhlig
    active: true
  - code: gu
    label: ગુજરાતી
    active: true
  - code: hi
    label: हिंदी
    active: true
  - code: hu
    label: Magyar
    active: true
  - code: it
    label: Italiano
    active: true
  - code: kk
    label: Қазақ
    active: true
  - code: lv
    label: Latviešu
    active: true
  - code: mr
    label: मराठी
    active: true
  - code: nl
    label: Nederlands
    active: true
  - code: pl
    label: Polski
    active: true
  - code: pt-PT
    label: Português
    active: true
  - code: pt-BR
    label: Português do Brasil
    active: true
  - code: ru
    label: Русский
    active: false
  - code: sr-lat
    label: Srpski (lat)
    active: true
  - code: sr-cyr
    label: Српски
    active: true
  - code: sv
    label: Svenska
    active: true
  - code: ta
    label: தமிழ்
    active: true
  - code: tr
    label: Türkçe
    active: true
  - code: vi
    label: Tiếng Việt
    active: true

EOF

echo "✅ Frontend configured."