#!/usr/bin/env bash

AUTONOMOUS_ENV_TMP=""
AUTONOMOUS_ENVIRONMENT=""

autonomous_env_log() {
  printf '[autonomous-env] %s\n' "$*"
}

autonomous_env_die() {
  autonomous_env_log "ERROR: $*" >&2
  exit 1
}

cleanup_autonomous_env() {
  if [[ -n "${AUTONOMOUS_ENV_TMP:-}" && -f "${AUTONOMOUS_ENV_TMP}" ]]; then
    if command -v shred >/dev/null 2>&1; then
      shred -u "${AUTONOMOUS_ENV_TMP}" 2>/dev/null || rm -f "${AUTONOMOUS_ENV_TMP}"
    else
      rm -f "${AUTONOMOUS_ENV_TMP}"
    fi
  fi
}

resolve_autonomous_age_key_file() {
  local candidates=()
  local sudo_home=""
  local candidate

  if [[ -n "${SOPS_AGE_KEY_FILE:-}" ]]; then
    [[ -f "${SOPS_AGE_KEY_FILE}" ]] || autonomous_env_die "SOPS_AGE_KEY_FILE is set but file was not found: ${SOPS_AGE_KEY_FILE}"
    printf '%s\n' "${SOPS_AGE_KEY_FILE}"
    return 0
  fi

  if [[ -n "${HOME:-}" ]]; then
    candidates+=("${HOME}/.config/sops/age/keys.txt")
    candidates+=("${HOME}/.config/age/keys.txt")
  fi

  if [[ "$(id -u)" == "0" && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    sudo_home="$(getent passwd "${SUDO_USER}" 2>/dev/null | cut -d: -f6 || true)"
    sudo_home="${sudo_home:-/home/${SUDO_USER}}"
    candidates+=("${sudo_home}/.config/sops/age/keys.txt")
    candidates+=("${sudo_home}/.config/age/keys.txt")
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

has_autonomous_sops_identity_env() {
  [[ -n "${SOPS_AGE_KEY:-}" \
    || -n "${SOPS_AGE_KEY_CMD:-}" \
    || -n "${SOPS_AGE_SSH_PRIVATE_KEY_FILE:-}" \
    || -n "${SOPS_AGE_SSH_PRIVATE_KEY_CMD:-}" ]]
}

resolve_autonomous_environment() {
  local raw="${1:-${SERVER_ENV:-}}"
  case "${raw}" in
    dev|development) printf 'dev' ;;
    prod|production) printf 'prod' ;;
    "") autonomous_env_die "environment is not set. Set SERVER_ENV or pass dev|prod." ;;
    *) autonomous_env_die "unsupported environment: ${raw}. Expected dev|development|prod|production." ;;
  esac
}

decrypt_autonomous_env() {
  local enc_file="$1"
  local age_key_file=""

  command -v sops >/dev/null 2>&1 || autonomous_env_die "sops is required"
  [[ -f "${enc_file}" ]] || autonomous_env_die "encrypted env file not found: ${enc_file}"

  AUTONOMOUS_ENV_TMP="$(mktemp /dev/shm/env-XXXXXX)"
  chmod 600 "${AUTONOMOUS_ENV_TMP}"

  if age_key_file="$(resolve_autonomous_age_key_file)"; then
    autonomous_env_log "Using SOPS age key file: ${age_key_file}"
    SOPS_AGE_KEY_FILE="${age_key_file}" sops --decrypt --input-type dotenv --output-type dotenv "${enc_file}" > "${AUTONOMOUS_ENV_TMP}"
    return 0
  fi

  if has_autonomous_sops_identity_env; then
    sops --decrypt --input-type dotenv --output-type dotenv "${enc_file}" > "${AUTONOMOUS_ENV_TMP}"
    return 0
  fi

  autonomous_env_die "AGE key file not found. Set SOPS_AGE_KEY_FILE or place keys.txt in ~/.config/sops/age/keys.txt. Under sudo, the script also checks the invoking user's home from SUDO_USER."
}

load_autonomous_env() {
  local project_root="$1"
  local environment_arg="${2:-}"
  local enc_file

  AUTONOMOUS_ENVIRONMENT="$(resolve_autonomous_environment "${environment_arg}")"
  enc_file="${project_root}/env.${AUTONOMOUS_ENVIRONMENT}.enc"

  trap cleanup_autonomous_env EXIT
  decrypt_autonomous_env "${enc_file}"

  autonomous_env_log "Loading env.${AUTONOMOUS_ENVIRONMENT}.enc from /dev/shm"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue

    line="$(printf '%s' "${line}" | sed -E 's/^[[:space:]]*export[[:space:]]+//')"
    [[ "${line}" == *"="* ]] || continue

    local key="${line%%=*}"
    local value="${line#*=}"

    key="$(printf '%s' "${key}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    value="$(printf '%s' "${value}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [[ "${value}" =~ ^\".*\"$ ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value}" =~ ^\'.*\'$ ]]; then
      value="${value:1:${#value}-2}"
    fi

    printf -v "${key}" '%s' "${value}"
    export "${key?}"
  done < "${AUTONOMOUS_ENV_TMP}"
}
