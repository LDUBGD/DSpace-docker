#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE="${ORCHESTRATOR_MODE:-noop}"
STACK_NAME="${STACK_NAME:-dspace}"
ENV_FILE="${ORCHESTRATOR_ENV_FILE:-/tmp/env.decrypted}"
BACKEND_RESTART_FLAG_FILE=""
ADMIN_CREATED_FLAG_FILE=""
DEPLOY_STATE_DIR="${ORCHESTRATOR_STATE_DIR:-${PROJECT_ROOT}/.orchestrator-state}"
DEPLOY_MANIFEST_HASH=""
DEPLOY_MANIFEST_HASH_FILE=""

log() {
  printf '[deploy-orchestrator] %s\n' "$*"
}

detect_compose_file() {
  if [[ -f "docker-compose.yaml" ]]; then
    echo "docker-compose.yaml"
  elif [[ -f "docker-compose.yml" ]]; then
    echo "docker-compose.yml"
  else
    echo ""
  fi
}

run_validation_scripts() {
  local environment verify_script smoke_script

  environment="${ENVIRONMENT_NAME:-${SERVER_ENV:-}}"
  verify_script="${SCRIPT_DIR}/verify-env.sh"
  smoke_script="${SCRIPT_DIR}/smoke-test.sh"

  if [[ -x "${verify_script}" ]]; then
    log "Running env validation: ${verify_script}"
    "${verify_script}" --env "${environment}"
  elif [[ -f "${verify_script}" ]]; then
    log "Running env validation via bash: ${verify_script}"
    bash "${verify_script}" --env "${environment}"
  else
    log "ERROR: validation script not found: ${verify_script}"
    exit 1
  fi

  if [[ -x "${smoke_script}" ]]; then
    log "Running smoke-test preflight dry-run: ${smoke_script}"
    ORCHESTRATOR_ENV_FILE="${ENV_FILE}" "${smoke_script}" --env "${environment}" --dry-run
  elif [[ -f "${smoke_script}" ]]; then
    log "Running smoke-test preflight dry-run via bash: ${smoke_script}"
    ORCHESTRATOR_ENV_FILE="${ENV_FILE}" bash "${smoke_script}" --env "${environment}" --dry-run
  else
    log "ERROR: smoke-test script not found: ${smoke_script}"
    exit 1
  fi
}

run_deploy_adjacent_scripts() {
  local init_volumes_script setup_configs_script

  init_volumes_script="${SCRIPT_DIR}/init-volumes.sh"
  setup_configs_script="${SCRIPT_DIR}/setup-configs.sh"

  if [[ -x "${init_volumes_script}" ]]; then
    log "Running deploy-adjacent script: ${init_volumes_script}"
    ORCHESTRATOR_ENV_FILE="${ENV_FILE}" "${init_volumes_script}"
  elif [[ -f "${init_volumes_script}" ]]; then
    log "Running deploy-adjacent script via bash: ${init_volumes_script}"
    ORCHESTRATOR_ENV_FILE="${ENV_FILE}" bash "${init_volumes_script}"
  else
    log "ERROR: deploy-adjacent script not found: ${init_volumes_script}"
    exit 1
  fi

  if [[ -x "${setup_configs_script}" ]]; then
    log "Running deploy-adjacent script: ${setup_configs_script}"
    ORCHESTRATOR_ENV_FILE="${ENV_FILE}" \
      DSPACE_BACKEND_RESTART_FLAG_FILE="${BACKEND_RESTART_FLAG_FILE}" \
      "${setup_configs_script}" --no-restart
  elif [[ -f "${setup_configs_script}" ]]; then
    log "Running deploy-adjacent script via bash: ${setup_configs_script}"
    ORCHESTRATOR_ENV_FILE="${ENV_FILE}" \
      DSPACE_BACKEND_RESTART_FLAG_FILE="${BACKEND_RESTART_FLAG_FILE}" \
      bash "${setup_configs_script}" --no-restart
  else
    log "ERROR: deploy-adjacent script not found: ${setup_configs_script}"
    exit 1
  fi
}

runtime_env_has_key() {
  local env_file="$1"
  local expected_key="$2"
  local line key

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue

    line="$(printf '%s' "${line}" | sed -E 's/^[[:space:]]*export[[:space:]]+//')"
    [[ "${line}" == *"="* ]] || continue

    key="${line%%=*}"
    key="$(printf '%s' "${key}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    if [[ "${key}" == "${expected_key}" ]]; then
      return 0
    fi
  done < "${env_file}"

  return 1
}

validate_runtime_env_file() {
  local required_keys=(
    VOL_POSTGRESQL_PATH
    VOL_SOLR_PATH
    VOL_ASSETSTORE_PATH
    VOL_EXPORTS_PATH
    VOL_LOGS_PATH
  )
  local missing=()
  local key

  if [[ ! -s "${ENV_FILE}" ]]; then
    log "ERROR: runtime env file is missing or empty: ${ENV_FILE}"
    exit 1
  fi

  for key in "${required_keys[@]}"; do
    if ! runtime_env_has_key "${ENV_FILE}" "${key}"; then
      missing+=("${key}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    log "ERROR: runtime env file ${ENV_FILE} is missing required deploy key(s): ${missing[*]}"
    log "HINT: check the GitHub environment selected by ENVIRONMENT_NAME=${ENVIRONMENT_NAME:-unset}, SOPS decrypt step, and DEPLOY_PROJECT_DIR/repo checkout."
    exit 1
  fi
}

run_post_deploy_scripts() {
  local bootstrap_admin_script

  bootstrap_admin_script="${SCRIPT_DIR}/bootstrap-admin.sh"

  if [[ -x "${bootstrap_admin_script}" ]]; then
    log "Running post-deploy script: ${bootstrap_admin_script}"
    ORCHESTRATOR_ENV_FILE="${ENV_FILE}" \
      STACK_NAME="${STACK_NAME}" \
      DSPACE_ADMIN_CREATED_FLAG_FILE="${ADMIN_CREATED_FLAG_FILE}" \
      "${bootstrap_admin_script}" --no-restart
  elif [[ -f "${bootstrap_admin_script}" ]]; then
    log "Running post-deploy script via bash: ${bootstrap_admin_script}"
    ORCHESTRATOR_ENV_FILE="${ENV_FILE}" \
      STACK_NAME="${STACK_NAME}" \
      DSPACE_ADMIN_CREATED_FLAG_FILE="${ADMIN_CREATED_FLAG_FILE}" \
      bash "${bootstrap_admin_script}" --no-restart
  else
    log "Post-deploy script not found: ${bootstrap_admin_script}; skipping"
  fi
}

restart_backend_if_required() {
  local backend_service="${STACK_NAME}_dspace"
  local reasons=()

  if [[ -s "${BACKEND_RESTART_FLAG_FILE}" ]]; then
    reasons+=("config changes: $(sort -u "${BACKEND_RESTART_FLAG_FILE}" | paste -sd ',' -)")
  fi
  if [[ -s "${ADMIN_CREATED_FLAG_FILE}" ]]; then
    reasons+=("admin created")
  fi

  if [[ "${#reasons[@]}" -eq 0 ]]; then
    log "Backend restart not required"
    return 0
  fi

  log "Restarting backend service ${backend_service} (${reasons[*]})"
  docker service update --force "${backend_service}"
}

prepare_deploy_state() {
  mkdir -p "${DEPLOY_STATE_DIR}"
  DEPLOY_MANIFEST_HASH_FILE="${DEPLOY_STATE_DIR}/${STACK_NAME}.stack.sha256"
}

stack_deploy_required() {
  local deploy_manifest="$1"
  local previous_hash=""

  DEPLOY_MANIFEST_HASH="$(sha256sum "${deploy_manifest}" | awk '{print $1}')"

  if [[ "${ORCHESTRATOR_FORCE_DEPLOY:-false}" == "true" ]]; then
    log "ORCHESTRATOR_FORCE_DEPLOY=true; stack deploy will run"
    return 0
  fi

  if [[ -f "${DEPLOY_MANIFEST_HASH_FILE}" ]]; then
    previous_hash="$(cat "${DEPLOY_MANIFEST_HASH_FILE}")"
  fi

  if [[ "${previous_hash}" == "${DEPLOY_MANIFEST_HASH}" ]]; then
    log "Stack manifest unchanged (${DEPLOY_MANIFEST_HASH}); skipping docker stack deploy"
    return 1
  fi

  log "Stack manifest changed or no previous checksum; docker stack deploy required"
  return 0
}

record_stack_deploy_hash() {
  printf '%s\n' "${DEPLOY_MANIFEST_HASH}" > "${DEPLOY_MANIFEST_HASH_FILE}"
}

run_ansible_secrets_if_configured() {
  local infra_repo_path environment inventory_env inventory_path playbook_path

  infra_repo_path="${INFRA_REPO_PATH:-}"
  environment="${ENVIRONMENT_NAME:-}"

  if [[ -z "${infra_repo_path}" ]]; then
    log "INFRA_REPO_PATH is not set; skip ansible secrets refresh"
    return 0
  fi

  if [[ ! -d "${infra_repo_path}" ]]; then
    log "ERROR: INFRA_REPO_PATH does not exist: ${infra_repo_path}"
    exit 1
  fi

  if ! command -v ansible-playbook >/dev/null 2>&1; then
    log "ERROR: ansible-playbook not found on host"
    exit 1
  fi

  case "${environment}" in
    development|dev)
      inventory_env="dev"
      ;;
    production|prod)
      inventory_env="prod"
      ;;
    *)
      log "ERROR: unsupported ENVIRONMENT_NAME=${environment} (expected: development|production)"
      exit 1
      ;;
  esac

  inventory_path="${infra_repo_path}/ansible/inventories/${inventory_env}/hosts.yml"
  playbook_path="${infra_repo_path}/ansible/playbooks/swarm.yml"

  if [[ ! -f "${inventory_path}" ]]; then
    log "ERROR: inventory file not found: ${inventory_path}"
    exit 1
  fi
  if [[ ! -f "${playbook_path}" ]]; then
    log "ERROR: playbook file not found: ${playbook_path}"
    exit 1
  fi

  log "Refreshing Swarm secrets via Ansible (inventory=${inventory_env})"
  ANSIBLE_CONFIG="${infra_repo_path}/ansible/ansible.cfg" \
    ansible-playbook \
    -i "${inventory_path}" \
    "${playbook_path}" \
    --tags secrets
}

run_versioned_env_secret_renderer() {
  local render_script

  render_script="${SCRIPT_DIR}/render-versioned-env-secret.sh"

  if [[ -x "${render_script}" ]]; then
    log "Rendering versioned Swarm env secrets: ${render_script}"
    ORCHESTRATOR_ENV_FILE="${ENV_FILE}" "${render_script}" --write-env-file "${ENV_FILE}" >/dev/null
  elif [[ -f "${render_script}" ]]; then
    log "Rendering versioned Swarm env secrets via bash: ${render_script}"
    ORCHESTRATOR_ENV_FILE="${ENV_FILE}" bash "${render_script}" --write-env-file "${ENV_FILE}" >/dev/null
  else
    log "ERROR: versioned env secret renderer not found: ${render_script}"
    exit 1
  fi
}

deploy_swarm() {
  local compose_file swarm_file raw_manifest deploy_manifest

  compose_file="$(detect_compose_file)"
  swarm_file="docker-compose.swarm.yml"
  raw_manifest="$(mktemp "/tmp/${STACK_NAME}.stack.raw.XXXXXX.yml")"
  deploy_manifest="$(mktemp "/tmp/${STACK_NAME}.stack.deploy.XXXXXX.yml")"
  BACKEND_RESTART_FLAG_FILE="$(mktemp "${PROJECT_ROOT}/.${STACK_NAME}.backend-restart.XXXXXX.flag")"
  ADMIN_CREATED_FLAG_FILE="$(mktemp "${PROJECT_ROOT}/.${STACK_NAME}.admin-created.XXXXXX.flag")"
  rm -f "${BACKEND_RESTART_FLAG_FILE}" "${ADMIN_CREATED_FLAG_FILE}"
  trap 'rm -f "${raw_manifest:-}" "${deploy_manifest:-}" "${BACKEND_RESTART_FLAG_FILE:-}" "${ADMIN_CREATED_FLAG_FILE:-}"' EXIT

  if [[ -z "${compose_file}" ]]; then
    log "ERROR: compose file not found (expected docker-compose.yaml|yml)"
    exit 1
  fi
  if [[ ! -f "${swarm_file}" ]]; then
    log "ERROR: ${swarm_file} not found"
    exit 1
  fi

  if [[ ! -f "${ENV_FILE}" ]]; then
    if [[ -f ".env" ]]; then
      ENV_FILE=".env"
      log "WARNING: env.*.enc не знайдено або ORCHESTRATOR_ENV_FILE не передано. Fallback на локальний .env — тільки для dev-середовища."
    else
      log "ERROR: env file not found (${ORCHESTRATOR_ENV_FILE:-/tmp/env.decrypted}) and .env missing"
      exit 1
    fi
  fi

  prepare_deploy_state
  validate_runtime_env_file
  run_ansible_secrets_if_configured
  run_versioned_env_secret_renderer
  run_validation_scripts
  run_deploy_adjacent_scripts

  log "Rendering Swarm manifest (stack=${STACK_NAME}, env_file=${ENV_FILE})"
  docker compose --env-file "${ENV_FILE}" \
    -f "${compose_file}" \
    -f "${swarm_file}" \
    config > "${raw_manifest}"

  awk 'NR==1 && $1=="name:" {next} {print}' "${raw_manifest}" > "${deploy_manifest}"

  if stack_deploy_required "${deploy_manifest}"; then
    log "Deploying stack ${STACK_NAME}"
    docker stack deploy -c "${deploy_manifest}" "${STACK_NAME}"
    record_stack_deploy_hash
  fi

  run_post_deploy_scripts
  restart_backend_if_required

  log "Swarm deploy completed"
}

cd "${PROJECT_ROOT}"

case "${MODE}" in
  noop)
    log "No-op mode. Set ORCHESTRATOR_MODE=swarm to enable Phase 8 Swarm deploy path."
    ;;
  swarm)
    deploy_swarm
    ;;
  *)
    log "ERROR: unknown ORCHESTRATOR_MODE=${MODE}. Supported: noop, swarm"
    exit 1
    ;;
esac
