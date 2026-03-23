#!/usr/bin/env bash
# Скрипт для створення адміністратора в DSpace 7+ через CLI
# Використовує змінні з .env для налаштування даних адміністратора

set -euo pipefail

# --- helpers ---
info() { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load env (only local file, never commit it)
if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ROOT_DIR}/.env"
  set +a
fi

: "${DSPACE_CONTAINER_NAME:=dspace}"
: "${DSPACE_BOOTSTRAP_ADMIN_EMAIL:?Set DSPACE_BOOTSTRAP_ADMIN_EMAIL in .env}"
: "${DSPACE_BOOTSTRAP_ADMIN_FIRSTNAME:?Set DSPACE_BOOTSTRAP_ADMIN_FIRSTNAME in .env}"
: "${DSPACE_BOOTSTRAP_ADMIN_LASTNAME:?Set DSPACE_BOOTSTRAP_ADMIN_LASTNAME in .env}"
: "${DSPACE_BOOTSTRAP_ADMIN_PASSWORD:?Set DSPACE_BOOTSTRAP_ADMIN_PASSWORD in .env}"
: "${DSPACE_BOOTSTRAP_ADMIN_LOCALE:=en}"

EMAIL="${DSPACE_BOOTSTRAP_ADMIN_EMAIL}"
FNAME="${DSPACE_BOOTSTRAP_ADMIN_FIRSTNAME}"
LNAME="${DSPACE_BOOTSTRAP_ADMIN_LASTNAME}"
PASS="${DSPACE_BOOTSTRAP_ADMIN_PASSWORD}"
LOCALE="${DSPACE_BOOTSTRAP_ADMIN_LOCALE}"

info "Checking DSpace backend container exists & is running: ${DSPACE_CONTAINER_NAME}"
docker inspect "${DSPACE_CONTAINER_NAME}" >/dev/null 2>&1 || fail "Container '${DSPACE_CONTAINER_NAME}' not found"
RUNNING="$(docker inspect -f '{{.State.Running}}' "${DSPACE_CONTAINER_NAME}")"
[[ "${RUNNING}" == "true" ]] || fail "Container '${DSPACE_CONTAINER_NAME}' is not running"

info "Checking DSpace CLI is available in container..."
docker exec "${DSPACE_CONTAINER_NAME}" bash -lc "test -x /dspace/bin/dspace" \
  || fail "/dspace/bin/dspace not found or not executable"

info "Checking whether admin user already exists: ${EMAIL}"
if docker exec "${DSPACE_CONTAINER_NAME}" bash -lc "/dspace/bin/dspace user -L 2>/dev/null | grep -Fq '${EMAIL}'"; then
  info "Admin already exists. Nothing to do."
  exit 0
fi

info "Admin not found. Creating administrator: ${EMAIL}"

# Non-interactive create-admin (works even without a TTY)
docker exec "${DSPACE_CONTAINER_NAME}" bash -lc \
  "/dspace/bin/dspace create-administrator \
    -e '${EMAIL}' \
    -f '${FNAME}' \
    -l '${LNAME}' \
    -p '${PASS}' \
    -c '${LOCALE}'"

info "Done. Try login in"
