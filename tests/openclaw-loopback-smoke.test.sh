#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v mix >/dev/null 2>&1; then
  echo "skip: openclaw loopback smoke (mix not available)"
  exit 0
fi

if ! command -v node >/dev/null 2>&1; then
  echo "skip: openclaw loopback smoke (node not available)"
  exit 0
fi

HOST="127.0.0.1"
PORT="$((4400 + RANDOM % 400))"
BASE_URL="http://${HOST}:${PORT}"
TMP_REPO="$(mktemp -d)"
TMP_SUPPORT="$(mktemp -d)"
SERVICE_LOG="$TMP_SUPPORT/service.log"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_REPO" "$TMP_SUPPORT"
}
trap cleanup EXIT

wait_for_http() {
  local path="$1"
  local timeout_seconds="${2:-60}"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if curl -fsS "$BASE_URL$path" >/dev/null 2>&1; then
      return 0
    fi

    if [[ -n "$SERVER_PID" ]] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "[openclaw-smoke] service exited unexpectedly" >&2
      tail -n 80 "$SERVICE_LOG" >&2 || true
      exit 1
    fi

    sleep 0.25
  done

  echo "[openclaw-smoke] timed out waiting for $BASE_URL$path" >&2
  tail -n 80 "$SERVICE_LOG" >&2 || true
  exit 1
}

mkdir -p "$TMP_REPO/bin" "$TMP_REPO/lib" "$TMP_REPO/elixir/priv/static" "$TMP_REPO/workflows/alpha"
cat >"$TMP_REPO/bin/loop.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
trap 'exit 0' TERM INT
sleep 30
EOF
chmod +x "$TMP_REPO/bin/loop.sh"
cat >"$TMP_REPO/bin/workflow-runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "run" ]]; then
  echo "unexpected:$*" >&2
  exit 2
fi
shift
mode="run"
if [[ "${1:-}" == "--preflight" ]]; then
  mode="preflight"
  shift
fi
workflow="${1:-unknown}"
echo "workflow:${workflow}:${mode}"
sleep 1
EOF
chmod +x "$TMP_REPO/bin/workflow-runner"
cat >"$TMP_REPO/workflows/alpha/workflow.toml" <<'EOF'
version = 1
EOF
cat >"$TMP_REPO/workflows/alpha/workflow.dot" <<'EOF'
digraph Alpha {}
EOF
cp -R "$ROOT_DIR/lib/." "$TMP_REPO/lib/"
cp "$ROOT_DIR/config.sh" "$TMP_REPO/config.sh"
cp -R "$ROOT_DIR/elixir/priv/static/ui" "$TMP_REPO/elixir/priv/static/ui"

cat >"$TMP_REPO/IMPLEMENTATION_PLAN.md" <<'EOF'
# Signalboard alpha backlog

- [ ] Ship queue polish
EOF

cat >"$TMP_REPO/REQUESTS.md" <<'EOF'
[PAUSE]
EOF

cat >"$TMP_REPO/QUESTIONS.md" <<'EOF'
## Q-1 (2026-03-25 00:00:00)
**Category**: blocked
**Question**: Which backlog should we prioritize first?
**Status**: ⏳ Awaiting response

**Answer**:
EOF

: >"$TMP_REPO/ESCALATIONS.md"
mkdir -p "$TMP_REPO/.forgeloop"
cat >"$TMP_REPO/.forgeloop/runtime-state.json" <<'EOF'
{
  "status": "paused",
  "transition": "paused",
  "surface": "loop",
  "mode": "build",
  "requested_action": "",
  "reason": "Waiting for operator input",
  "branch": "main"
}
EOF
cat >"$TMP_REPO/.gitignore" <<'EOF'
.forgeloop/
EOF

(
  cd "$TMP_REPO"
  git init >/dev/null
  git config user.email "tests@example.com"
  git config user.name "OpenClaw Smoke"
  git config commit.gpgsign false
  git add .
  git commit -m "seed openclaw smoke fixture" >/dev/null
  git branch -M main >/dev/null 2>&1 || true
)

(
  cd "$ROOT_DIR/elixir"
  mix deps.get >/dev/null
  mix compile >/dev/null
  FORGELOOP_WORKFLOW_RUNNER="$TMP_REPO/bin/workflow-runner" \
    mix forgeloop_v2.serve --repo "$TMP_REPO" --host "$HOST" --port "$PORT" >"$SERVICE_LOG" 2>&1
) &
SERVER_PID=$!

wait_for_http '/api/schema' 60

node --input-type=module - "$ROOT_DIR" "$BASE_URL" "$TMP_REPO" <<'NODE'
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = process.argv[2];
const baseUrl = process.argv[3];
const repoRoot = process.argv[4];
const pluginRoot = path.join(root, '.openclaw', 'extensions', 'forgeloop');
const plugin = (await import(pathToFileURL(path.join(pluginRoot, 'index.mjs')).href)).default;

function registerPlugin() {
  const registrations = [];
  const api = {
    config: {
      plugins: {
        entries: {
          forgeloop: {
            config: {
              baseUrl,
              requestTimeoutMs: 15000,
              allowMutations: true,
              allowOrchestrationApply: false,
              orchestrationDefaultLimit: 10
            }
          }
        }
      }
    },
    registerTool(tool, opts) {
      registrations.push({ tool, opts });
    }
  };

  plugin.register(api);
  return Object.fromEntries(registrations.map(({ tool }) => [tool.name, tool]));
}

function parsePayload(result) {
  const text = result.content?.[0]?.text || '';
  const start = text.indexOf('{\n');
  assert.ok(start >= 0, `expected JSON payload in tool result: ${text}`);
  return JSON.parse(text.slice(start));
}

async function waitForSlotStatus(tools, slotId, matcher, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const detail = parsePayload(await tools.forgeloop_slots.execute(`slot-wait-${slotId}`, { action: 'detail', slotId }));
    if (matcher(detail.status, detail)) return detail;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`timed out waiting for slot ${slotId}`);
}

const tools = registerPlugin();

const overviewBefore = await tools.forgeloop_overview.execute('overview-before', { limit: 6 });
assert.match(overviewBefore.content[0].text, /Forgeloop overview/);
assert.match(overviewBefore.content[0].text, /Runtime: paused \/ build via loop on main/);
assert.match(overviewBefore.content[0].text, /Questions: 1 total, 1 awaiting response/);
assert.match(overviewBefore.content[0].text, /Flags: pause=yes/);

const slotsBefore = await tools.forgeloop_slots.execute('slots-before', { action: 'list' });
assert.match(slotsBefore.content[0].text, /Forgeloop slots/);
assert.match(slotsBefore.content[0].text, /Slots: 0 total \/ 0 active \/ 0 blocked/);

const slotStart = await tools.forgeloop_slots.execute('slot-start', {
  action: 'start',
  lane: 'checklist',
  slotAction: 'plan'
});
const slotStartPayload = parsePayload(slotStart);
const slotId = slotStartPayload.slot_id;
assert.ok(typeof slotId === 'string' && slotId.length > 0);
assert.equal(slotStartPayload.lane, 'checklist');
assert.equal(slotStartPayload.action, 'plan');

const slotsAfterStart = await tools.forgeloop_slots.execute('slots-after-start', { action: 'list' });
assert.match(slotsAfterStart.content[0].text, new RegExp(`Slots: [1-9][0-9]* total \/ [1-9][0-9]* active \/ 0 blocked`));
assert.match(slotsAfterStart.content[0].text, new RegExp(`${slotId}: checklist plan → (starting|running|stopping|completed|blocked) via openclaw`));

const slotDetail = await tools.forgeloop_slots.execute('slot-detail', { action: 'detail', slotId });
const slotDetailPayload = parsePayload(slotDetail);
assert.equal(slotDetailPayload.slot_id, slotId);
assert.equal(slotDetailPayload.write_class, 'read');
assert.ok(typeof slotDetailPayload.coordination_paths?.requests === 'string' && slotDetailPayload.coordination_paths.requests.length > 0);

const slotStop = await tools.forgeloop_slots.execute('slot-stop', {
  action: 'stop',
  slotId,
  stopReason: 'kill'
});
const slotStopPayload = parsePayload(slotStop);
assert.equal(slotStopPayload.slot_id, slotId);
assert.ok(['stopping', 'completed', 'blocked'].includes(slotStopPayload.status));

const buildSlot = await tools.forgeloop_slots.execute('slot-build', {
  action: 'start',
  lane: 'checklist',
  slotAction: 'build'
});
const buildSlotPayload = parsePayload(buildSlot);
const buildSlotId = buildSlotPayload.slot_id;
assert.equal(buildSlotPayload.write_class, 'write');
assert.equal(buildSlotPayload.coordination_scope, 'canonical');

const buildSlotDetail = parsePayload(await tools.forgeloop_slots.execute('slot-build-detail', { action: 'detail', slotId: buildSlotId }));
assert.equal(buildSlotDetail.coordination_paths.requests, path.join(repoRoot, 'REQUESTS.md'));
assert.equal(buildSlotDetail.coordination_paths.questions, path.join(repoRoot, 'QUESTIONS.md'));
assert.equal(buildSlotDetail.coordination_paths.escalations, path.join(repoRoot, 'ESCALATIONS.md'));

const buildSlotStop = await tools.forgeloop_slots.execute('slot-build-stop', {
  action: 'stop',
  slotId: buildSlotId,
  stopReason: 'kill'
});
const buildSlotStopPayload = parsePayload(buildSlotStop);
assert.equal(buildSlotStopPayload.slot_id, buildSlotId);
assert.ok(['stopping', 'completed', 'blocked'].includes(buildSlotStopPayload.status));
assert.match(fs.readFileSync(path.join(repoRoot, 'REQUESTS.md'), 'utf8'), /\[PAUSE\]/);

const workflowRun = await tools.forgeloop_slots.execute('workflow-run-slot', {
  action: 'start',
  lane: 'workflow',
  slotAction: 'run',
  workflowName: 'alpha'
});
const workflowRunPayload = parsePayload(workflowRun);
const workflowRunSlotId = workflowRunPayload.slot_id;
assert.equal(workflowRunPayload.write_class, 'write');
assert.equal(workflowRunPayload.coordination_scope, 'canonical');
const workflowRunDetail = await waitForSlotStatus(tools, workflowRunSlotId, (status) => ['completed', 'blocked', 'failed'].includes(status));
assert.equal(workflowRunDetail.workflow_name, 'alpha');
assert.equal(workflowRunDetail.coordination_scope, 'canonical');
assert.equal(workflowRunDetail.coordination_paths.requests, path.join(repoRoot, 'REQUESTS.md'));
assert.match(workflowRunDetail.last_result, /workflow run completed for alpha|completed|slot_process_down/);

const answer = 'Use the Signalboard backlog first.';
await tools.forgeloop_question.execute('answer', {
  action: 'answer',
  questionId: 'Q-1',
  answer
});

const questionsAfterAnswer = fs.readFileSync(path.join(repoRoot, 'QUESTIONS.md'), 'utf8');
assert.match(questionsAfterAnswer, /Use the Signalboard backlog first\./);

const orchestrationAfterAnswer = await tools.forgeloop_orchestrate.execute('orchestrate-answer', {
  mode: 'recommend',
  limit: 10
});
const orchestrationAfterAnswerPayload = parsePayload(orchestrationAfterAnswer);
assert.equal(orchestrationAfterAnswerPayload.coordination_source, 'service');
assert.ok(typeof orchestrationAfterAnswerPayload.brief === 'string' && orchestrationAfterAnswerPayload.brief.length > 0);
assert.ok(Array.isArray(orchestrationAfterAnswerPayload.timeline));
assert.ok(Array.isArray(orchestrationAfterAnswerPayload.playbooks));

await tools.forgeloop_control.execute('clear-pause', { action: 'clear_pause' });
const requestsAfterClearPause = fs.readFileSync(path.join(repoRoot, 'REQUESTS.md'), 'utf8');
assert.doesNotMatch(requestsAfterClearPause, /\[PAUSE\]/);

const orchestrationAfterClearPause = await tools.forgeloop_orchestrate.execute('orchestrate-clear-pause', {
  mode: 'recommend',
  limit: 10
});
const orchestrationAfterClearPausePayload = parsePayload(orchestrationAfterClearPause);
assert.equal(orchestrationAfterClearPausePayload.coordination_source, 'service');
assert.ok(typeof orchestrationAfterClearPausePayload.brief === 'string' && orchestrationAfterClearPausePayload.brief.length > 0);
assert.ok(Array.isArray(orchestrationAfterClearPausePayload.recommendations));

await tools.forgeloop_control.execute('replan', { action: 'replan' });
const requestsAfterReplan = fs.readFileSync(path.join(repoRoot, 'REQUESTS.md'), 'utf8');
assert.match(requestsAfterReplan, /\[REPLAN\]/);

const overviewAfter = await tools.forgeloop_overview.execute('overview-after', { limit: 6 });
assert.match(overviewAfter.content[0].text, /Questions: 1 total, 0 awaiting response/);
assert.match(overviewAfter.content[0].text, /Flags: pause=no replan=yes/);
NODE

echo "ok: openclaw loopback smoke"
