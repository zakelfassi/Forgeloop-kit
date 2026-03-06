#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

scenarios=(
  "tests/daemon-entrypoint-layouts.test.sh"
  "tests/failure-escalation.test.sh"
  "tests/runtime-state-model.test.sh"
  "tests/daemon-blocker-escalation.test.sh"
  "tests/install-upgrade.test.sh"
)

for scenario in "${scenarios[@]}"; do
    bash "$ROOT_DIR/$scenario"
done
