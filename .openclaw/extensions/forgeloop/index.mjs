const DEFAULT_BASE_URL = "http://127.0.0.1:4010";
const DEFAULT_TIMEOUT_MS = 10_000;
const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 200;
const PLUGIN_ID = "forgeloop";
const ALLOWED_ORCHESTRATION_ACTIONS = new Set(["pause", "clear_pause", "replan"]);
const FAILURE_EVENT_CODES = new Set([
  "loop_failed",
  "babysitter_failed",
  "daemon_deploy_failed",
  "daemon_ingest_logs_failed"
]);
const ORCHESTRATION_RULES = [
  {
    id: "clear_pause_after_human_answer",
    action: "clear_pause",
    matches(event) {
      return eventCode(event) === "operator_action" && ["answer_question", "resolve_question"].includes(event?.action);
    },
    blockedBy(_event, overview) {
      const blocked = [];
      if (!pauseRequested(overview)) blocked.push("pause_not_requested");
      if (!runtimePausedOrAwaitingHuman(overview)) blocked.push("runtime_not_paused");
      if (awaitingQuestionCount(overview) > 0) blocked.push("unanswered_questions_remain");
      if (babysitterRunning(overview)) blocked.push("babysitter_running");
      return blocked;
    },
    reason(event) {
      return `Question action ${event.action} landed while pause is still requested and no unanswered questions remain.`;
    }
  },
  {
    id: "replan_after_clear_pause",
    action: "replan",
    matches(event) {
      return eventCode(event) === "operator_action" && event?.action === "clear_pause";
    },
    blockedBy(_event, overview) {
      const blocked = [];
      if (!needsBuild(overview)) blocked.push("backlog_not_ready");
      if (replanRequested(overview)) blocked.push("replan_already_requested");
      if (babysitterRunning(overview)) blocked.push("babysitter_running");
      if (runtimeStatus(overview) === "awaiting-human") blocked.push("awaiting_human");
      return blocked;
    },
    reason() {
      return "Pause was cleared while the backlog still needs a build and no replan is currently queued.";
    }
  },
  {
    id: "pause_after_failure_signal",
    action: "pause",
    matches(event) {
      return FAILURE_EVENT_CODES.has(eventCode(event));
    },
    blockedBy(_event, overview) {
      const blocked = [];
      if (pauseRequested(overview)) blocked.push("pause_already_requested");
      if (["paused", "awaiting-human"].includes(runtimeStatus(overview))) blocked.push("runtime_already_blocked");
      if (babysitterRunning(overview)) blocked.push("babysitter_running");
      return blocked;
    },
    reason(event) {
      return `Failure signal ${eventCode(event)} arrived while the runtime is still live.`;
    }
  }
];

export default {
  id: PLUGIN_ID,
  name: "Forgeloop",
  description: "Monitor and pilot a local Forgeloop control plane.",
  register(api) {
    api.registerTool(buildOverviewTool(api), { optional: true });
    api.registerTool(buildControlTool(api), { optional: true });
    api.registerTool(buildQuestionTool(api), { optional: true });
    api.registerTool(buildOrchestrationTool(api), { optional: true });
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
        limit: { type: "integer", minimum: 1, maximum: MAX_LIMIT, default: DEFAULT_LIMIT }
      }
    },
    async execute(_id, params = {}) {
      const limit = normalizeLimit(params.limit);
      const overviewPayload = await fetchOverview(api, limit);
      const data = overviewPayload?.data || {};
      const eventsWindow = await fetchEventsWindow(api, {
        limit,
        fallbackEvents: data.events || [],
        allowFallback: true
      });
      const runtime = data.runtime_state || {};
      const backlog = data.backlog || {};
      const questions = Array.isArray(data.questions) ? data.questions : [];
      const escalations = Array.isArray(data.escalations) ? data.escalations : [];
      const tracker = data.tracker || {};
      const trackerIssues = Array.isArray(tracker.issues) ? tracker.issues : [];
      const events = Array.isArray(eventsWindow.items) ? eventsWindow.items : [];
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
        ...events.slice(-Math.min(events.length, 5)).map((event) => `Event ${eventCode(event)} @ ${eventTimestamp(event) || "unknown"}`),
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
      const payload = await executeControlAction(api, action, params);
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

function buildOrchestrationTool(api) {
  return {
    name: "forgeloop_orchestrate",
    description: "Review canonical replayable Forgeloop events and optionally apply one bounded OpenClaw orchestration action.",
    parameters: {
      type: "object",
      additionalProperties: false,
      properties: {
        after: { type: "string" },
        limit: { type: "integer", minimum: 1, maximum: MAX_LIMIT, default: DEFAULT_LIMIT },
        mode: { type: "string", enum: ["recommend", "apply"], default: "recommend" }
      }
    },
    async execute(_id, params = {}) {
      const mode = params.mode === "apply" ? "apply" : "recommend";
      if (mode === "apply") {
        assertOrchestrationApplyAllowed(api);
      }

      const after = normalizeCursor(params.after);
      const limit = normalizeLimit(params.limit, normalizeLimit(pluginConfig(api).orchestrationDefaultLimit, DEFAULT_LIMIT));
      const overviewPayload = await fetchOverview(api, limit);
      const overview = overviewPayload?.data || {};
      const eventsWindow = await fetchEventsWindow(api, {
        after,
        limit,
        fallbackEvents: overview.events || [],
        allowFallback: true
      });
      const result = await executeOrchestration(api, {
        mode,
        after,
        limit,
        overview,
        eventsWindow
      });

      const text = [
        `Forgeloop orchestration: ${mode}`,
        `Service: ${serviceBaseUrl(api)}`,
        `Event source: ${result.event_source}`,
        `Cursor: requested=${result.cursor.requested_after || "none"} next=${result.cursor.next_after || "none"}`,
        `Recommendations: ${result.summary.recommendations}`,
        result.applied.attempted
          ? `Applied: ${result.applied.action || "none"} (${result.applied.result})`
          : `Applied: none (${result.applied.result})`,
        result.warnings.length ? `Warnings: ${result.warnings.join(", ")}` : "Warnings: none",
        "",
        JSON.stringify(result, null, 2)
      ].join("\n");

      return textResult(text);
    },
  };
}

async function executeOrchestration(api, { mode, after, limit, overview, eventsWindow }) {
  const warnings = [];
  const meta = normalizeEventsMeta(eventsWindow.meta);
  const deduped = dedupeEvents(eventsWindow.items);
  const unsafeFallback = eventsWindow.source === "overview_fallback";
  const nextAfter = unsafeFallback ? after : (meta.latest_event_id || latestEventId(deduped.unique) || null);
  const cursorFound = after ? meta.cursor_found : null;
  const replayTruncated = after ? meta.truncated : false;
  const resetRequired = Boolean(unsafeFallback || (after && (cursorFound === false || replayTruncated)));
  const actionableEvents = deduped.unique.filter(isPotentiallyActionableEvent);
  const recommendations = evaluateRecommendations(deduped.unique, overview);

  if (unsafeFallback) {
    warnings.push("events_api_unavailable");
    warnings.push("cursor_reset_required_after_fallback");
  }
  if (after && cursorFound === false) {
    warnings.push("cursor_not_found_reset_required");
  }
  if (after && replayTruncated) {
    warnings.push("replay_truncated_reset_required");
  }
  if (mode === "apply" && !after) {
    warnings.push("apply_requires_after_cursor");
  }

  const result = {
    mode,
    service: serviceBaseUrl(api),
    event_source: eventsWindow.source,
    cursor: {
      requested_after: after,
      next_after: nextAfter,
      cursor_found: cursorFound,
      truncated: after ? replayTruncated : meta.truncated,
      reset_required: resetRequired
    },
    summary: {
      fetched_events: deduped.total,
      unique_events: deduped.unique.length,
      duplicate_events: deduped.duplicates,
      actionable_events: actionableEvents.length,
      recommendations: recommendations.length
    },
    recommendations,
    applied: {
      attempted: false,
      action: null,
      result: mode === "apply" ? "skipped" : "not_requested",
      reason: mode === "apply" ? "no_apply_attempted" : null
    },
    warnings
  };

  if (mode !== "apply") {
    return result;
  }

  const applyBlockedReason = firstApplyBlocker({ after, eventsWindow, cursorFound, replayTruncated });
  if (applyBlockedReason) {
    result.applied.result = "blocked";
    result.applied.reason = applyBlockedReason;
    return result;
  }

  const candidate = firstApplyCandidate(recommendations);
  if (!candidate) {
    result.applied.result = recommendations.length > 0 ? "blocked" : "skipped";
    result.applied.reason = recommendations.length > 0 ? "no_apply_eligible_recommendation" : "no_recommendations";
    return result;
  }

  const freshOverviewPayload = await fetchOverview(api, limit);
  const freshOverview = freshOverviewPayload?.data || {};
  const rechecked = recheckRecommendation(candidate, freshOverview);
  if (!rechecked.apply_eligible) {
    result.applied.result = "blocked";
    result.applied.action = candidate.action;
    result.applied.reason = rechecked.blocked_by[0] || "state_changed";
    result.recommendations = replaceRecommendation(result.recommendations, rechecked);
    return result;
  }

  try {
    const payload = await executeControlAction(api, candidate.action, {});
    result.applied.attempted = true;
    result.applied.action = candidate.action;
    result.applied.response = payload?.data ?? payload;

    try {
      const latestOverviewPayload = await fetchOverview(api, limit);
      result.applied.result = "applied";
      result.applied.reason = null;
      result.applied.latest_overview = latestOverviewPayload?.data || {};
    } catch (error) {
      result.applied.result = "error";
      result.applied.reason = `post_apply_overview_failed:${error.message}`;
    }
  } catch (error) {
    result.applied.attempted = true;
    result.applied.action = candidate.action;
    result.applied.result = "error";
    result.applied.reason = error.message;
  }

  return result;
}

function firstApplyBlocker({ after, eventsWindow, cursorFound, replayTruncated }) {
  if (!after) return "apply_requires_after_cursor";
  if (eventsWindow.source === "overview_fallback") return "events_api_unavailable";
  if (cursorFound === false) return "cursor_not_found_reset_required";
  if (replayTruncated) return "replay_truncated_reset_required";
  return null;
}

function firstApplyCandidate(recommendations) {
  return recommendations.find(
    (recommendation) => recommendation.apply_eligible && ALLOWED_ORCHESTRATION_ACTIONS.has(recommendation.action)
  );
}

function replaceRecommendation(recommendations, updated) {
  return recommendations.map((recommendation) => recommendation.rule === updated.rule ? updated : recommendation);
}

function evaluateRecommendations(events, overview) {
  const newestFirst = [...events].reverse();
  const recommendations = [];

  for (const rule of ORCHESTRATION_RULES) {
    const event = newestFirst.find((entry) => rule.matches(entry));
    if (!event) continue;

    const blocked_by = rule.blockedBy(event, overview);
    recommendations.push({
      rule: rule.id,
      action: rule.action,
      event_id: event.event_id,
      event_code: eventCode(event),
      event_action: event?.action || null,
      reason: rule.reason(event, overview),
      apply_eligible: blocked_by.length === 0,
      blocked_by
    });
  }

  return recommendations;
}

function recheckRecommendation(recommendation, overview) {
  const rule = ORCHESTRATION_RULES.find((entry) => entry.id === recommendation.rule);
  if (!rule) return recommendation;
  const event = {
    event_id: recommendation.event_id,
    event_code: recommendation.event_code,
    action: recommendation.event_action
  };
  const blocked_by = rule.blockedBy(event, overview);
  return {
    ...recommendation,
    apply_eligible: blocked_by.length === 0,
    blocked_by
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

async function fetchOverview(api, limit) {
  return requestJson(api, `/api/overview?limit=${normalizeLimit(limit)}`);
}

async function fetchEventsWindow(api, { after, limit, fallbackEvents = [], allowFallback = true } = {}) {
  const normalizedAfter = normalizeCursor(after);
  const normalizedLimit = normalizeLimit(limit);
  const params = new URLSearchParams({ limit: String(normalizedLimit) });
  if (normalizedAfter) params.set("after", normalizedAfter);

  try {
    const payload = await requestJson(api, `/api/events?${params.toString()}`);
    return {
      source: "events_api",
      items: Array.isArray(payload?.data) ? payload.data : [],
      meta: payload?.meta || null,
      error: null
    };
  } catch (error) {
    if (!allowFallback) throw error;
    return {
      source: "overview_fallback",
      items: Array.isArray(fallbackEvents) ? fallbackEvents : [],
      meta: null,
      error
    };
  }
}

async function executeControlAction(api, action, params = {}) {
  switch (action) {
    case "pause":
      return requestJson(api, "/api/control/pause", { method: "POST", body: {} });
    case "clear_pause":
      return requestJson(api, "/api/control/clear-pause", { method: "POST", body: {} });
    case "replan":
      return requestJson(api, "/api/control/replan", { method: "POST", body: {} });
    case "plan":
    case "build":
      return requestJson(api, "/api/control/run", {
        method: "POST",
        body: compact({
          mode: action,
          branch: params.branch,
          surface: "openclaw"
        })
      });
    case "workflow_preflight":
    case "workflow_run": {
      if (!params.workflowName) {
        throw new Error("workflowName is required for workflow actions");
      }
      const workflowAction = action === "workflow_preflight" ? "preflight" : "run";
      return requestJson(api, `/api/workflows/${encodeURIComponent(params.workflowName)}/${workflowAction}`, {
        method: "POST",
        body: compact({
          branch: params.branch,
          surface: "openclaw"
        })
      });
    }
    case "stop":
      return requestJson(api, "/api/babysitter/stop", {
        method: "POST",
        body: { reason: params.stopReason || "pause" }
      });
    default:
      throw new Error(`Unsupported Forgeloop action: ${action}`);
  }
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

function assertOrchestrationApplyAllowed(api) {
  assertMutationsAllowed(api, "orchestration:apply");
  if (pluginConfig(api).allowOrchestrationApply !== true) {
    throw new Error("Forgeloop orchestration apply mode is disabled for this plugin config");
  }
}

function normalizeLimit(value, fallback = DEFAULT_LIMIT) {
  const parsed = Number(value ?? fallback);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return Math.min(Math.trunc(parsed), MAX_LIMIT);
}

function normalizeCursor(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed;
}

function normalizeEventsMeta(meta) {
  return {
    latest_event_id: normalizeCursor(meta?.latest_event_id) || null,
    returned_count: Number(meta?.returned_count || 0),
    limit: Number(meta?.limit || 0),
    cursor_found: nullableBoolean(meta?.["cursor_found?"] ?? meta?.cursor_found),
    truncated: nullableBoolean(meta?.["truncated?"] ?? meta?.truncated)
  };
}

function dedupeEvents(events) {
  const seen = new Set();
  const unique = [];
  let duplicates = 0;

  for (const event of Array.isArray(events) ? events : []) {
    const eventId = normalizeCursor(event?.event_id);
    if (!eventId) {
      unique.push(event);
      continue;
    }
    if (seen.has(eventId)) {
      duplicates += 1;
      continue;
    }
    seen.add(eventId);
    unique.push(event);
  }

  return {
    total: Array.isArray(events) ? events.length : 0,
    duplicates,
    unique
  };
}

function latestEventId(events) {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const eventId = normalizeCursor(events[index]?.event_id);
    if (eventId) return eventId;
  }
  return null;
}

function isPotentiallyActionableEvent(event) {
  if (!normalizeCursor(event?.event_id)) return false;
  return ORCHESTRATION_RULES.some((rule) => rule.matches(event));
}

function pendingCount(items) {
  return Array.isArray(items) ? items.length : 0;
}

function boolFlag(value) {
  return value ? "yes" : "no";
}

function nullableBoolean(value) {
  if (value === true || value === false) return value;
  if (value == null) return null;
  return Boolean(value);
}

function pauseRequested(overview) {
  return Boolean(overview?.control_flags?.["pause_requested?"] ?? overview?.control_flags?.pause_requested);
}

function replanRequested(overview) {
  return Boolean(overview?.control_flags?.["replan_requested?"] ?? overview?.control_flags?.replan_requested);
}

function runtimeStatus(overview) {
  return overview?.runtime_state?.status || "unknown";
}

function runtimePausedOrAwaitingHuman(overview) {
  return ["paused", "awaiting-human"].includes(runtimeStatus(overview));
}

function awaitingQuestionCount(overview) {
  const questions = Array.isArray(overview?.questions) ? overview.questions : [];
  return questions.filter((item) => item?.status_kind === "awaiting_response").length;
}

function babysitterRunning(overview) {
  return Boolean(overview?.babysitter?.["running?"] ?? overview?.babysitter?.running);
}

function needsBuild(overview) {
  return Boolean(overview?.backlog?.["needs_build?"] ?? overview?.backlog?.needs_build);
}

function eventCode(event) {
  return event?.event_code || event?.event_type || "event";
}

function eventTimestamp(event) {
  return event?.occurred_at || event?.recorded_at || null;
}

function compact(object) {
  return Object.fromEntries(Object.entries(object).filter(([, value]) => value !== undefined && value !== null && value !== ""));
}

function textResult(text) {
  return { content: [{ type: "text", text }] };
}
