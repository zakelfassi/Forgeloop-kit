const DEFAULT_BASE_URL = "http://127.0.0.1:4010";
const DEFAULT_TIMEOUT_MS = 10_000;
const PLUGIN_ID = "forgeloop";

export default {
  id: PLUGIN_ID,
  name: "Forgeloop",
  description: "Monitor and pilot a local Forgeloop control plane.",
  register(api) {
    api.registerTool(buildOverviewTool(api), { optional: true });
    api.registerTool(buildControlTool(api), { optional: true });
    api.registerTool(buildQuestionTool(api), { optional: true });
  },
};

function buildOverviewTool(api) {
  return {
    name: "forgeloop_overview",
    description: "Read the current Forgeloop runtime/backlog/questions/escalations/babysitter snapshot from the loopback service.",
    parameters: {
      type: "object",
      additionalProperties: false,
      properties: {
        limit: { type: "integer", minimum: 1, maximum: 200, default: 20 }
      }
    },
    async execute(_id, params = {}) {
      const limit = normalizeLimit(params.limit);
      const payload = await requestJson(api, `/api/overview?limit=${limit}`);
      const data = payload?.data || {};
      const runtime = data.runtime_state || {};
      const backlog = data.backlog || {};
      const questions = Array.isArray(data.questions) ? data.questions : [];
      const escalations = Array.isArray(data.escalations) ? data.escalations : [];
      const tracker = data.tracker || {};
      const trackerIssues = Array.isArray(tracker.issues) ? tracker.issues : [];
      const events = Array.isArray(data.events) ? data.events : [];
      const workflows = data.workflows?.workflows || [];
      const activeWorkflowCount = workflows.filter((workflow) => workflow.active_run).length;
      const workflowOutcomeCounts = workflows.reduce((acc, workflow) => {
        const outcome = workflow.history?.latest?.outcome;
        if (outcome) acc[outcome] = (acc[outcome] || 0) + 1;
        return acc;
      }, {});
      const babysitter = data.babysitter || {};
      const flags = data.control_flags || {};
      const workflowTarget = flags.workflow_target || {};
      const workflowFlag = boolFlag(flags["workflow_requested?"] ?? flags.workflow_requested);
      const deployFlag = boolFlag(flags["deploy_requested?"] ?? flags.deploy_requested);
      const ingestFlag = boolFlag(flags["ingest_logs_requested?"] ?? flags.ingest_logs_requested);
      const workflowTargetValidity = workflowTarget["valid?"] === false ? `invalid:${workflowTarget.error || "config"}` : "valid";
      const workflowTargetLabel = workflowTarget.name ? `${workflowTarget.action || "preflight"} ${workflowTarget.name}` : "unconfigured";

      const backlogLabel = backlog.source?.label || "IMPLEMENTATION_PLAN.md";

      const text = [
        `Forgeloop overview (${serviceBaseUrl(api)})`,
        `Runtime: ${runtime.status || "unknown"} / ${runtime.mode || "unknown"} via ${runtime.surface || "unknown"} on ${runtime.branch || "unknown"}`,
        `Backlog: ${pendingCount(backlog.items)} pending items from ${backlogLabel} (needs_build=${Boolean(backlog["needs_build?"] ?? backlog.needs_build)})`,
        `Flags: pause=${boolFlag(flags["pause_requested?"] ?? flags.pause_requested)} replan=${boolFlag(flags["replan_requested?"] ?? flags.replan_requested)} deploy=${deployFlag} ingest=${ingestFlag} workflow=${workflowFlag} (${workflowTargetLabel}; ${workflowTargetValidity})`,
        `Questions: ${questions.length} total, ${questions.filter((item) => item.status_kind === "awaiting_response").length} awaiting response`,
        `Escalations: ${escalations.length}`,
        `Tracker: ${trackerIssues.length} projected repo-local issues`,
        `Babysitter: ${babysitter["running?"] ? `running ${babysitter.mode || "unknown"} as ${babysitter.runtime_surface || "unknown"}` : "idle"}`,
        `Workflows: ${workflows.length} discovered (${activeWorkflowCount} active, failed=${workflowOutcomeCounts.failed || 0}, escalated=${workflowOutcomeCounts.escalated || 0}, start_failed=${workflowOutcomeCounts.start_failed || 0})`,
        ...workflows.map((workflow) => {
          const latest = workflow.history?.latest;
          const latestText = latest
            ? `${latest.action || "run"} ${latest.outcome || "unknown"} @ ${latest.finished_at || latest.started_at || "unknown"}`
            : (workflow.latest_activity_kind ? `${workflow.latest_activity_kind} @ ${workflow.latest_activity_at || "unknown"}` : "no activity yet");
          return `Workflow ${workflow.entry?.name || "workflow"}: ${latestText}`;
        }),
        `Recent events: ${events.length}`,
        "",
        JSON.stringify(data, null, 2),
      ].join("\n");

      return textResult(text);
    },
  };
}

function buildControlTool(api) {
  return {
    name: "forgeloop_control",
    description: "Pause, clear pause, request replan, or start/stop manual Forgeloop runs through the loopback service.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: {
        action: {
          type: "string",
          enum: ["pause", "clear_pause", "replan", "plan", "build", "workflow_preflight", "workflow_run", "stop"]
        },
        workflowName: { type: "string" },
        branch: { type: "string" },
        stopReason: { type: "string", enum: ["pause", "kill"], default: "pause" }
      }
    },
    async execute(_id, params = {}) {
      assertMutationsAllowed(api, params.action);

      const action = params.action;
      let payload;

      switch (action) {
        case "pause":
          payload = await requestJson(api, "/api/control/pause", { method: "POST", body: {} });
          break;
        case "clear_pause":
          payload = await requestJson(api, "/api/control/clear-pause", { method: "POST", body: {} });
          break;
        case "replan":
          payload = await requestJson(api, "/api/control/replan", { method: "POST", body: {} });
          break;
        case "plan":
        case "build":
          payload = await requestJson(api, "/api/control/run", {
            method: "POST",
            body: compact({
              mode: action,
              branch: params.branch,
              surface: "openclaw"
            })
          });
          break;
        case "workflow_preflight":
        case "workflow_run": {
          if (!params.workflowName) {
            throw new Error("workflowName is required for workflow actions");
          }

          const workflowAction = action === "workflow_preflight" ? "preflight" : "run";
          payload = await requestJson(api, `/api/workflows/${encodeURIComponent(params.workflowName)}/${workflowAction}`, {
            method: "POST",
            body: compact({
              branch: params.branch,
              surface: "openclaw"
            })
          });
          break;
        }
        case "stop":
          payload = await requestJson(api, "/api/babysitter/stop", {
            method: "POST",
            body: { reason: params.stopReason || "pause" }
          });
          break;
        default:
          throw new Error(`Unsupported Forgeloop action: ${action}`);
      }

      const text = [
        `Forgeloop control action: ${action}`,
        `Service: ${serviceBaseUrl(api)}`,
        "",
        JSON.stringify(payload?.data ?? payload, null, 2)
      ].join("\n");

      return textResult(text);
    },
  };
}

function buildQuestionTool(api) {
  return {
    name: "forgeloop_question",
    description: "Answer or resolve a Forgeloop question using the canonical question revision from the loopback service.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["action", "questionId"],
      properties: {
        action: { type: "string", enum: ["answer", "resolve"] },
        questionId: { type: "string" },
        answer: { type: "string" },
        expectedRevision: { type: "string" }
      }
    },
    async execute(_id, params = {}) {
      assertMutationsAllowed(api, `question:${params.action || "unknown"}`);

      const questionId = params.questionId;
      const action = params.action;
      const revision = params.expectedRevision || await currentRevision(api, questionId);
      const body = compact({
        expected_revision: revision,
        answer: params.answer
      });

      const payload = await requestJson(
        api,
        `/api/questions/${encodeURIComponent(questionId)}/${action}`,
        { method: "POST", body }
      );

      const text = [
        `Forgeloop question ${action}: ${questionId}`,
        `Service: ${serviceBaseUrl(api)}`,
        "",
        JSON.stringify(payload?.data ?? payload, null, 2)
      ].join("\n");

      return textResult(text);
    },
  };
}

async function currentRevision(api, questionId) {
  const payload = await requestJson(api, "/api/questions");
  const questions = Array.isArray(payload?.data) ? payload.data : [];
  const question = questions.find((entry) => entry.id === questionId);

  if (!question?.revision) {
    throw new Error(`Could not resolve current revision for question ${questionId}`);
  }

  return question.revision;
}

async function requestJson(api, path, opts = {}) {
  const url = new URL(path, serviceBaseUrl(api));
  const timeoutMs = requestTimeout(api);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetch(url, {
      method: opts.method || "GET",
      headers: {
        Accept: "application/json",
        ...(opts.body ? { "Content-Type": "application/json" } : {})
      },
      body: opts.body ? JSON.stringify(opts.body) : undefined,
      signal: controller.signal
    });

    const text = await response.text();
    let payload = null;

    try {
      payload = text ? JSON.parse(text) : null;
    } catch (_error) {
      payload = null;
    }

    if (!response.ok || !payload?.ok) {
      const reason = payload?.error?.reason || payload?.error?.message || response.statusText || `HTTP ${response.status}`;
      throw new Error(`Forgeloop request failed (${response.status}): ${reason}`);
    }

    return payload;
  } finally {
    clearTimeout(timeout);
  }
}

function serviceBaseUrl(api) {
  const config = pluginConfig(api);
  return String(config.baseUrl || DEFAULT_BASE_URL).replace(/\/+$/, "") + "/";
}

function requestTimeout(api) {
  const config = pluginConfig(api);
  const value = Number(config.requestTimeoutMs || DEFAULT_TIMEOUT_MS);
  return Number.isFinite(value) && value >= 1000 ? value : DEFAULT_TIMEOUT_MS;
}

function pluginConfig(api) {
  return api?.config?.plugins?.entries?.[PLUGIN_ID]?.config || {};
}

function assertMutationsAllowed(api, action) {
  if (pluginConfig(api).allowMutations === false) {
    throw new Error(`Forgeloop mutations are disabled for this plugin config (blocked action: ${action})`);
  }
}

function normalizeLimit(value) {
  const parsed = Number(value ?? 20);
  if (!Number.isFinite(parsed) || parsed <= 0) return 20;
  return Math.min(Math.trunc(parsed), 200);
}

function pendingCount(items) {
  return Array.isArray(items) ? items.length : 0;
}

function boolFlag(value) {
  return value ? "yes" : "no";
}

function compact(object) {
  return Object.fromEntries(Object.entries(object).filter(([, value]) => value !== undefined && value !== null && value !== ""));
}

function textResult(text) {
  return { content: [{ type: "text", text }] };
}
