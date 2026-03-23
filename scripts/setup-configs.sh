#!/bin/bash
set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

echo "🚀 Starting KDV DSpace Configuration Setup..."
echo "---------------------------------------------"

# Даємо права на виконання (про всяк випадок)
chmod +x "$SCRIPT_DIR/patch-local.cfg.sh"
chmod +x "$SCRIPT_DIR/patch-config.yml.sh"
chmod +x "$SCRIPT_DIR/patch-submission-forms.sh"

# Запускаємо скрипти по черзі
"$SCRIPT_DIR/patch-local.cfg.sh"
"$SCRIPT_DIR/patch-config.yml.sh"
"$SCRIPT_DIR/patch-submission-forms.sh"

echo "---------------------------------------------"
echo "🎉 All configurations updated from .env!"
echo "👉 Now run: docker compose restart"
