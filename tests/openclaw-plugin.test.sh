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
  ["forgeloop_control", "forgeloop_orchestrate", "forgeloop_overview", "forgeloop_question", "forgeloop_slots"]
);
assert.ok(registrations.every(({ opts }) => opts?.optional === true));

const fetchCalls = [];
globalThis.fetch = async (url, options = {}) => {
  fetchCalls.push({ url: String(url), options });
  const parsed = new URL(String(url));

  if (parsed.pathname === "/api/schema") {
    return okJson({ data: makeSchema() });
  }

  if (parsed.pathname === "/api/overview" && parsed.searchParams.get("limit") === "9") {
    return okJson({
      data: makeOverview({
        runtime_state: { status: "running", mode: "build", surface: "ui", branch: "main" },
        ownership: {
          summary_state: "ready",
          headline: "Manual starts are currently clear",
          detail: "No live ownership conflicts or malformed run metadata are blocking a manual start.",
          "start_allowed?": true,
          "conflict?": false,
          "fail_closed?": false,
          start_gate: { status: "allowed", reason: null, http_status: null, "reclaim_on_start?": false, "cleanup_on_start?": false, details: null },
          runtime_owner: { state: "missing", owner: null, surface: null, mode: null, branch: null, claim_id: null, "reclaimable?": false, error: null },
          active_run: { state: "missing", "managed?": false, "running?": false, lane: null, action: null, mode: null, workflow_name: null, branch: null, runtime_surface: null, error: null }
        },
        control_flags: { "pause_requested?": false, "replan_requested?": true },
        questions: [{ id: "Q-1", status_kind: "awaiting_response" }],
        escalations: [{ id: "E-1" }],
        tracker: { issues: [{ id: "plan:1" }, { id: "workflow:alpha" }] },
        events: [{ event_type: "daemon_tick" }],
        coordination: makeCoordination({
          status: "actionable",
          brief: "Actionable: Queue the next rebuild pass — Pause was cleared while the backlog still needs a build and no replan is currently queued.",
          timeline: [
            {
              event_id: "evt-1",
              event_code: "daemon_tick",
              occurred_at: "2026-03-21T00:00:01Z",
              kind: "daemon_decision",
              title: "Daemon decided Build",
              detail: "Backlog still needs work.",
              surface: "daemon",
              related_playbook_ids: []
            }
          ],
          summary: { recommendations: 1, playbooks: { total: 1, actionable: 1, blocked: 0, observe: 0 } }
        }),
        workflows: {
          workflows: [
            {
              entry: { name: "alpha" },
              active_run: { workflow_name: "alpha", action: "run" },
              history: { latest: { action: "run", outcome: "failed", finished_at: "2026-03-21T00:00:02Z" } }
            }
          ]
        },
        slots: {
          items: [
            {
              slot_id: "slot-1",
              lane: "checklist",
              action: "plan",
              status: "running",
              runtime_surface: "openclaw",
              slot_paths: { root: "/tmp/slot-1" }
            }
          ],
          counts: { total: 1, active: 1, blocked: 0 },
          limits: { read: 3, write: 1 }
        }
      })
    });
  }

  if (parsed.pathname === "/api/slots" && (!parsed.search || parsed.search === "")) {
    if ((options.method || "GET") === "POST") {
      const requestBody = JSON.parse(options.body);
      return okJson({ data: { slot_id: "slot-2", lane: requestBody.lane, action: requestBody.action, status: "starting", runtime_surface: "openclaw", write_class: ["build", "run"].includes(requestBody.action) ? "write" : "read", coordination_scope: ["build", "run"].includes(requestBody.action) ? "canonical" : "slot_local" } });
    }
    return okJson({ data: { items: [{ slot_id: "slot-1", lane: "checklist", action: "plan", status: "running", runtime_surface: "openclaw", write_class: "read", coordination_scope: "slot_local" }], counts: { total: 1, active: 1, blocked: 0 }, limits: { read: 3, write: 1 } } });
  }

  if (parsed.pathname === "/api/slots/slot-1") {
    return okJson({ data: { slot_id: "slot-1", lane: "checklist", action: "plan", status: "running", runtime_surface: "openclaw", coordination_paths: { requests: "/tmp/slot-1/REQUESTS.md" } } });
  }

  if (parsed.pathname === "/api/slots/slot-1/stop") {
    return okJson({ data: { slot_id: "slot-1", status: "stopping", runtime_surface: "openclaw" } });
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
assert.match(overviewResult.content[0].text, /Ownership: ready/);
assert.match(overviewResult.content[0].text, /Start gate: allowed/);
assert.match(overviewResult.content[0].text, /Ownership detail: No live ownership conflicts or malformed run metadata are blocking a manual start\./);
assert.match(overviewResult.content[0].text, /Slots: 1 total \(1 active, blocked=0, read_limit=3\)/);
assert.match(overviewResult.content[0].text, /Workflows: 1 discovered \(1 active, failed=1, escalated=0, start_failed=0\)/);
assert.match(overviewResult.content[0].text, /Coordination: actionable \(1 playbooks, 1 recommendations\)/);
assert.match(overviewResult.content[0].text, /Coordination brief: Actionable: Queue the next rebuild pass/);
assert.match(overviewResult.content[0].text, /Workflow alpha: run failed @ 2026-03-21T00:00:02Z/);
assert.match(overviewResult.content[0].text, /Recent events: 2/);
assert.match(overviewResult.content[0].text, /Event daemon_tick @ 2026-03-21T00:00:01Z/);
assert.match(overviewResult.content[0].text, /Event operator_action @ 2026-03-21T00:00:02Z/);

const controlResult = await tools.forgeloop_control.execute("2", { action: "build" });
assert.match(controlResult.content[0].text, /surface\": \"openclaw\"/);
assert.equal(fetchCalls.find((entry) => entry.url.endsWith("/api/schema")).url, "http://127.0.0.1:4010/api/schema");
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

const slotListResult = await tools.forgeloop_slots.execute("slots-1", { action: "list" });
assert.match(slotListResult.content[0].text, /Slots: 1 total \/ 1 active \/ 0 blocked/);
assert.match(slotListResult.content[0].text, /slot-1: checklist plan → running via openclaw/);

const slotDetailResult = await tools.forgeloop_slots.execute("slots-2", { action: "detail", slotId: "slot-1" });
assert.match(slotDetailResult.content[0].text, /coordination_paths/);

const slotStartResult = await tools.forgeloop_slots.execute("slots-3", { action: "start", lane: "checklist", slotAction: "plan" });
assert.match(slotStartResult.content[0].text, /slot-2/);
assert.deepEqual(
  JSON.parse(fetchCalls.find((entry) => entry.url.endsWith("/api/slots") && (entry.options.method || "GET") === "POST").options.body),
  { lane: "checklist", action: "plan", surface: "openclaw", ephemeral: true }
);

const buildSlotResult = await tools.forgeloop_slots.execute("slots-3b", { action: "start", lane: "checklist", slotAction: "build" });
assert.match(buildSlotResult.content[0].text, /"write_class": "write"/);
assert.deepEqual(
  JSON.parse(fetchCalls.filter((entry) => entry.url.endsWith("/api/slots") && (entry.options.method || "GET") === "POST")[1].options.body),
  { lane: "checklist", action: "build", surface: "openclaw", ephemeral: true }
);

const workflowRunSlotResult = await tools.forgeloop_slots.execute("slots-3c", { action: "start", lane: "workflow", slotAction: "run", workflowName: "alpha" });
assert.match(workflowRunSlotResult.content[0].text, /"action": "run"/);
assert.deepEqual(
  JSON.parse(fetchCalls.filter((entry) => entry.url.endsWith("/api/slots") && (entry.options.method || "GET") === "POST")[2].options.body),
  { lane: "workflow", action: "run", workflow_name: "alpha", surface: "openclaw", ephemeral: true }
);

const slotStopResult = await tools.forgeloop_slots.execute("slots-4", { action: "stop", slotId: "slot-1", stopReason: "kill" });
assert.match(slotStopResult.content[0].text, /slot-1/);
assert.deepEqual(
  JSON.parse(fetchCalls.find((entry) => entry.url.endsWith("/api/slots/slot-1/stop")).options.body),
  { reason: "kill" }
);

const questionResult = await tools.forgeloop_question.execute("3", { action: "answer", questionId: "Q-1", answer: "Proceed." });
assert.match(questionResult.content[0].text, /status_kind\": \"answered\"/);
assert.deepEqual(
  JSON.parse(fetchCalls.find((entry) => entry.url.endsWith("/api/questions/Q-1/answer")).options.body),
  { expected_revision: "rev-1", answer: "Proceed." }
);

globalThis.fetch = async (url, options = {}) => {
  const parsed = new URL(String(url));
  if (parsed.pathname === "/api/schema") {
    return okJson({ data: makeSchema() });
  }
  if (parsed.pathname === "/api/control/run") {
    return {
      ok: false,
      status: 409,
      statusText: "Conflict",
      async text() {
        return JSON.stringify({
          ok: false,
          api: { name: "forgeloop_loopback", contract_version: 1, schema_path: "/api/schema" },
          error: {
            reason: "active_runtime_owned_by",
            detail: "live owner conflict",
            details: { owner: "bash" },
            ownership: {
              summary_state: "blocked",
              headline: "Runtime ownership is currently held by bash",
              detail: "A live daemon build still owns the claim (rt-1). Wait for it to release or intervene manually.",
              "start_allowed?": false,
              "conflict?": true,
              "fail_closed?": false,
              start_gate: { status: "blocked", reason: "active_runtime_owned_by", http_status: 409, "reclaim_on_start?": false, "cleanup_on_start?": false, details: { owner: "bash" } },
              runtime_owner: { state: "live", owner: "bash", surface: "daemon", mode: "build", branch: "main", claim_id: "rt-1", "reclaimable?": false, error: null },
              active_run: { state: "missing", "managed?": false, "running?": false, lane: null, action: null, mode: null, workflow_name: null, branch: null, runtime_surface: null, error: null }
            }
          }
        });
      }
    };
  }
  throw new Error(`Unexpected ownership error fetch: ${url} ${options.method || "GET"}`);
};

await assert.rejects(
  tools.forgeloop_control.execute("3b", { action: "build" }),
  /A live daemon build still owns the claim \(rt-1\)\. Wait for it to release or intervene manually\./
);

let recommendationOverview = makeOverview({
  runtime_state: { status: "running", mode: "build", surface: "service", branch: "main" },
  control_flags: { "pause_requested?": false, "replan_requested?": false },
  questions: [],
  babysitter: { "running?": false }
});
let coordinationCalls = 0;
let eventsCalls = 0;
coordinationCalls = 0;
eventsCalls = 0;
globalThis.fetch = async (url) => {
  const parsed = new URL(String(url));
  if (parsed.pathname === "/api/overview") {
    return okJson({ data: recommendationOverview });
  }
  if (parsed.pathname === "/api/coordination") {
    coordinationCalls += 1;
    assert.equal(parsed.searchParams.get("after"), "evt-0");
    assert.equal(parsed.searchParams.get("limit"), "9");
    return okJson({
      data: makeCoordination({
        status: "actionable",
        cursor: { requested_after: "evt-0", next_after: "evt-3", cursor_found: true, truncated: false, reset_required: false },
        brief: "Actionable: Queue the next rebuild pass — Pause was cleared while the backlog still needs a build and no replan is currently queued.",
        timeline: [
          {
            event_id: "evt-1",
            event_code: "daemon_tick",
            occurred_at: "2026-03-21T01:00:00Z",
            kind: "daemon_decision",
            title: "Daemon decided Build",
            detail: "Backlog still needs work.",
            surface: "daemon",
            related_playbook_ids: []
          },
          {
            event_id: "evt-3",
            event_code: "operator_action",
            event_action: "clear_pause",
            occurred_at: "2026-03-21T01:01:00Z",
            kind: "operator_action",
            title: "Operator cleared pause",
            detail: null,
            surface: "ui",
            related_playbook_ids: ["post_clear_pause_rebuild"]
          }
        ],
        summary: {
          fetched_events: 3,
          unique_events: 2,
          duplicate_events: 1,
          actionable_events: 1,
          recommendations: 1,
          playbooks: { total: 1, actionable: 1, blocked: 0, observe: 0 }
        },
        recommendations: [
          {
            rule: "replan_after_clear_pause",
            action: "replan",
            playbook_id: "post_clear_pause_rebuild",
            event_id: "evt-3",
            event_code: "operator_action",
            event_action: "clear_pause",
            event_occurred_at: "2026-03-21T01:01:00Z",
            reason: "Pause was cleared while the backlog still needs a build and no replan is currently queued.",
            apply_eligible: true,
            blocked_by: []
          }
        ],
        playbooks: [
          {
            id: "post_clear_pause_rebuild",
            title: "Queue the next rebuild pass",
            goal: "Request a new plan/build pass after pause is cleared when canonical backlog work is still pending.",
            status: "actionable",
            reason: "Pause was cleared while the backlog still needs a build and no replan is currently queued.",
            evidence: [{ event_id: "evt-3", event_code: "operator_action", occurred_at: "2026-03-21T01:01:00Z", action: "clear_pause" }],
            recommended_action: "replan",
            apply_eligible: true,
            blocked_by: [],
            steps: [
              {
                kind: "control_action",
                title: "Request replan",
                detail: "Queue one bounded replan so the managed control plane can pick up the next backlog pass.",
                action: "replan",
                apply_eligible: true,
                blocked_by: []
              }
            ]
          }
        ]
      })
    });
  }
  if (parsed.pathname === "/api/events") {
    eventsCalls += 1;
    throw new Error("service-backed orchestration should not hit /api/events");
  }
  throw new Error(`Unexpected recommend fetch: ${url}`);
};

const recommendResult = await tools.forgeloop_orchestrate.execute("4", { mode: "recommend", after: "evt-0", limit: 9 });
const recommendPayload = parsePayload(recommendResult);
assert.equal(coordinationCalls, 1);
assert.equal(eventsCalls, 0);
assert.equal(recommendPayload.coordination_source, "service");
assert.equal(recommendPayload.status, "actionable");
assert.equal(recommendPayload.event_source, "events_api");
assert.equal(recommendPayload.cursor.next_after, "evt-3");
assert.match(recommendPayload.brief, /^Actionable: Queue the next rebuild pass/);
assert.equal(recommendPayload.timeline[0].kind, "daemon_decision");
assert.equal(recommendPayload.timeline[1].related_playbook_ids[0], "post_clear_pause_rebuild");
assert.equal(recommendPayload.summary.duplicate_events, 1);
assert.equal(recommendPayload.summary.recommendations, 1);
assert.deepEqual(recommendPayload.summary.playbooks, { total: 1, actionable: 1, blocked: 0, observe: 0 });
assert.equal(recommendPayload.recommendations[0].rule, "replan_after_clear_pause");
assert.equal(recommendPayload.playbooks[0].id, "post_clear_pause_rebuild");
assert.equal(recommendPayload.playbooks[0].steps[0].action, "replan");
assert.equal(recommendPayload.applied.result, "not_requested");

const absentPlaybookOverview = makeOverview();
globalThis.fetch = async (url) => {
  const parsed = new URL(String(url));
  if (parsed.pathname === "/api/overview") {
    return okJson({ data: absentPlaybookOverview });
  }
  if (parsed.pathname === "/api/coordination") {
    return okJson({
      data: makeCoordination({
        status: "idle",
        selected_playbook_id: "human_answer_recovery",
        cursor: { requested_after: "evt-0", next_after: "evt-3", cursor_found: true, truncated: false, reset_required: false },
        summary: {
          fetched_events: 3,
          unique_events: 3,
          duplicate_events: 0,
          actionable_events: 1,
          recommendations: 0,
          playbooks: { total: 0, actionable: 0, blocked: 0, observe: 0 }
        },
        recommendations: [],
        playbooks: [],
        warnings: ["selected_playbook_not_triggered"]
      })
    });
  }
  throw new Error(`Unexpected absent playbook fetch: ${url}`);
};

const absentPlaybookResult = await tools.forgeloop_orchestrate.execute("4b", {
  mode: "recommend",
  after: "evt-0",
  limit: 9,
  playbookId: "human_answer_recovery"
});
const absentPlaybookPayload = parsePayload(absentPlaybookResult);
assert.equal(absentPlaybookPayload.coordination_source, "service");
assert.equal(absentPlaybookPayload.selected_playbook_id, "human_answer_recovery");
assert.equal(absentPlaybookPayload.summary.recommendations, 0);
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
  if (parsed.pathname === "/api/coordination") {
    return okJson({
      data: makeCoordination({
        status: "blocked",
        selected_playbook_id: "human_answer_recovery",
        cursor: { requested_after: "evt-prev-blocked", next_after: "evt-blocked", cursor_found: true, truncated: false, reset_required: false },
        summary: {
          fetched_events: 1,
          unique_events: 1,
          duplicate_events: 0,
          actionable_events: 1,
          recommendations: 1,
          playbooks: { total: 1, actionable: 0, blocked: 1, observe: 0 }
        },
        recommendations: [
          {
            rule: "clear_pause_after_human_answer",
            action: "clear_pause",
            playbook_id: "human_answer_recovery",
            event_id: "evt-blocked",
            event_code: "operator_action",
            event_action: "answer_question",
            event_occurred_at: "2026-03-21T01:30:00Z",
            reason: "Question action answer_question landed while pause is still requested and no unanswered questions remain.",
            apply_eligible: false,
            blocked_by: ["unanswered_questions_remain"]
          }
        ],
        playbooks: [
          {
            id: "human_answer_recovery",
            title: "Resume after human answers land",
            goal: "Clear a stale pause once human answers have landed and no unanswered questions remain.",
            status: "blocked",
            reason: "Resume after human answers land is currently blocked by: unanswered questions remain.",
            evidence: [{ event_id: "evt-blocked", event_code: "operator_action", occurred_at: "2026-03-21T01:30:00Z", action: "answer_question" }],
            recommended_action: "clear_pause",
            apply_eligible: false,
            blocked_by: ["unanswered_questions_remain"],
            steps: [
              {
                kind: "control_action",
                title: "Clear the pause request",
                detail: "Clear pause so Forgeloop can resume normal operation after the human response is captured.",
                action: "clear_pause",
                apply_eligible: false,
                blocked_by: ["unanswered_questions_remain"]
              }
            ]
          }
        ]
      })
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
assert.equal(blockedPayload.coordination_source, "service");
assert.equal(blockedPayload.playbooks[0].status, "blocked");
assert.equal(blockedPayload.playbooks[0].recommended_action, "clear_pause");
assert.ok(blockedPayload.playbooks[0].blocked_by.includes("unanswered_questions_remain"));
assert.equal(blockedPayload.playbooks[0].steps[0].apply_eligible, false);

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
  if (parsed.pathname === "/api/coordination") {
    return okJson({
      data: makeCoordination({
        status: "observe",
        selected_playbook_id: "failure_stabilization",
        cursor: { requested_after: "evt-prev-observe", next_after: "evt-observe", cursor_found: true, truncated: false, reset_required: false },
        summary: {
          fetched_events: 1,
          unique_events: 1,
          duplicate_events: 0,
          actionable_events: 1,
          recommendations: 1,
          playbooks: { total: 1, actionable: 0, blocked: 0, observe: 1 }
        },
        recommendations: [
          {
            rule: "pause_after_failure_signal",
            action: "pause",
            playbook_id: "failure_stabilization",
            event_id: "evt-observe",
            event_code: "loop_failed",
            event_action: null,
            event_occurred_at: "2026-03-21T01:45:00Z",
            reason: "Failure signal loop_failed arrived while the runtime is still live.",
            apply_eligible: false,
            blocked_by: ["pause_already_requested", "runtime_already_blocked"]
          }
        ],
        playbooks: [
          {
            id: "failure_stabilization",
            title: "Stabilize after a failure signal",
            goal: "Pause the control plane after a fresh failure signal so the operator can review evidence before more work starts.",
            status: "observe",
            reason: "Stabilize after a failure signal is already satisfied or safely waiting: pause already requested, runtime already blocked.",
            evidence: [{ event_id: "evt-observe", event_code: "loop_failed", occurred_at: "2026-03-21T01:45:00Z", action: null }],
            recommended_action: null,
            apply_eligible: false,
            blocked_by: ["pause_already_requested", "runtime_already_blocked"],
            steps: [{ kind: "manual", title: "Inspect failure evidence", detail: "Review the latest failure artifacts." }]
          }
        ]
      })
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
assert.equal(observePayload.coordination_source, "service");
assert.equal(observePayload.playbooks[0].status, "observe");
assert.equal(observePayload.playbooks[0].recommended_action, null);
assert.equal(observePayload.playbooks[0].steps[0].kind, "manual");

let resetOverview = makeOverview({ events: [] });
globalThis.fetch = async (url) => {
  const parsed = new URL(String(url));
  if (parsed.pathname === "/api/overview") {
    return okJson({ data: resetOverview });
  }
  if (parsed.pathname === "/api/coordination") {
    return okJson({
      data: makeCoordination({
        status: "idle",
        cursor: { requested_after: "stale-cursor", next_after: "evt-9", cursor_found: false, truncated: false, reset_required: true },
        warnings: ["cursor_not_found_reset_required"]
      })
    });
  }
  throw new Error(`Unexpected reset fetch: ${url}`);
};

const resetResult = await tools.forgeloop_orchestrate.execute("5", { mode: "recommend", after: "stale-cursor", limit: 5 });
const resetPayload = parsePayload(resetResult);
assert.equal(resetPayload.coordination_source, "service");
assert.equal(resetPayload.cursor.next_after, "evt-9");
assert.equal(resetPayload.cursor.reset_required, true);
assert.ok(resetPayload.warnings.includes("cursor_not_found_reset_required"));

const { tools: legacyFallbackTools } = registerPlugin({ baseUrl: "http://127.0.0.1:4011" });
const fallbackOverview = makeOverview({
  runtime_state: { status: "running", mode: "build", surface: "service", branch: "main" },
  control_flags: { "pause_requested?": false, "replan_requested?": false },
  events: [
    { event_id: "evt-fallback", event_code: "loop_failed", occurred_at: "2026-03-21T02:00:00Z" }
  ]
});
globalThis.fetch = async (url) => {
  const parsed = new URL(String(url));
  if (parsed.pathname === "/api/schema") {
    return errorJson(404, "not_found");
  }
  if (parsed.pathname === "/api/overview") {
    return okJson({ data: fallbackOverview });
  }
  if (parsed.pathname === "/api/coordination") {
    return errorJson(404, "not_found");
  }
  if (parsed.pathname === "/api/events") {
    throw new Error("simulated events outage");
  }
  throw new Error(`Unexpected fallback fetch: ${url}`);
};

const fallbackResult = await legacyFallbackTools.forgeloop_orchestrate.execute("6", {
  mode: "recommend",
  after: "evt-base",
  limit: 4,
  playbookId: "failure_stabilization"
});
const fallbackPayload = parsePayload(fallbackResult);
assert.equal(fallbackPayload.coordination_source, "plugin_fallback");
assert.equal(fallbackPayload.event_source, "overview_fallback");
assert.ok(fallbackPayload.warnings.includes("events_api_unavailable"));
assert.ok(fallbackPayload.warnings.includes("cursor_reset_required_after_fallback"));
assert.equal(fallbackPayload.cursor.reset_required, true);
assert.equal(fallbackPayload.cursor.next_after, "evt-base");
assert.match(fallbackPayload.brief, /^Actionable: Stabilize after a failure signal|^Blocked: Stabilize after a failure signal|^Observe: Stabilize after a failure signal/);
assert.equal(fallbackPayload.timeline[0].kind, "failure_signal");
assert.equal(fallbackPayload.applied.result, "not_requested");
assert.equal(fallbackPayload.playbooks[0].id, "failure_stabilization");
assert.equal(fallbackPayload.playbooks[0].recommended_action, "pause");

let serviceApplyOverview = makeOverview({
  runtime_state: { status: "paused", mode: "build", surface: "service", branch: "main" },
  control_flags: { "pause_requested?": true, "replan_requested?": false },
  questions: [],
  babysitter: { "running?": false }
});
let serviceReplanCalls = 0;
let serviceCoordinationFetches = 0;
globalThis.fetch = async (url, options = {}) => {
  const parsed = new URL(String(url));
  if (parsed.pathname === "/api/overview") {
    return okJson({ data: serviceApplyOverview });
  }
  if (parsed.pathname === "/api/coordination") {
    serviceCoordinationFetches += 1;
    assert.equal(parsed.searchParams.get("playbook_id"), "post_clear_pause_rebuild");
    return okJson({
      data: makeCoordination({
        status: "actionable",
        selected_playbook_id: "post_clear_pause_rebuild",
        brief: "Actionable: Queue the next rebuild pass — Pause was cleared while the backlog still needs a build and no replan is currently queued.",
        timeline: [
          {
            event_id: "evt-clear",
            event_code: "operator_action",
            event_action: "clear_pause",
            occurred_at: "2026-03-21T03:01:00Z",
            kind: "operator_action",
            title: "Operator cleared pause",
            detail: null,
            surface: "service",
            related_playbook_ids: ["post_clear_pause_rebuild"]
          }
        ],
        cursor: { requested_after: "evt-prev", next_after: "evt-clear", cursor_found: true, truncated: false, reset_required: false },
        summary: {
          fetched_events: 2,
          unique_events: 2,
          duplicate_events: 0,
          actionable_events: 2,
          recommendations: 1,
          playbooks: { total: 1, actionable: 1, blocked: 0, observe: 0 }
        },
        recommendations: [
          {
            rule: "replan_after_clear_pause",
            action: "replan",
            playbook_id: "post_clear_pause_rebuild",
            event_id: "evt-clear",
            event_code: "operator_action",
            event_action: "clear_pause",
            event_occurred_at: "2026-03-21T03:01:00Z",
            reason: "Pause was cleared while the backlog still needs a build and no replan is currently queued.",
            apply_eligible: true,
            blocked_by: []
          }
        ],
        playbooks: [
          {
            id: "post_clear_pause_rebuild",
            title: "Queue the next rebuild pass",
            goal: "Request a new plan/build pass after pause is cleared when canonical backlog work is still pending.",
            status: "actionable",
            reason: "Pause was cleared while the backlog still needs a build and no replan is currently queued.",
            evidence: [{ event_id: "evt-clear", event_code: "operator_action", occurred_at: "2026-03-21T03:01:00Z", action: "clear_pause" }],
            recommended_action: "replan",
            apply_eligible: true,
            blocked_by: [],
            steps: [{ kind: "control_action", title: "Request replan", detail: "Queue one bounded replan.", action: "replan", apply_eligible: true, blocked_by: [] }]
          }
        ]
      })
    });
  }
  if (parsed.pathname === "/api/events") {
    throw new Error("service-backed apply should not hit /api/events");
  }
  if (parsed.pathname === "/api/control/replan") {
    serviceReplanCalls += 1;
    assert.deepEqual(JSON.parse(options.body), {});
    return okJson({ data: { action: "replan", ok: true } });
  }
  throw new Error(`Unexpected service apply fetch: ${url}`);
};

const targetedApplyResult = await tools.forgeloop_orchestrate.execute("7", {
  mode: "apply",
  after: "evt-prev",
  limit: 6,
  playbookId: "post_clear_pause_rebuild"
});
const targetedApplyPayload = parsePayload(targetedApplyResult);
assert.equal(serviceCoordinationFetches, 2);
assert.equal(serviceReplanCalls, 1);
assert.equal(targetedApplyPayload.coordination_source, "service");
assert.equal(targetedApplyPayload.selected_playbook_id, "post_clear_pause_rebuild");
assert.match(targetedApplyPayload.brief, /^Actionable: Queue the next rebuild pass/);
assert.equal(targetedApplyPayload.timeline[0].kind, "operator_action");
assert.equal(targetedApplyPayload.applied.attempted, true);
assert.equal(targetedApplyPayload.applied.action, "replan");
assert.equal(targetedApplyPayload.applied.result, "applied");
assert.equal(targetedApplyPayload.cursor.next_after, "evt-clear");

const { tools: legacyFallbackApplyTools } = registerPlugin({ baseUrl: "http://127.0.0.1:4012" });
let fallbackApplyOverview = makeOverview({
  runtime_state: { status: "paused", mode: "build", surface: "service", branch: "main" },
  control_flags: { "pause_requested?": true, "replan_requested?": false },
  questions: [],
  babysitter: { "running?": false }
});
let fallbackApplyReplanCalls = 0;
globalThis.fetch = async (url, options = {}) => {
  const parsed = new URL(String(url));
  if (parsed.pathname === "/api/schema") {
    return errorJson(404, "not_found");
  }
  if (parsed.pathname === "/api/overview") {
    return okJson({ data: fallbackApplyOverview });
  }
  if (parsed.pathname === "/api/coordination") {
    return errorJson(404, "not_found");
  }
  if (parsed.pathname === "/api/events") {
    return okJson({
      data: [
        { event_id: "evt-clear", event_code: "operator_action", occurred_at: "2026-03-21T03:01:00Z", action: "clear_pause" }
      ],
      meta: { latest_event_id: "evt-clear", returned_count: 1, limit: 6, "cursor_found?": true, "truncated?": false }
    });
  }
  if (parsed.pathname === "/api/control/replan") {
    fallbackApplyReplanCalls += 1;
    assert.deepEqual(JSON.parse(options.body), {});
    return okJson({ data: { action: "replan", ok: true } });
  }
  throw new Error(`Unexpected fallback apply fetch: ${url}`);
};

const fallbackApplyResult = await legacyFallbackApplyTools.forgeloop_orchestrate.execute("7b", {
  mode: "apply",
  after: "evt-prev-2",
  limit: 6,
  playbookId: "post_clear_pause_rebuild"
});
const fallbackApplyPayload = parsePayload(fallbackApplyResult);
assert.equal(fallbackApplyReplanCalls, 1);
assert.equal(fallbackApplyPayload.coordination_source, "plugin_fallback");
assert.equal(fallbackApplyPayload.applied.result, "applied");
assert.equal(fallbackApplyPayload.applied.action, "replan");

let mismatchedServiceReplanCalls = 0;
globalThis.fetch = async (url) => {
  const parsed = new URL(String(url));
  if (parsed.pathname === "/api/overview") {
    return okJson({ data: serviceApplyOverview });
  }
  if (parsed.pathname === "/api/coordination") {
    return okJson({
      data: makeCoordination({
        status: "actionable",
        selected_playbook_id: "human_answer_recovery",
        cursor: { requested_after: "evt-prev-mismatch", next_after: "evt-clear", cursor_found: true, truncated: false, reset_required: false },
        summary: {
          fetched_events: 1,
          unique_events: 1,
          duplicate_events: 0,
          actionable_events: 1,
          recommendations: 1,
          playbooks: { total: 1, actionable: 1, blocked: 0, observe: 0 }
        },
        recommendations: [
          {
            rule: "clear_pause_after_human_answer",
            action: "clear_pause",
            playbook_id: "human_answer_recovery",
            event_id: "evt-answer",
            event_code: "operator_action",
            event_action: "answer_question",
            event_occurred_at: "2026-03-21T03:00:00Z",
            reason: "Question action answer_question landed while pause is still requested and no unanswered questions remain.",
            apply_eligible: true,
            blocked_by: []
          }
        ],
        playbooks: [
          {
            id: "human_answer_recovery",
            title: "Resume after human answers land",
            goal: "Clear a stale pause once human answers have landed and no unanswered questions remain.",
            status: "actionable",
            reason: "Question action answer_question landed while pause is still requested and no unanswered questions remain.",
            evidence: [{ event_id: "evt-answer", event_code: "operator_action", occurred_at: "2026-03-21T03:00:00Z", action: "answer_question" }],
            recommended_action: "clear_pause",
            apply_eligible: true,
            blocked_by: [],
            steps: [{ kind: "control_action", title: "Clear the pause request", detail: "Clear pause.", action: "clear_pause", apply_eligible: true, blocked_by: [] }]
          }
        ]
      })
    });
  }
  if (parsed.pathname === "/api/control/replan") {
    mismatchedServiceReplanCalls += 1;
    return okJson({ data: { action: "replan", ok: true } });
  }
  throw new Error(`Unexpected mismatched service fetch: ${url}`);
};

const mismatchedServiceResult = await tools.forgeloop_orchestrate.execute("7c", {
  mode: "apply",
  after: "evt-prev-mismatch",
  limit: 6,
  playbookId: "post_clear_pause_rebuild"
});
const mismatchedServicePayload = parsePayload(mismatchedServiceResult);
assert.equal(mismatchedServiceReplanCalls, 0);
assert.equal(mismatchedServicePayload.coordination_source, "service");
assert.equal(mismatchedServicePayload.applied.result, "blocked");
assert.equal(mismatchedServicePayload.applied.reason, "service_coordination_playbook_mismatch");

let brokenServiceReplanCalls = 0;
let brokenServiceOverview = makeOverview({
  runtime_state: { status: "running", mode: "build", surface: "service", branch: "main" },
  control_flags: { "pause_requested?": false, "replan_requested?": false },
  questions: [],
  babysitter: { "running?": false }
});
globalThis.fetch = async (url) => {
  const parsed = new URL(String(url));
  if (parsed.pathname === "/api/overview") {
    return okJson({ data: brokenServiceOverview });
  }
  if (parsed.pathname === "/api/coordination") {
    return errorJson(500, "coordination_boom");
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
    brokenServiceReplanCalls += 1;
    return okJson({ data: { action: "replan", ok: true } });
  }
  throw new Error(`Unexpected broken service fetch: ${url}`);
};

const applyErrorResult = await tools.forgeloop_orchestrate.execute("7c", {
  mode: "apply",
  after: "evt-prev-3",
  limit: 6,
  playbookId: "post_clear_pause_rebuild"
});
const applyErrorPayload = parsePayload(applyErrorResult);
assert.equal(brokenServiceReplanCalls, 0);
assert.equal(applyErrorPayload.coordination_source, "plugin_fallback");
assert.ok(applyErrorPayload.warnings.includes("service_coordination_failed"));
assert.equal(applyErrorPayload.applied.attempted, false);
assert.equal(applyErrorPayload.applied.result, "blocked");
assert.equal(applyErrorPayload.applied.reason, "service_coordination_failed");

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
    coordination: overrides.coordination,
    slots: overrides.slots || { items: [], counts: { total: 0, active: 0, blocked: 0 }, limits: { read: 0, write: 0 } },
    babysitter: { "running?": false, ...(overrides.babysitter || {}) }
  };
}

function makeSchema(overrides = {}) {
  return {
    contract_name: "forgeloop_loopback",
    contract_version: 1,
    payload_versions: {
      overview: 1,
      events: 1,
      events_meta: 1,
      coordination: 1,
      tracker: 1,
      workflow_overview: 1,
      provider_health: 1,
      babysitter: 1,
      runtime_owner: 1,
      ownership: 1,
      slots: 1
    },
    endpoints: {
      overview: { path: "/api/overview" },
      events: { path: "/api/events" },
      coordination: { path: "/api/coordination", payload_version: 1 },
      questions: {
        path: "/api/questions",
        answer_path_template: "/api/questions/{question_id}/answer",
        resolve_path_template: "/api/questions/{question_id}/resolve"
      },
      workflows: {
        path: "/api/workflows",
        preflight_path_template: "/api/workflows/{workflow_name}/preflight",
        run_path_template: "/api/workflows/{workflow_name}/run"
      },
      control: {
        pause_path: "/api/control/pause",
        clear_pause_path: "/api/control/clear-pause",
        replan_path: "/api/control/replan",
        run_path: "/api/control/run"
      },
      slots: {
        path: "/api/slots",
        fetch_path_template: "/api/slots/{slot_id}",
        stop_path_template: "/api/slots/{slot_id}/stop"
      },
      babysitter: { stop_path: "/api/babysitter/stop" },
      stream: { path: "/api/stream", snapshot_event: "snapshot", data_event: "event" }
    },
    ...overrides
  };
}

function makeCoordination(overrides = {}) {
  return {
    schema_version: 1,
    status: "idle",
    selected_playbook_id: null,
    event_source: "events_api",
    brief: "Coordination is idle for the current bounded event window.",
    cursor: {
      requested_after: null,
      next_after: null,
      cursor_found: null,
      truncated: false,
      reset_required: false,
      ...(overrides.cursor || {})
    },
    summary: {
      fetched_events: 0,
      unique_events: 0,
      duplicate_events: 0,
      actionable_events: 0,
      recommendations: 0,
      playbooks: { total: 0, actionable: 0, blocked: 0, observe: 0 },
      ...(overrides.summary || {})
    },
    recommendations: overrides.recommendations || [],
    playbooks: overrides.playbooks || [],
    timeline: overrides.timeline || [],
    warnings: overrides.warnings || [],
    ...Object.fromEntries(Object.entries(overrides).filter(([key]) => !["cursor", "summary", "recommendations", "playbooks", "timeline", "warnings"].includes(key)))
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
      return JSON.stringify({
        ok: true,
        api: { name: "forgeloop_loopback", contract_version: 1, schema_path: "/api/schema" },
        ...body
      });
    }
  };
}

function errorJson(status, reason) {
  return {
    ok: false,
    status,
    statusText: reason,
    async text() {
      return JSON.stringify({
        ok: false,
        api: { name: "forgeloop_loopback", contract_version: 1, schema_path: "/api/schema" },
        error: { reason }
      });
    }
  };
}
NODE

echo "ok: openclaw plugin seam"
