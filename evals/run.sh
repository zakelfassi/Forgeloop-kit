#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

scenarios=(
  "tests/daemon-entrypoint-layouts.test.sh"
  "evals/scenarios/daemon-paused-flag.sh"
  "tests/failure-escalation.test.sh"
  "evals/scenarios/repeated-failure-state.sh"
  "tests/runtime-state-model.test.sh"
  "tests/daemon-blocker-escalation.test.sh"
  "tests/llm-auth-failover.test.sh"
)

for scenario in "${scenarios[@]}"; do
    echo "==> $scenario"
    bash "$ROOT_DIR/$scenario"
done
