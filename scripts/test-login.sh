#!/usr/bin/env bash
# Скрипт для тестування логіну через OIDC (Keycloak) до DSpace 7+
# Використовує токен з куки, щоб обійти CSRF захист
# Важливо: цей скрипт НЕ тестує сам Keycloak, а лише перевіряє, чи працює логін на стороні DSpace (Backend).
# Якщо цей скрипт працює, але логін через браузер ні - проблема в браузері або в його взаємодії з Nginx (можливо, через проксі або CORS).

# URL сайту (Nginx)
BASE_URL="http://localhost:8081"
# Кренденшали
USER="admin@edu.ua"
PASS="admin"

echo "1. Отримуємо CSRF токен (через Cookie jar)..."
# -c cookies.txt: записувати куки
# -b cookies.txt: читати куки (якщо є)
curl -c cookies.txt -b cookies.txt -s -I "${BASE_URL}/server/api/authn/status" > /dev/null

# DSpace віддає токен у куці з назвою "DSPACE-XSRF-COOKIE"
# Формат у файлі cookies.txt (Netscape format):
# domain  flag  path  secure  expiration  name  value
TOKEN=$(grep "DSPACE-XSRF-COOKIE" cookies.txt | awk '{print $7}')

if [ -z "$TOKEN" ]; then
  echo "ПОМИЛКА: Не вдалося знайти DSPACE-XSRF-COOKIE у файлі cookies.txt."
  echo "Вміст cookies.txt:"
  cat cookies.txt
  echo "Перевір, чи працює Backend і чи віддає він куки."
  exit 1
fi

echo "Токен отримано з Cookie: $TOKEN"

echo "2. Спробуємо увійти..."
# Важливо: передаємо токен у заголовку X-XSRF-TOKEN
RESPONSE=$(curl -v -X POST "${BASE_URL}/server/api/authn/login" \
  -c cookies.txt -b cookies.txt \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "X-XSRF-TOKEN: $TOKEN" \
  -d "user=$USER&password=$PASS" 2>&1)

# Перевіряємо результат
if echo "$RESPONSE" | grep -q "Authorization: Bearer"; then
  echo ""
  echo "✅ УСПІХ! Логін пройшов. Сервер видав Bearer токен."
  echo "Висновок: Backend працює ідеально. Проблема може бути в браузері."
else
  echo ""
  echo "❌ НЕВДАЧА. Логін не пройшов."
  echo "Останні рядки відповіді:"
  echo "$RESPONSE" | tail -n 20
  echo "Висновок: Проблема на сервері."
fi

# rm cookies.txt