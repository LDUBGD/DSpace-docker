#!/usr/bin/env bash
set -euo pipefail

[[ -f "example.env" && ! -f ".env" ]] && cp example.env .env || true

mkdir -p dspace/config
touch dspace/config/local.cfg

[[ -f "./scripts/verify-env.sh" ]] && bash ./scripts/verify-env.sh --ci-mock
[[ -f "./scripts/patch-local.cfg.sh" ]] && bash ./scripts/patch-local.cfg.sh
[[ -f "./scripts/patch-config.yml.sh" ]] && bash ./scripts/patch-config.yml.sh
[[ -f "./scripts/init-volumes.sh" ]] && bash ./scripts/init-volumes.sh
[[ -f "./scripts/smoke-test.sh" ]] && bash ./scripts/smoke-test.sh

echo "Orchestration script completed"
