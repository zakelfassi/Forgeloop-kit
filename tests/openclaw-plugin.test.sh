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
assert.equal(manifest.id, "forgeloop");
assert.equal(manifest.configSchema.type, "object");

const plugin = (await import(pathToFileURL(path.join(pluginRoot, "index.mjs")).href)).default;
const registrations = [];
const api = {
  config: {
    plugins: {
      entries: {
        forgeloop: {
          config: {
            baseUrl: "http://127.0.0.1:4010",
            requestTimeoutMs: 5000,
            allowMutations: true
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

assert.deepEqual(
  registrations.map(({ tool }) => tool.name).sort(),
  ["forgeloop_control", "forgeloop_overview", "forgeloop_question"]
);
assert.ok(registrations.every(({ opts }) => opts?.optional === true));

const fetchCalls = [];
globalThis.fetch = async (url, options = {}) => {
  fetchCalls.push({ url: String(url), options });

  if (String(url).endsWith("/api/overview?limit=9")) {
    return okJson({
      data: {
        runtime_state: { status: "running", mode: "build", surface: "ui", branch: "main" },
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
          items: [{ id: "task-1" }]
        },
        control_flags: { "pause_requested?": false, "replan_requested?": true },
        tracker: { issues: [{ id: "plan:1" }, { id: "workflow:alpha" }] },
        questions: [{ id: "Q-1", status_kind: "awaiting_response" }],
        escalations: [{ id: "E-1" }],
        events: [{ event_type: "daemon_tick" }],
        workflows: { workflows: [{ entry: { name: "alpha" }, active_run: { workflow_name: "alpha", action: "run" }, history: { latest: { action: "run", outcome: "failed", finished_at: "2026-03-21T00:00:02Z" } } }] },
        babysitter: { "running?": false }
      }
    });
  }

  if (String(url).endsWith("/api/events?limit=9")) {
    return okJson({
      data: [
        { event_id: "evt-1", event_code: "daemon_tick", occurred_at: "2026-03-21T00:00:01Z" },
        { event_id: "evt-2", event_code: "operator_action", occurred_at: "2026-03-21T00:00:02Z", action: "replan_requested" }
      ],
      meta: { latest_event_id: "evt-2", returned_count: 2, limit: 9, "truncated?": false }
    });
  }

  if (String(url).endsWith("/api/control/run")) {
    return okJson({ data: { mode: "build", surface: "openclaw" } });
  }

  if (String(url).endsWith("/api/workflows/alpha/preflight")) {
    return okJson({ data: { lane: "workflow", action: "preflight", workflow: "alpha", surface: "openclaw" } });
  }

  if (String(url).endsWith("/api/questions")) {
    return okJson({ data: [{ id: "Q-1", revision: "rev-1" }] });
  }

  if (String(url).endsWith("/api/questions/Q-1/answer")) {
    return okJson({ data: { question: { id: "Q-1", revision: "rev-2", status_kind: "answered" } } });
  }

  throw new Error(`Unexpected fetch: ${url}`);
};

const overviewTool = registrations.find(({ tool }) => tool.name === "forgeloop_overview").tool;
const controlTool = registrations.find(({ tool }) => tool.name === "forgeloop_control").tool;
const questionTool = registrations.find(({ tool }) => tool.name === "forgeloop_question").tool;

const overviewResult = await overviewTool.execute("1", { limit: 9 });
assert.match(overviewResult.content[0].text, /Runtime: running \/ build via ui on main/);
assert.match(overviewResult.content[0].text, /Backlog: 1 pending items from IMPLEMENTATION_PLAN\.md/);
assert.match(overviewResult.content[0].text, /Tracker: 2 projected repo-local issues/);
assert.match(overviewResult.content[0].text, /Workflows: 1 discovered \(1 active, failed=1, escalated=0, start_failed=0\)/);
assert.match(overviewResult.content[0].text, /Workflow alpha: run failed @ 2026-03-21T00:00:02Z/);
assert.match(overviewResult.content[0].text, /Recent events: 2/);
assert.match(overviewResult.content[0].text, /Event daemon_tick @ 2026-03-21T00:00:01Z/);
assert.match(overviewResult.content[0].text, /Event operator_action @ 2026-03-21T00:00:02Z/);

const controlResult = await controlTool.execute("2", { action: "build" });
assert.match(controlResult.content[0].text, /surface\": \"openclaw\"/);
assert.equal(fetchCalls.find((entry) => entry.url.endsWith("/api/events?limit=9")).url, "http://127.0.0.1:4010/api/events?limit=9");
assert.equal(fetchCalls.find((entry) => entry.url.endsWith("/api/control/run")).url, "http://127.0.0.1:4010/api/control/run");
assert.deepEqual(
  JSON.parse(fetchCalls.find((entry) => entry.url.endsWith("/api/control/run")).options.body),
  { mode: "build", surface: "openclaw" }
);

const workflowControlResult = await controlTool.execute("2b", { action: "workflow_preflight", workflowName: "alpha" });
assert.match(workflowControlResult.content[0].text, /workflow\": \"alpha\"/);
assert.deepEqual(
  JSON.parse(fetchCalls.find((entry) => entry.url.endsWith("/api/workflows/alpha/preflight")).options.body),
  { surface: "openclaw" }
);

const questionResult = await questionTool.execute("3", { action: "answer", questionId: "Q-1", answer: "Proceed." });
assert.match(questionResult.content[0].text, /status_kind\": \"answered\"/);
assert.deepEqual(
  JSON.parse(fetchCalls.find((entry) => entry.url.endsWith("/api/questions/Q-1/answer")).options.body),
  { expected_revision: "rev-1", answer: "Proceed." }
);

const lockedApi = {
  ...api,
  config: {
    plugins: {
      entries: {
        forgeloop: {
          config: {
            baseUrl: "http://127.0.0.1:4010",
            allowMutations: false
          }
        }
      }
    }
  }
};
const lockedRegistrations = [];
lockedApi.registerTool = (tool, opts) => lockedRegistrations.push({ tool, opts });
plugin.register(lockedApi);

await assert.rejects(
  lockedRegistrations.find(({ tool }) => tool.name === "forgeloop_control").tool.execute("4", { action: "pause" }),
  /mutations are disabled/
);

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
