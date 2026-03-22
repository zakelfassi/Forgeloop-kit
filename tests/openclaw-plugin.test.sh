#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node --input-type=module - "$ROOT_DIR" <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const root = process.argv[2];
const pluginRoot = path.join(root, ".openclaw", "extensions", "forgeloop");
const manifest = JSON.parse(fs.readFileSync(path.join(pluginRoot, "openclaw.plugin.json"), "utf8"));
const packageJson = JSON.parse(fs.readFileSync(path.join(pluginRoot, "package.json"), "utf8"));
const entrySource = fs.readFileSync(path.join(pluginRoot, "index.ts"), "utf8");
assert.equal(manifest.id, "forgeloop");
assert.equal(manifest.configSchema.type, "object");
assert.equal(manifest.configSchema.properties.allowOrchestrationApply.default, false);
assert.equal(manifest.version, packageJson.version);
assert.deepEqual(packageJson.openclaw.extensions, ["./index.ts"]);
assert.match(entrySource, /export \{ default \} from "\.\/index\.mjs";/);

const plugin = (await import(pathToFileURL(path.join(pluginRoot, "index.mjs")).href)).default;

const basePluginConfig = {
  baseUrl: "http://127.0.0.1:4010",
  requestTimeoutMs: 5000,
  allowMutations: true,
  allowOrchestrationApply: true,
  orchestrationDefaultLimit: 7
};

const { registrations, tools } = registerPlugin();
assert.deepEqual(
  registrations.map(({ tool }) => tool.name).sort(),
  ["forgeloop_control", "forgeloop_orchestrate", "forgeloop_overview", "forgeloop_question"]
);
assert.ok(registrations.every(({ opts }) => opts?.optional === true));

const fetchCalls = [];
globalThis.fetch = async (url, options = {}) => {
  fetchCalls.push({ url: String(url), options });
  const parsed = new URL(String(url));

  if (parsed.pathname === "/api/overview" && parsed.searchParams.get("limit") === "9") {
    return okJson({
      data: makeOverview({
        runtime_state: { status: "running", mode: "build", surface: "ui", branch: "main" },
        control_flags: { "pause_requested?": false, "replan_requested?": true },
        questions: [{ id: "Q-1", status_kind: "awaiting_response" }],
        escalations: [{ id: "E-1" }],
        tracker: { issues: [{ id: "plan:1" }, { id: "workflow:alpha" }] },
        events: [{ event_type: "daemon_tick" }],
        workflows: {
          workflows: [
            {
              entry: { name: "alpha" },
              active_run: { workflow_name: "alpha", action: "run" },
              history: { latest: { action: "run", outcome: "failed", finished_at: "2026-03-21T00:00:02Z" } }
            }
          ]
        }
      })
    });
  }

  if (parsed.pathname === "/api/events" && parsed.searchParams.get("limit") === "9" && !parsed.searchParams.get("after")) {
    return okJson({
      data: [
        { event_id: "evt-1", event_code: "daemon_tick", occurred_at: "2026-03-21T00:00:01Z" },
        { event_id: "evt-2", event_code: "operator_action", occurred_at: "2026-03-21T00:00:02Z", action: "replan_requested" }
      ],
      meta: { latest_event_id: "evt-2", returned_count: 2, limit: 9, "truncated?": false }
    });
  }

  if (parsed.pathname === "/api/control/run") {
    return okJson({ data: { mode: "build", surface: "openclaw" } });
  }

  if (parsed.pathname === "/api/workflows/alpha/preflight") {
    return okJson({ data: { lane: "workflow", action: "preflight", workflow: "alpha", surface: "openclaw" } });
  }

  if (parsed.pathname === "/api/questions") {
    return okJson({ data: [{ id: "Q-1", revision: "rev-1" }] });
  }

  if (parsed.pathname === "/api/questions/Q-1/answer") {
    return okJson({ data: { question: { id: "Q-1", revision: "rev-2", status_kind: "answered" } } });
  }

  throw new Error(`Unexpected fetch: ${url}`);
};

const overviewResult = await tools.forgeloop_overview.execute("1", { limit: 9 });
assert.match(overviewResult.content[0].text, /Runtime: running \/ build via ui on main/);
assert.match(overviewResult.content[0].text, /Backlog: 1 pending items from IMPLEMENTATION_PLAN\.md/);
assert.match(overviewResult.content[0].text, /Tracker: 2 projected repo-local issues/);
assert.match(overviewResult.content[0].text, /Workflows: 1 discovered \(1 active, failed=1, escalated=0, start_failed=0\)/);
assert.match(overviewResult.content[0].text, /Workflow alpha: run failed @ 2026-03-21T00:00:02Z/);
assert.match(overviewResult.content[0].text, /Recent events: 2/);
assert.match(overviewResult.content[0].text, /Event daemon_tick @ 2026-03-21T00:00:01Z/);
assert.match(overviewResult.content[0].text, /Event operator_action @ 2026-03-21T00:00:02Z/);

const controlResult = await tools.forgeloop_control.execute("2", { action: "build" });
assert.match(controlResult.content[0].text, /surface\": \"openclaw\"/);
assert.equal(fetchCalls.find((entry) => entry.url.endsWith("/api/events?limit=9")).url, "http://127.0.0.1:4010/api/events?limit=9");
assert.equal(fetchCalls.find((entry) => entry.url.endsWith("/api/control/run")).url, "http://127.0.0.1:4010/api/control/run");
assert.deepEqual(
  JSON.parse(fetchCalls.find((entry) => entry.url.endsWith("/api/control/run")).options.body),
  { mode: "build", surface: "openclaw" }
);

const workflowControlResult = await tools.forgeloop_control.execute("2b", { action: "workflow_preflight", workflowName: "alpha" });
assert.match(workflowControlResult.content[0].text, /workflow\": \"alpha\"/);
assert.deepEqual(
  JSON.parse(fetchCalls.find((entry) => entry.url.endsWith("/api/workflows/alpha/preflight")).options.body),
  { surface: "openclaw" }
);

const questionResult = await tools.forgeloop_question.execute("3", { action: "answer", questionId: "Q-1", answer: "Proceed." });
assert.match(questionResult.content[0].text, /status_kind\": \"answered\"/);
assert.deepEqual(
  JSON.parse(fetchCalls.find((entry) => entry.url.endsWith("/api/questions/Q-1/answer")).options.body),
  { expected_revision: "rev-1", answer: "Proceed." }
);

let recommendationOverview = makeOverview({
  runtime_state: { status: "running", mode: "build", surface: "service", branch: "main" },
  control_flags: { "pause_requested?": false, "replan_requested?": false },
  questions: [],
  babysitter: { "running?": false }
});
globalThis.fetch = async (url) => {
  const parsed = new URL(String(url));
  if (parsed.pathname === "/api/overview") {
    return okJson({ data: recommendationOverview });
  }
  if (parsed.pathname === "/api/events") {
    assert.equal(parsed.searchParams.get("after"), "evt-0");
    assert.equal(parsed.searchParams.get("limit"), "9");
    return okJson({
      data: [
        { event_id: "evt-2", event_code: "operator_action", occurred_at: "2026-03-21T01:00:00Z", action: "clear_pause" },
        { event_id: "evt-2", event_code: "operator_action", occurred_at: "2026-03-21T01:00:00Z", action: "clear_pause" },
        { event_id: "evt-3", event_code: "operator_action", occurred_at: "2026-03-21T01:01:00Z", action: "clear_pause" }
      ],
      meta: { latest_event_id: "evt-3", returned_count: 3, limit: 9, "cursor_found?": true, "truncated?": false }
    });
  }
  throw new Error(`Unexpected recommend fetch: ${url}`);
};

const recommendResult = await tools.forgeloop_orchestrate.execute("4", { mode: "recommend", after: "evt-0", limit: 9 });
const recommendPayload = parsePayload(recommendResult);
assert.equal(recommendPayload.event_source, "events_api");
assert.equal(recommendPayload.cursor.next_after, "evt-3");
assert.equal(recommendPayload.summary.duplicate_events, 1);
assert.equal(recommendPayload.summary.recommendations, 1);
assert.deepEqual(recommendPayload.summary.playbooks, { total: 1, actionable: 1, blocked: 0, observe: 0 });
assert.equal(recommendPayload.recommendations[0].rule, "replan_after_clear_pause");
assert.equal(recommendPayload.recommendations[0].action, "replan");
assert.equal(recommendPayload.recommendations[0].playbook_id, "post_clear_pause_rebuild");
assert.equal(recommendPayload.recommendations[0].apply_eligible, true);
assert.equal(recommendPayload.playbooks[0].id, "post_clear_pause_rebuild");
assert.equal(recommendPayload.playbooks[0].status, "actionable");
assert.equal(recommendPayload.playbooks[0].recommended_action, "replan");
assert.equal(recommendPayload.playbooks[0].steps[0].kind, "control_action");
assert.equal(recommendPayload.playbooks[0].steps[0].action, "replan");
assert.equal(recommendPayload.applied.result, "not_requested");

const absentPlaybookResult = await tools.forgeloop_orchestrate.execute("4b", {
  mode: "recommend",
  after: "evt-0",
  limit: 9,
  playbookId: "human_answer_recovery"
});
const absentPlaybookPayload = parsePayload(absentPlaybookResult);
assert.equal(absentPlaybookPayload.selected_playbook_id, "human_answer_recovery");
assert.equal(absentPlaybookPayload.summary.recommendations, 0);
assert.deepEqual(absentPlaybookPayload.summary.playbooks, { total: 0, actionable: 0, blocked: 0, observe: 0 });
assert.deepEqual(absentPlaybookPayload.recommendations, []);
assert.deepEqual(absentPlaybookPayload.playbooks, []);
assert.ok(absentPlaybookPayload.warnings.includes("selected_playbook_not_triggered"));

const blockedOverview = makeOverview({
  runtime_state: { status: "paused", mode: "build", surface: "service", branch: "main" },
  control_flags: { "pause_requested?": true, "replan_requested?": false },
  questions: [{ id: "Q-blocked", status_kind: "awaiting_response" }],
  babysitter: { "running?": false }
});
globalThis.fetch = async (url) => {
  const parsed = new URL(String(url));
  if (parsed.pathname === "/api/overview") {
    return okJson({ data: blockedOverview });
  }
  if (parsed.pathname === "/api/events") {
    return okJson({
      data: [
        { event_id: "evt-blocked", event_code: "operator_action", occurred_at: "2026-03-21T01:30:00Z", action: "answer_question" }
      ],
      meta: { latest_event_id: "evt-blocked", returned_count: 1, limit: 6, "cursor_found?": true, "truncated?": false }
    });
  }
  throw new Error(`Unexpected blocked fetch: ${url}`);
};

const blockedResult = await tools.forgeloop_orchestrate.execute("4c", {
  mode: "recommend",
  after: "evt-prev-blocked",
  limit: 6,
  playbookId: "human_answer_recovery"
});
const blockedPayload = parsePayload(blockedResult);
assert.equal(blockedPayload.playbooks[0].id, "human_answer_recovery");
assert.equal(blockedPayload.playbooks[0].status, "blocked");
assert.equal(blockedPayload.playbooks[0].recommended_action, "clear_pause");
assert.ok(blockedPayload.playbooks[0].blocked_by.includes("unanswered_questions_remain"));
assert.equal(blockedPayload.playbooks[0].steps[0].kind, "control_action");
assert.equal(blockedPayload.playbooks[0].steps[0].apply_eligible, false);
assert.deepEqual(blockedPayload.summary.playbooks, { total: 1, actionable: 0, blocked: 1, observe: 0 });

const observeOverview = makeOverview({
  runtime_state: { status: "paused", mode: "build", surface: "service", branch: "main" },
  control_flags: { "pause_requested?": true, "replan_requested?": false },
  questions: [],
  babysitter: { "running?": false }
});
globalThis.fetch = async (url) => {
  const parsed = new URL(String(url));
  if (parsed.pathname === "/api/overview") {
    return okJson({ data: observeOverview });
  }
  if (parsed.pathname === "/api/events") {
    return okJson({
      data: [
        { event_id: "evt-observe", event_code: "loop_failed", occurred_at: "2026-03-21T01:45:00Z" }
      ],
      meta: { latest_event_id: "evt-observe", returned_count: 1, limit: 6, "cursor_found?": true, "truncated?": false }
    });
  }
  throw new Error(`Unexpected observe fetch: ${url}`);
};

const observeResult = await tools.forgeloop_orchestrate.execute("4d", {
  mode: "recommend",
  after: "evt-prev-observe",
  limit: 6,
  playbookId: "failure_stabilization"
});
const observePayload = parsePayload(observeResult);
assert.equal(observePayload.playbooks[0].id, "failure_stabilization");
assert.equal(observePayload.playbooks[0].status, "observe");
assert.equal(observePayload.playbooks[0].recommended_action, null);
assert.equal(observePayload.playbooks[0].steps[0].kind, "manual");
assert.deepEqual(observePayload.summary.playbooks, { total: 1, actionable: 0, blocked: 0, observe: 1 });

let resetOverview = makeOverview({ events: [] });
globalThis.fetch = async (url) => {
  const parsed = new URL(String(url));
  if (parsed.pathname === "/api/overview") {
    return okJson({ data: resetOverview });
  }
  if (parsed.pathname === "/api/events") {
    return okJson({
      data: [],
      meta: { latest_event_id: "evt-9", returned_count: 0, limit: 5, "cursor_found?": false, "truncated?": false }
    });
  }
  throw new Error(`Unexpected reset fetch: ${url}`);
};

const resetResult = await tools.forgeloop_orchestrate.execute("5", { mode: "recommend", after: "stale-cursor", limit: 5 });
const resetPayload = parsePayload(resetResult);
assert.equal(resetPayload.cursor.next_after, "evt-9");
assert.equal(resetPayload.cursor.reset_required, true);
assert.ok(resetPayload.warnings.includes("cursor_not_found_reset_required"));

const fallbackOverview = makeOverview({
  runtime_state: { status: "running", mode: "build", surface: "service", branch: "main" },
  control_flags: { "pause_requested?": false, "replan_requested?": false },
  events: [
    { event_id: "evt-fallback", event_code: "loop_failed", occurred_at: "2026-03-21T02:00:00Z" }
  ]
});
globalThis.fetch = async (url) => {
  const parsed = new URL(String(url));
  if (parsed.pathname === "/api/overview") {
    return okJson({ data: fallbackOverview });
  }
  if (parsed.pathname === "/api/events") {
    throw new Error("simulated events outage");
  }
  throw new Error(`Unexpected fallback fetch: ${url}`);
};

const fallbackResult = await tools.forgeloop_orchestrate.execute("6", {
  mode: "recommend",
  after: "evt-base",
  limit: 4,
  playbookId: "failure_stabilization"
});
const fallbackPayload = parsePayload(fallbackResult);
assert.equal(fallbackPayload.event_source, "overview_fallback");
assert.ok(fallbackPayload.warnings.includes("events_api_unavailable"));
assert.ok(fallbackPayload.warnings.includes("cursor_reset_required_after_fallback"));
assert.equal(fallbackPayload.cursor.reset_required, true);
assert.equal(fallbackPayload.cursor.next_after, "evt-base");
assert.equal(fallbackPayload.applied.result, "not_requested");
assert.equal(fallbackPayload.summary.recommendations, 1);
assert.equal(fallbackPayload.playbooks[0].id, "failure_stabilization");
assert.equal(fallbackPayload.playbooks[0].status, "actionable");
assert.equal(fallbackPayload.playbooks[0].recommended_action, "pause");

let targetedApplyOverview = makeOverview({
  runtime_state: { status: "paused", mode: "build", surface: "service", branch: "main" },
  control_flags: { "pause_requested?": true, "replan_requested?": false },
  questions: [],
  babysitter: { "running?": false }
});
let clearPauseCalls = 0;
let replanCalls = 0;
globalThis.fetch = async (url, options = {}) => {
  const parsed = new URL(String(url));
  if (parsed.pathname === "/api/overview") {
    return okJson({ data: targetedApplyOverview });
  }
  if (parsed.pathname === "/api/events") {
    return okJson({
      data: [
        { event_id: "evt-answer", event_code: "operator_action", occurred_at: "2026-03-21T03:00:00Z", action: "answer_question" },
        { event_id: "evt-clear", event_code: "operator_action", occurred_at: "2026-03-21T03:01:00Z", action: "clear_pause" }
      ],
      meta: { latest_event_id: "evt-clear", returned_count: 2, limit: 6, "cursor_found?": true, "truncated?": false }
    });
  }
  if (parsed.pathname === "/api/control/clear-pause") {
    clearPauseCalls += 1;
    return okJson({ data: { action: "clear_pause", ok: true } });
  }
  if (parsed.pathname === "/api/control/replan") {
    replanCalls += 1;
    assert.deepEqual(JSON.parse(options.body), {});
    targetedApplyOverview = makeOverview({
      runtime_state: { status: "paused", mode: "build", surface: "service", branch: "main" },
      control_flags: { "pause_requested?": true, "replan_requested?": true },
      questions: [],
      babysitter: { "running?": false }
    });
    return okJson({ data: { action: "replan", ok: true } });
  }
  throw new Error(`Unexpected targeted apply fetch: ${url}`);
};

const targetedApplyResult = await tools.forgeloop_orchestrate.execute("7", {
  mode: "apply",
  after: "evt-prev",
  limit: 6,
  playbookId: "post_clear_pause_rebuild"
});
const targetedApplyPayload = parsePayload(targetedApplyResult);
assert.equal(clearPauseCalls, 0);
assert.equal(replanCalls, 1);
assert.equal(targetedApplyPayload.selected_playbook_id, "post_clear_pause_rebuild");
assert.equal(targetedApplyPayload.applied.attempted, true);
assert.equal(targetedApplyPayload.applied.action, "replan");
assert.equal(targetedApplyPayload.applied.result, "applied");
assert.equal(targetedApplyPayload.cursor.next_after, "evt-clear");
assert.equal(targetedApplyPayload.summary.recommendations, 1);
assert.deepEqual(targetedApplyPayload.summary.playbooks, { total: 1, actionable: 1, blocked: 0, observe: 0 });

let applyErrorOverview = makeOverview({
  runtime_state: { status: "running", mode: "build", surface: "service", branch: "main" },
  control_flags: { "pause_requested?": false, "replan_requested?": false },
  questions: [],
  babysitter: { "running?": false }
});
globalThis.fetch = async (url) => {
  const parsed = new URL(String(url));
  if (parsed.pathname === "/api/overview") {
    return okJson({ data: applyErrorOverview });
  }
  if (parsed.pathname === "/api/events") {
    return okJson({
      data: [
        { event_id: "evt-fail", event_code: "operator_action", occurred_at: "2026-03-21T04:00:00Z", action: "clear_pause" }
      ],
      meta: { latest_event_id: "evt-fail", returned_count: 1, limit: 6, "cursor_found?": true, "truncated?": false }
    });
  }
  if (parsed.pathname === "/api/control/replan") {
    throw new Error("simulated replan failure");
  }
  throw new Error(`Unexpected apply-error fetch: ${url}`);
};

const applyErrorResult = await tools.forgeloop_orchestrate.execute("7b", {
  mode: "apply",
  after: "evt-prev-2",
  limit: 6,
  playbookId: "post_clear_pause_rebuild"
});
const applyErrorPayload = parsePayload(applyErrorResult);
assert.equal(applyErrorPayload.applied.attempted, true);
assert.equal(applyErrorPayload.applied.action, "replan");
assert.equal(applyErrorPayload.applied.result, "error");
assert.match(applyErrorPayload.applied.reason, /simulated replan failure/);
assert.equal(applyErrorPayload.cursor.next_after, "evt-fail");

await assert.rejects(
  tools.forgeloop_orchestrate.execute("7c", { mode: "recommend", after: "evt-prev-3", playbookId: "not_a_playbook" }),
  /Unsupported Forgeloop playbookId/
);
await assert.rejects(
  tools.forgeloop_orchestrate.execute("7d", { mode: "apply", after: "evt-prev-4", playbookId: "   " }),
  /playbookId must be a non-empty string/
);
await assert.rejects(
  tools.forgeloop_orchestrate.execute("7e", { mode: "apply", after: "evt-prev-5", playbookId: 123 }),
  /playbookId must be a non-empty string/
);

const { tools: lockedTools } = registerPlugin({ allowMutations: false, allowOrchestrationApply: false });
await assert.rejects(
  lockedTools.forgeloop_control.execute("8", { action: "pause" }),
  /mutations are disabled/
);
await assert.rejects(
  lockedTools.forgeloop_orchestrate.execute("9", { mode: "apply", after: "evt-prev" }),
  /mutations are disabled/
);

const { tools: applyDisabledTools } = registerPlugin({ allowMutations: true, allowOrchestrationApply: false });
await assert.rejects(
  applyDisabledTools.forgeloop_orchestrate.execute("10", { mode: "apply", after: "evt-prev" }),
  /apply mode is disabled/
);

function registerPlugin(configOverrides = {}) {
  const registrations = [];
  const api = {
    config: {
      plugins: {
        entries: {
          forgeloop: {
            config: {
              ...basePluginConfig,
              ...configOverrides
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

  return {
    registrations,
    tools: Object.fromEntries(registrations.map(({ tool }) => [tool.name, tool]))
  };
}

function makeOverview(overrides = {}) {
  return {
    runtime_state: { status: "running", mode: "build", surface: "ui", branch: "main", ...(overrides.runtime_state || {}) },
    backlog: {
      "needs_build?": true,
      "exists?": true,
      source: {
        kind: "implementation_plan",
        label: "IMPLEMENTATION_PLAN.md",
        path: "/tmp/repo/IMPLEMENTATION_PLAN.md",
        "canonical?": true,
        phase: "phase1"
      },
      items: [{ id: "task-1" }],
      ...(overrides.backlog || {})
    },
    control_flags: { "pause_requested?": false, "replan_requested?": false, ...(overrides.control_flags || {}) },
    tracker: overrides.tracker || { issues: [] },
    questions: overrides.questions || [],
    escalations: overrides.escalations || [],
    events: overrides.events || [],
    workflows: overrides.workflows || { workflows: [] },
    babysitter: { "running?": false, ...(overrides.babysitter || {}) }
  };
}

function parsePayload(result) {
  const text = result.content?.[0]?.text || "";
  const start = text.indexOf("{\n");
  assert.ok(start >= 0, `expected JSON payload in tool result: ${text}`);
  return JSON.parse(text.slice(start));
}

function okJson(body) {
  return {
    ok: true,
    status: 200,
    statusText: "OK",
    async text() {
      return JSON.stringify({ ok: true, ...body });
    }
  };
}
NODE

echo "ok: openclaw plugin seam"
