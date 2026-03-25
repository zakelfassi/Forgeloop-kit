const STREAM_EVENT_LIMIT = 50;
const OVERVIEW_REFRESH_DEBOUNCE_MS = 250;

const state = {
  stream: null,
  hasSnapshot: false,
  snapshot: null,
  contract: null,
  api: null,
  scene: "operator",
  latestEventId: null,
  refreshTimer: null,
  questionDrafts: {},
  questionDraftRevisions: {},
  questionErrors: {},
  pendingActions: {},
  notice: { kind: "info", text: "Loading operator controls…" }
};

const refs = {
  pill: document.getElementById("connection-pill"),
  runtimeBrief: document.getElementById("runtime-brief"),
  canonicalBrief: document.getElementById("canonical-brief"),
  sceneOperatorButton: document.getElementById("scene-operator"),
  sceneDirectorButton: document.getElementById("scene-director"),
  controlStatus: document.getElementById("control-status"),
  controlsBody: document.getElementById("controls-body"),
  directorNow: document.getElementById("director-now"),
  directorNext: document.getElementById("director-next"),
  directorQueue: document.getElementById("director-queue"),
  directorFeed: document.getElementById("director-feed"),
  runtimeBody: document.getElementById("runtime-body"),
  ownershipBody: document.getElementById("ownership-body"),
  providerBody: document.getElementById("provider-body"),
  backlogBody: document.getElementById("backlog-body"),
  coordinationBody: document.getElementById("coordination-body"),
  trackerBody: document.getElementById("tracker-body"),
  workflowsBody: document.getElementById("workflows-body"),
  questionsBody: document.getElementById("questions-body"),
  escalationsBody: document.getElementById("escalations-body"),
  eventsBody: document.getElementById("events-body")
};

boot();

async function boot() {
  bindEvents();
  hydrateScenePreference();
  renderSceneToggle();
  setConnectionState("loading", "Booting…");
  renderNotice();

  try {
    await fetchContract();
    const snapshot = await fetchOverview();
    applySnapshot(snapshot);
    state.hasSnapshot = true;
    setConnectionState("live", "Live stream connected");
    setNotice("info", "HUD ready. Manual runs flow through the babysitter and preserve canonical artifacts.");
  } catch (error) {
    renderFatal(error);
    setConnectionState("offline", "Bootstrap failed");
    setNotice("bad", error.message || String(error));
  }

  connectStream();
}

function bindEvents() {
  refs.sceneOperatorButton?.addEventListener("click", handleSceneClick);
  refs.sceneDirectorButton?.addEventListener("click", handleSceneClick);
  refs.controlsBody.addEventListener("click", handleControlClick);
  refs.workflowsBody.addEventListener("click", handleControlClick);
  refs.questionsBody.addEventListener("input", handleQuestionInput);
  refs.questionsBody.addEventListener("click", handleQuestionClick);
}

function hydrateScenePreference() {
  try {
    const saved = window.localStorage.getItem("forgeloop-hud-scene");
    if (saved === "director" || saved === "operator") {
      state.scene = saved;
    }
  } catch (_error) {
    state.scene = "operator";
  }

  document.body.dataset.scene = state.scene;
}

function handleSceneClick(event) {
  const button = event.currentTarget;
  const scene = button?.dataset?.scene;
  if (!scene || scene === state.scene) return;

  state.scene = scene;
  try {
    window.localStorage.setItem("forgeloop-hud-scene", scene);
  } catch (_error) {
    // ignore localStorage failures; scene state still applies for this session
  }

  document.body.dataset.scene = state.scene;
  renderSceneToggle();
  setNotice("info", scene === "director"
    ? "Director Mode enabled. The scene is still derived from the same loopback truth."
    : "Operator HUD enabled. Controls and proofs still target the same canonical state.");
}

function renderSceneToggle() {
  const operatorActive = state.scene !== "director";
  const directorActive = state.scene === "director";

  if (refs.sceneOperatorButton) {
    refs.sceneOperatorButton.classList.toggle("active", operatorActive);
    refs.sceneOperatorButton.setAttribute("aria-pressed", String(operatorActive));
  }

  if (refs.sceneDirectorButton) {
    refs.sceneDirectorButton.classList.toggle("active", directorActive);
    refs.sceneDirectorButton.setAttribute("aria-pressed", String(directorActive));
  }
}

async function fetchContract() {
  try {
    const response = await fetch("/api/schema", { headers: { Accept: "application/json" } });
    if (!response.ok) return null;

    const payload = await response.json();
    rememberApiMetadata(payload);

    if (!payload.ok || !payload.data || typeof payload.data !== "object") {
      return null;
    }

    state.contract = payload.data;
    return state.contract;
  } catch (_error) {
    return null;
  }
}

async function fetchOverview() {
  const response = await fetch(overviewPath(50), { headers: { Accept: "application/json" } });

  if (!response.ok) {
    throw new Error(`overview request failed (${response.status})`);
  }

  const payload = await response.json();
  rememberApiMetadata(payload);

  if (!payload.ok || !payload.data) {
    throw new Error("overview payload was not ok");
  }

  return payload.data;
}

async function refreshOverview(noticeText) {
  const snapshot = await fetchOverview();
  applySnapshot(snapshot);
  state.hasSnapshot = true;

  if (noticeText) {
    setNotice("good", noticeText);
  }

  return snapshot;
}

async function postJson(path, body) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify(body || {})
  });

  let payload = null;

  try {
    payload = await response.json();
  } catch (_error) {
    payload = null;
  }

  rememberApiMetadata(payload);

  if (!response.ok || !payload || payload.ok !== true) {
    throw buildRequestError(response, payload);
  }

  return payload.data;
}

function rememberApiMetadata(payload) {
  if (payload && payload.api && typeof payload.api === "object") {
    state.api = payload.api;
  }
}

function overviewPath(limit) {
  const path = endpointPath("overview") || "/api/overview";
  return `${path}?limit=${normalizeLimit(limit)}`;
}

function streamPath(limit) {
  const path = endpointPath("stream") || "/api/stream";
  return `${path}?limit=${normalizeLimit(limit)}`;
}

function controlPath(action) {
  const endpoint = endpointDescriptor("control") || {};

  switch (action) {
    case "pause":
      return endpoint.pause_path || "/api/control/pause";
    case "clear-pause":
      return endpoint.clear_pause_path || "/api/control/clear-pause";
    case "replan":
      return endpoint.replan_path || "/api/control/replan";
    case "run":
      return endpoint.run_path || "/api/control/run";
    default:
      return null;
  }
}

function workflowActionPath(workflowName, action) {
  const endpoint = endpointDescriptor("workflows") || {};
  const template = action === "preflight" ? endpoint.preflight_path_template : endpoint.run_path_template;
  return fillPathTemplate(template, { workflow_name: encodeURIComponent(workflowName) }) || `/api/workflows/${encodeURIComponent(workflowName)}/${action}`;
}

function questionActionPath(questionId, action) {
  const endpoint = endpointDescriptor("questions") || {};
  const template = action === "answer" ? endpoint.answer_path_template : endpoint.resolve_path_template;
  return fillPathTemplate(template, { question_id: encodeURIComponent(questionId) }) || `/api/questions/${encodeURIComponent(questionId)}/${action}`;
}

function endpointPath(name) {
  const endpoint = endpointDescriptor(name);
  return endpoint && typeof endpoint.path === "string" ? endpoint.path : null;
}

function endpointDescriptor(name) {
  return state.contract && state.contract.endpoints ? state.contract.endpoints[name] || null : null;
}

function fillPathTemplate(template, params) {
  if (typeof template !== "string" || !template) return null;
  return template.replace(/\{([^}]+)\}/g, (_match, key) => {
    const value = params[key];
    return value == null ? `{${key}}` : value;
  });
}

function normalizeLimit(value) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) return STREAM_EVENT_LIMIT;
  return Math.min(Math.trunc(parsed), 500);
}

function buildRequestError(response, payload) {
  const reason = payload && payload.error ? payload.error.reason : null;
  const ownership = ownershipErrorReason(reason) && payload && payload.error
    ? normalizeOwnershipPayload(payload.error.ownership)
    : null;
  const message = ownership && ownership.detail
    ? ownership.detail
    : reason
      ? reason.replaceAll("_", " ")
      : `request failed (${response.status})`;

  const error = new Error(message);
  error.status = response.status;
  error.payload = payload;
  error.reason = reason;
  error.ownership = ownership;
  return error;
}

function ownershipErrorReason(reason) {
  return [
    "babysitter_already_running",
    "babysitter_unmanaged_active",
    "active_runtime_owned_by",
    "active_runtime_state_error",
    "active_run_state_error"
  ].includes(reason);
}

function connectStream() {
  if (state.stream) {
    state.stream.close();
  }

  const stream = new EventSource(streamPath(STREAM_EVENT_LIMIT));
  state.stream = stream;

  stream.addEventListener("snapshot", (event) => {
    try {
      const payload = JSON.parse(event.data);
      rememberApiMetadata(payload);
      if (payload.ok && payload.data) {
        applySnapshot(payload.data);
        state.hasSnapshot = true;
        setConnectionState("live", "Live stream connected");
      }
    } catch (error) {
      console.error("failed to parse stream snapshot", error);
    }
  });

  stream.addEventListener("event", (event) => {
    try {
      const payload = JSON.parse(event.data);
      rememberApiMetadata(payload);
      if (payload.ok && payload.data) {
        applyLiveEvent(payload.data);
        state.hasSnapshot = true;
        setConnectionState("live", "Live stream connected");
      }
    } catch (error) {
      console.error("failed to parse stream event", error);
    }
  });

  stream.onerror = () => {
    setConnectionState(
      state.hasSnapshot ? "reconnecting" : "offline",
      state.hasSnapshot ? "Reconnecting…" : "Stream unavailable"
    );
  };
}

function applySnapshot(snapshot) {
  reconcileQuestionDrafts(snapshot.questions || []);
  const ownership = normalizeOwnership(snapshot);
  const normalizedSnapshot = { ...snapshot, ownership };
  state.latestEventId = eventCursorFromSnapshot(snapshot);
  state.snapshot = normalizedSnapshot;
  renderControls(normalizedSnapshot);
  renderDirectorMode(normalizedSnapshot);
  renderRuntime(normalizedSnapshot.runtime_state, normalizedSnapshot.babysitter, normalizedSnapshot.control_flags, ownership);
  renderOwnership(ownership);
  renderProviders(normalizedSnapshot.provider_health);
  renderBacklog(normalizedSnapshot.backlog);
  renderCoordination(normalizedSnapshot.coordination);
  renderTracker(normalizedSnapshot.tracker);
  renderWorkflows(normalizedSnapshot.workflows || {}, ownership);
  renderQuestions(normalizedSnapshot.questions || []);
  renderEscalations(normalizedSnapshot.escalations || []);
  renderEvents(normalizedSnapshot.events || []);
  renderNotice();
}

function renderControls(snapshot) {
  const flags = snapshot.control_flags || {};
  const babysitter = snapshot.babysitter || {};
  const activeRun = babysitter.active_run || {};
  const ownership = snapshot.ownership || normalizeOwnership(snapshot);
  const pauseRequested = Boolean(flags["pause_requested?"]);
  const replanRequested = Boolean(flags["replan_requested?"]);
  const deployRequested = Boolean(flags["deploy_requested?"]);
  const ingestLogsRequested = Boolean(flags["ingest_logs_requested?"]);
  const workflowRequested = Boolean(flags["workflow_requested?"]);
  const workflowTarget = flags.workflow_target || {};
  const workflowTargetValid = workflowTarget["valid?"] !== false;
  const workflowTargetLabel = workflowTarget.name ? `${workflowTarget.action || "preflight"} ${workflowTarget.name}` : "unconfigured";
  const workflowTargetStatus = workflowRequested ? (workflowTargetValid ? "workflow queued" : "workflow invalid") : "workflow clear";
  const running = Boolean(babysitter["running?"]);
  const runtimeSurface = babysitter.runtime_surface || activeRun.runtime_surface || "—";
  const manualStartBlocked = ownership.startAllowed === false;

  refs.controlsBody.className = "stack";
  refs.controlsBody.innerHTML = `
    <div class="control-overview">
      <div class="badges">
        ${badge(pauseRequested ? "pause requested" : "pause clear", pauseRequested ? "warn" : "good")}
        ${badge(replanRequested ? "replan queued" : "replan clear", replanRequested ? "purple" : "info")}
        ${badge(deployRequested ? "deploy queued" : "deploy clear", deployRequested ? "warn" : "info")}
        ${badge(ingestLogsRequested ? "ingest queued" : "ingest clear", ingestLogsRequested ? "purple" : "info")}
        ${badge(workflowTargetStatus, workflowRequested ? (workflowTargetValid ? "purple" : "bad") : "info")}
        ${badge(running ? "run active" : "idle", running ? "warn" : "good")}
        ${badge(runtimeSurface === "—" ? "surface idle" : `surface ${runtimeSurface}`, "info")}
        ${badge(`ownership ${ownership.summaryState}`, ownershipSummaryClass(ownership.summaryState))}
        ${badge(`start gate ${ownership.startGate.status}`, ownershipGateClass(ownership.startGate.status))}
      </div>
      <p class="subtle-copy">${escapeHtml(ownership.detail)}</p>
      <p class="subtle-copy">UI actions update the canonical files first. Clearing pause does not write <code>recovered</code>; that still happens on the next daemon or loop cycle.</p>
      <p class="subtle-copy">Daemon workflow request: <code>[WORKFLOW]</code> → <code>${escapeHtml(workflowTargetLabel)}</code>${workflowTarget.error ? ` (${escapeHtml(workflowTarget.error)})` : ""}. The managed public daemon honors this marker; <code>FORGELOOP_DAEMON_RUNTIME=bash</code> keeps the legacy bash path.</p>
    </div>
    <div class="control-grid">
      <div class="control-card">
        <h3>Interrupts</h3>
        <div class="control-buttons">
          ${controlButton("pause", "Request pause", { disabled: pauseRequested || isPending("pause") })}
          ${controlButton("clear-pause", "Clear pause", { disabled: !pauseRequested || isPending("clear-pause") })}
          ${controlButton("replan", "Request replan", { disabled: isPending("replan") })}
        </div>
      </div>
      <div class="control-card">
        <h3>One-off runs</h3>
        <div class="control-buttons">
          ${controlButton("run-plan", "Run plan", { disabled: manualStartBlocked || isPending("run") })}
          ${controlButton("run-build", "Run build", { disabled: manualStartBlocked || isPending("run") })}
        </div>
        <p class="subtle-copy">Manual runs use <code>surface: "ui"</code> and still flow through the babysitter, worktree, and existing escalation chain.</p>
      </div>
    </div>
  `;
}

function renderDirectorMode(snapshot) {
  if (!refs.directorNow || !refs.directorNext || !refs.directorQueue || !refs.directorFeed) {
    return;
  }

  const runtime = snapshot.runtime_state || {};
  const ownership = snapshot.ownership || normalizeOwnership(snapshot);
  const coordination = snapshot.coordination || {};
  const playbooks = Array.isArray(coordination.playbooks) ? coordination.playbooks : [];
  const backlogItems = Array.isArray(snapshot.backlog?.items) ? snapshot.backlog.items : [];
  const workflows = Array.isArray(snapshot.workflows?.workflows) ? snapshot.workflows.workflows : [];
  const questions = Array.isArray(snapshot.questions) ? snapshot.questions : [];
  const escalations = Array.isArray(snapshot.escalations) ? snapshot.escalations : [];
  const events = Array.isArray(snapshot.events) ? snapshot.events : [];
  const timeline = Array.isArray(coordination.timeline) ? coordination.timeline : [];
  const flags = snapshot.control_flags || {};
  const topPlaybook = playbooks.find((playbook) => playbook.status === "actionable") || playbooks[0] || null;
  const activeWorkflow = workflows.find((workflow) => workflow.active_run) || null;
  const nextBacklog = backlogItems[0] || null;
  const openQuestion = questions.find((question) => question.status_kind !== "resolved") || null;
  const latestEscalation = escalations[0] || null;
  const objective = directorObjective({ runtime, coordination, nextBacklog, openQuestion, activeWorkflow, latestEscalation });
  const stakes = directorStakes({ ownership, topPlaybook, openQuestion, latestEscalation });
  const nextMove = directorNextMove({ ownership, flags, topPlaybook, activeWorkflow, openQuestion, nextBacklog });
  const interventionPrompt = directorInterventionPrompt({ ownership, flags, topPlaybook, openQuestion, nextBacklog, latestEscalation });
  const queueCards = directorQueueCards({ backlogItems, activeWorkflow, questions, escalations });
  const feedCards = directorFeedCards({ timeline, events });

  refs.directorNow.className = "director-subgrid";
  refs.directorNow.innerHTML = `
    <article class="list-card director-summary">
      <div class="list-meta">
        ${badge(runtime.status || "idle", badgeClass(runtime.status || "idle"))}
        ${badge(`ownership ${ownership.summaryState}`, ownershipSummaryClass(ownership.summaryState))}
        ${badge(`start gate ${ownership.startGate.status}`, ownershipGateClass(ownership.startGate.status))}
        ${runtime.surface ? badge(runtime.surface, "purple") : ""}
      </div>
      <p class="eyebrow small">Current objective</p>
      <h3 class="director-objective">${escapeHtml(objective)}</h3>
      <p>${escapeHtml(runtime.reason || coordination.brief || "No runtime reason has been recorded yet.")}</p>
    </article>
    <article class="list-card director-highlight">
      <div class="list-meta">
        ${badge("stakes", stakes.kind)}
        ${ownership.conflict ? badge("conflict", "bad") : ""}
      </div>
      <h3>${escapeHtml(ownership.headline)}</h3>
      <p>${escapeHtml(stakes.detail)}</p>
      <div class="metric-grid compact-grid">
        ${metric("Status", runtime.status || "idle")}
        ${metric("Transition", runtime.transition || "—")}
        ${metric("Mode", runtime.mode || "—")}
        ${metric("Babysitter", snapshot.babysitter?.["running?"] ? "running" : "idle")}
      </div>
    </article>
  `;

  refs.directorNext.className = "director-subgrid";
  refs.directorNext.innerHTML = `
    <article class="list-card director-highlight">
      <div class="list-meta">
        ${badge(nextMove.kind_label, nextMove.kind)}
        ${nextMove.action ? badge(nextMove.action, nextMove.action_badge || "purple") : ""}
      </div>
      <h3>${escapeHtml(nextMove.title)}</h3>
      <p>${escapeHtml(nextMove.detail)}</p>
    </article>
    ${topPlaybook ? `
      <article class="list-card director-highlight">
        <div class="list-meta">
          ${badge(topPlaybook.status || "idle", coordinationStatusClass(topPlaybook.status))}
          ${topPlaybook.recommended_action ? badge(`recommend ${topPlaybook.recommended_action}`, topPlaybook.apply_eligible ? "good" : "warn") : badge("manual review", "info")}
        </div>
        <h3>${escapeHtml(topPlaybook.title || topPlaybook.id || "Top playbook")}</h3>
        <p>${escapeHtml(topPlaybook.goal || topPlaybook.reason || "No additional playbook summary is available.")}</p>
      </article>
    ` : `
      <article class="list-card director-highlight">
        <div class="list-meta">
          ${badge("playbooks idle", "info")}
        </div>
        <h3>No coordination playbook is currently active</h3>
        <p>The loopback service is not currently recommending an intervention beyond the canonical queue and runtime state.</p>
      </article>
    `}
    <article class="list-card director-highlight">
      <div class="list-meta">
        ${badge("human prompt", interventionPrompt.kind)}
        ${interventionPrompt.cue ? badge(interventionPrompt.cue, interventionPrompt.cue_kind || "purple") : ""}
      </div>
      <h3>${escapeHtml(interventionPrompt.title)}</h3>
      <p>${escapeHtml(interventionPrompt.detail)}</p>
    </article>
  `;

  refs.directorQueue.className = queueCards.length ? "director-queue-list" : "stack empty";
  refs.directorQueue.innerHTML = queueCards.length
    ? queueCards.join("")
    : "<p>No backlog, workflow, question, or escalation pressure is currently queued.</p>";

  refs.directorFeed.className = feedCards.length ? "director-feed-list" : "stack empty";
  refs.directorFeed.innerHTML = feedCards.length
    ? feedCards.join("")
    : "<p>No recent timeline or event signals are available yet.</p>";
}

function renderRuntime(runtime, babysitter, controlFlags, ownership) {
  const runtimeStatus = runtime && runtime.status ? runtime.status : "idle";
  const babysitterRunning = Boolean(babysitter && babysitter["running?"]);
  const babysitterState = babysitterRunning ? "Babysitter active" : "Babysitter idle";
  const pauseRequested = Boolean(controlFlags && controlFlags["pause_requested?"]);
  refs.runtimeBrief.textContent = `Runtime: ${runtimeStatus}`;
  refs.canonicalBrief.textContent = `${babysitterState}. ${pauseRequested ? "[PAUSE] is present." : "[PAUSE] is clear."} Start gate: ${ownership.summaryState}.`;

  if (!runtime) {
    refs.runtimeBody.className = "stack empty";
    refs.runtimeBody.textContent = "No runtime state yet.";
    return;
  }

  refs.runtimeBody.className = "stack";
  refs.runtimeBody.innerHTML = `
    <div class="metric-grid">
      ${metric("Status", runtime.status)}
      ${metric("Transition", runtime.transition || "—")}
      ${metric("Surface", runtime.surface || "—")}
      ${metric("Mode", runtime.mode || "—")}
      ${metric("Branch", runtime.branch || "—")}
      ${metric("Babysitter", babysitterRunning ? "running" : "idle")}
    </div>
    <article class="list-card">
      <div class="list-meta">
        ${badge(runtime.status || "idle", badgeClass(runtime.status))}
        ${badge(runtime.surface || "unknown", "info")}
        ${badge(`start gate ${ownership.startGate.status}`, ownershipGateClass(ownership.startGate.status))}
      </div>
      <h3>${escapeHtml(runtime.reason || "Runtime state recorded")}</h3>
      <p>Requested action: ${escapeHtml(runtime.requested_action || "—")}</p>
    </article>
  `;
}

function renderOwnership(ownership) {
  if (!ownership) {
    refs.ownershipBody.className = "stack empty";
    refs.ownershipBody.textContent = "No ownership snapshot yet.";
    return;
  }

  refs.ownershipBody.className = "stack";
  refs.ownershipBody.innerHTML = `
    <article class="list-card ownership-summary-card">
      <div class="list-meta">
        ${badge(`ownership ${ownership.summaryState}`, ownershipSummaryClass(ownership.summaryState))}
        ${badge(`start gate ${ownership.startGate.status}`, ownershipGateClass(ownership.startGate.status))}
        ${ownership.conflict ? badge("conflict", "bad") : badge("no live conflict", "good")}
        ${ownership.failClosed ? badge("fail closed", "bad") : badge("manual start ready", ownership.startAllowed ? "good" : "warn")}
      </div>
      <h3>${escapeHtml(ownership.headline)}</h3>
      <p>${escapeHtml(ownership.detail)}</p>
    </article>
    <article class="list-card ownership-card">
      <div class="list-meta">
        ${badge(`status ${ownership.startGate.status}`, ownershipGateClass(ownership.startGate.status))}
        ${ownership.startGate.reason ? badge(ownership.startGate.reason.replaceAll("_", " "), ownership.startGate.status === "error" ? "bad" : "warn") : badge("no blocker", "good")}
      </div>
      <h3>Start gate</h3>
      <div class="metric-grid compact-grid">
        ${metric("Allowed", yesNo(ownership.startAllowed))}
        ${metric("HTTP status", ownership.startGate.httpStatus || "—")}
        ${metric("Reclaim on start", yesNo(ownership.startGate.reclaimOnStart))}
        ${metric("Cleanup on start", yesNo(ownership.startGate.cleanupOnStart))}
      </div>
      ${ownership.startGate.details ? `<pre>${escapeHtml(JSON.stringify(ownership.startGate.details, null, 2))}</pre>` : ""}
    </article>
    <article class="list-card ownership-card">
      <div class="list-meta">
        ${badge(`owner ${ownership.runtimeOwner.state}`, ownershipSummaryClass(ownership.runtimeOwner.state === "reclaimable" ? "recoverable" : ownership.runtimeOwner.state))}
        ${ownership.runtimeOwner.claimId ? badge(ownership.runtimeOwner.claimId, "info") : ""}
      </div>
      <h3>Runtime owner</h3>
      <div class="metric-grid compact-grid">
        ${metric("State", ownership.runtimeOwner.state)}
        ${metric("Owner", ownership.runtimeOwner.owner || "—")}
        ${metric("Surface", ownership.runtimeOwner.surface || "—")}
        ${metric("Mode", ownership.runtimeOwner.mode || "—")}
        ${metric("Branch", ownership.runtimeOwner.branch || "—")}
        ${metric("Reclaimable", yesNo(ownership.runtimeOwner.reclaimable))}
      </div>
      <p>${escapeHtml(ownership.runtimeOwner.error || "No runtime-owner metadata error is currently recorded.")}</p>
    </article>
    <article class="list-card ownership-card">
      <div class="list-meta">
        ${badge(`active run ${ownership.activeRun.state}`, ownershipSummaryClass(ownership.activeRun.state === "stale" ? "recoverable" : ownership.activeRun.state))}
        ${ownership.activeRun.running ? badge("running", "warn") : badge("idle", "good")}
        ${ownership.activeRun.managed ? badge("managed", "purple") : badge("unmanaged", "info")}
      </div>
      <h3>Managed run metadata</h3>
      <div class="metric-grid compact-grid">
        ${metric("State", ownership.activeRun.state)}
        ${metric("Lane", ownership.activeRun.lane || "—")}
        ${metric("Action", ownership.activeRun.action || "—")}
        ${metric("Mode", ownership.activeRun.mode || "—")}
        ${metric("Workflow", ownership.activeRun.workflowName || "—")}
        ${metric("Surface", ownership.activeRun.runtimeSurface || "—")}
      </div>
      <p>${escapeHtml(ownership.activeRun.error || "No active-run metadata error is currently recorded.")}</p>
    </article>
  `;
}

function normalizeOwnership(snapshot) {
  if (snapshot && snapshot.ownership && snapshot.ownership.summaryState && snapshot.ownership.startGate) {
    return snapshot.ownership;
  }

  return normalizeOwnershipPayload(snapshot && snapshot.ownership)
    || deriveLegacyOwnership(snapshot || {});
}

function normalizeOwnershipPayload(payload) {
  if (!payload || typeof payload !== "object") return null;

  const startGate = payload.start_gate && typeof payload.start_gate === "object" ? payload.start_gate : {};
  const runtimeOwner = payload.runtime_owner && typeof payload.runtime_owner === "object" ? payload.runtime_owner : {};
  const activeRun = payload.active_run && typeof payload.active_run === "object" ? payload.active_run : {};

  return {
    summaryState: payload.summary_state || "ready",
    headline: payload.headline || "Manual starts are currently clear",
    detail: payload.detail || "No live ownership conflicts or malformed run metadata are blocking a manual start.",
    startAllowed: Boolean(payload["start_allowed?"] ?? payload.start_allowed ?? false),
    conflict: Boolean(payload["conflict?"] ?? payload.conflict),
    failClosed: Boolean(payload["fail_closed?"] ?? payload.fail_closed),
    startGate: {
      status: startGate.status || (payload["start_allowed?"] === false ? "blocked" : "allowed"),
      reason: startGate.reason || null,
      httpStatus: startGate.http_status ?? null,
      reclaimOnStart: Boolean(startGate["reclaim_on_start?"] ?? startGate.reclaim_on_start),
      cleanupOnStart: Boolean(startGate["cleanup_on_start?"] ?? startGate.cleanup_on_start),
      details: startGate.details || null
    },
    runtimeOwner: {
      state: runtimeOwner.state || "missing",
      owner: runtimeOwner.owner || null,
      surface: runtimeOwner.surface || null,
      mode: runtimeOwner.mode || null,
      branch: runtimeOwner.branch || null,
      claimId: runtimeOwner.claim_id || null,
      reclaimable: Boolean(runtimeOwner["reclaimable?"] ?? runtimeOwner.reclaimable),
      error: runtimeOwner.error || null
    },
    activeRun: {
      state: activeRun.state || "missing",
      managed: Boolean(activeRun["managed?"] ?? activeRun.managed),
      running: Boolean(activeRun["running?"] ?? activeRun.running),
      lane: activeRun.lane || null,
      action: activeRun.action || null,
      mode: activeRun.mode || null,
      workflowName: activeRun.workflow_name || null,
      branch: activeRun.branch || null,
      runtimeSurface: activeRun.runtime_surface || null,
      error: activeRun.error || null
    }
  };
}

function deriveLegacyOwnership(snapshot) {
  const runtimeOwner = snapshot && snapshot.runtime_owner ? snapshot.runtime_owner : {};
  const babysitter = snapshot && snapshot.babysitter ? snapshot.babysitter : {};
  const current = runtimeOwner.current || {};
  const activeRun = babysitter.active_run || {};
  const activeRunState = babysitter.active_run_state || "missing";
  const running = Boolean(babysitter["running?"]);
  const managed = Boolean(babysitter["managed?"]);
  const reclaimable = Boolean(runtimeOwner["reclaimable?"]);
  const runtimeState = runtimeOwner.state || "missing";
  let summaryState = "ready";
  let headline = "Manual starts are currently clear";
  let detail = "No live ownership conflicts or malformed run metadata are blocking a manual start.";
  let startGate = {
    status: "allowed",
    reason: null,
    httpStatus: null,
    reclaimOnStart: reclaimable,
    cleanupOnStart: activeRunState === "stale",
    details: null
  };
  let conflict = false;
  let failClosed = false;

  if (running && managed) {
    summaryState = "blocked";
    headline = "A managed babysitter run is already active";
    detail = "Wait for the active managed run to finish or stop it before launching another one.";
    startGate = { ...startGate, status: "blocked", reason: "babysitter_already_running", httpStatus: 409, reclaimOnStart: false, cleanupOnStart: false, details: activeRun };
    conflict = true;
  } else if (running) {
    summaryState = "blocked";
    headline = "Unmanaged active-run metadata is blocking new starts";
    detail = "Forgeloop sees active unmanaged run metadata and will not start another run automatically.";
    startGate = { ...startGate, status: "blocked", reason: "babysitter_unmanaged_active", httpStatus: 409, reclaimOnStart: false, cleanupOnStart: false, details: activeRun };
    conflict = true;
  } else if (runtimeState === "error") {
    summaryState = "error";
    headline = "Runtime ownership metadata is malformed";
    detail = "Starts fail closed until the active-runtime claim is repaired or removed.";
    startGate = { ...startGate, status: "error", reason: "active_runtime_state_error", httpStatus: 500, reclaimOnStart: false, cleanupOnStart: false };
    failClosed = true;
  } else if (activeRunState === "error") {
    summaryState = "error";
    headline = "Managed run metadata is malformed";
    detail = "Starts fail closed until the active-run metadata is repaired or removed.";
    startGate = { ...startGate, status: "error", reason: "active_run_state_error", httpStatus: 500, reclaimOnStart: false, cleanupOnStart: false };
    failClosed = true;
  } else if (Boolean(runtimeOwner["live?"]) && current && typeof current === "object") {
    summaryState = "blocked";
    headline = `Runtime ownership is currently held by ${current.owner || "another runtime"}`;
    detail = `A live ${(current.surface || "runtime")} ${(current.mode || "run")} still owns the claim${current.claim_id ? ` (${current.claim_id})` : ""}.`;
    startGate = { ...startGate, status: "blocked", reason: "active_runtime_owned_by", httpStatus: 409, reclaimOnStart: false, cleanupOnStart: false, details: current };
    conflict = true;
  } else if (reclaimable || activeRunState === "stale") {
    summaryState = "recoverable";
    headline = reclaimable && activeRunState === "stale"
      ? "A stale claim and stale managed-run metadata can be recovered"
      : reclaimable
        ? "A stale runtime claim can be reclaimed on the next start"
        : "Stale managed-run metadata will be cleaned before launch";
    detail = reclaimable && activeRunState === "stale"
      ? "The stale runtime claim can be reclaimed and the stale managed-run metadata will be cleaned before launch."
      : reclaimable
        ? "The stale runtime claim can be reclaimed on the next managed start."
        : "The stale managed-run metadata will be cleaned before launch.";
  }

  return {
    summaryState,
    headline,
    detail,
    startAllowed: startGate.status === "allowed",
    conflict,
    failClosed,
    startGate,
    runtimeOwner: {
      state: runtimeState,
      owner: current.owner || null,
      surface: current.surface || null,
      mode: current.mode || null,
      branch: current.branch || null,
      claimId: current.claim_id || null,
      reclaimable,
      error: runtimeOwner.error || null
    },
    activeRun: {
      state: activeRunState,
      managed,
      running,
      lane: babysitter.lane || activeRun.lane || null,
      action: babysitter.action || activeRun.action || null,
      mode: babysitter.mode || activeRun.mode || null,
      workflowName: babysitter.workflow_name || activeRun.workflow_name || null,
      branch: babysitter.branch || activeRun.branch || null,
      runtimeSurface: babysitter.runtime_surface || activeRun.runtime_surface || null,
      error: babysitter.active_run_error || null
    }
  };
}

function ownershipSummaryClass(status) {
  if (["ready"].includes(status)) return "good";
  if (["recoverable", "reclaimable", "stale", "active"].includes(status)) return "warn";
  if (["blocked", "error"].includes(status)) return "bad";
  return "info";
}

function ownershipGateClass(status) {
  if (status === "allowed") return "good";
  if (status === "blocked") return "warn";
  if (status === "error") return "bad";
  return "info";
}

function yesNo(value) {
  return value ? "yes" : "no";
}

function renderProviders(providerHealth) {
  const providers = providerHealth && providerHealth.providers ? providerHealth.providers : [];

  if (!providers.length) {
    refs.providerBody.className = "stack empty";
    refs.providerBody.textContent = "No provider health data yet.";
    return;
  }

  refs.providerBody.className = "provider-grid";
  refs.providerBody.innerHTML = providers.map((provider) => {
    const statusClass = badgeClass(provider.status);
    const failoverBadge = providerHealth.failover_enabled ? badge("failover on", "info") : badge("failover off", "warn");

    return `
      <article class="provider-card">
        <h3>${escapeHtml(provider.name)}</h3>
        <div class="badges">
          ${badge(String(provider.status || "unknown").replaceAll("_", " "), statusClass)}
          ${provider.disabled ? badge("disabled", "bad") : failoverBadge}
        </div>
        <div class="stack" style="margin-top: 12px">
          <p><span class="meta-label">Last attempt</span><br>${escapeHtml(provider.last_attempted_at || "Never")}</p>
          <p><span class="meta-label">Last failover</span><br>${escapeHtml(provider.last_failover_at || "None")}</p>
          <p><span class="meta-label">Failover reason</span><br>${escapeHtml(provider.last_failover_reason || "—")}</p>
          <p><span class="meta-label">Rate limit expires</span><br>${escapeHtml(provider.rate_limited_until_iso || "—")}</p>
        </div>
      </article>
    `;
  }).join("");
}

function renderBacklog(backlog) {
  const items = backlog && backlog.items ? backlog.items : [];
  const source = backlog && backlog.source ? backlog.source : {};
  const label = source.label || "IMPLEMENTATION_PLAN.md";
  const phase = source.phase || "phase1";
  const sourcePath = source.path || label;
  const introCard = `
    <article class="list-card">
      <div class="list-meta">
        ${badge("canonical", source["canonical?"] === false ? "warn" : "good")}
        ${badge(phase, "info")}
      </div>
      <h3>${escapeHtml(label)}</h3>
      <p>Resolved as the phase-1 self-hosting backlog from <code>${escapeHtml(sourcePath)}</code>.</p>
    </article>
  `;

  if (backlog && backlog["exists?"] === false) {
    refs.backlogBody.className = "stack empty";
    refs.backlogBody.innerHTML = `${introCard}<p>Canonical backlog file is missing, so the control plane fails closed and still reports pending work.</p>`;
    return;
  }

  if (!items.length) {
    refs.backlogBody.className = "stack empty";
    refs.backlogBody.innerHTML = `${introCard}<p>${backlog && backlog["needs_build?"] ? "Canonical backlog exists but no pending items were parsed." : "No pending items remain in the phase-1 canonical backlog."}</p>`;
    return;
  }

  refs.backlogBody.className = "stack";
  refs.backlogBody.innerHTML = `${introCard}${items.map((item) => `
    <article class="list-card">
      <div class="list-meta">
        ${badge(item.status || "pending", "good")}
        ${badge(item.section || "general", "purple")}
        ${badge(`line ${item.line_number}`, "info")}
      </div>
      <h3>${escapeHtml(item.text || item.raw_line || "Untitled item")}</h3>
    </article>
  `).join("")}`;
}

function renderCoordination(coordination) {
  if (!coordination) {
    refs.coordinationBody.className = "stack empty";
    refs.coordinationBody.textContent = "No coordination advisory has been derived yet.";
    return;
  }

  const warnings = Array.isArray(coordination.warnings) ? coordination.warnings : [];
  const playbooks = Array.isArray(coordination.playbooks) ? coordination.playbooks : [];
  const timeline = Array.isArray(coordination.timeline) ? coordination.timeline : [];
  const counts = coordination.summary && coordination.summary.playbooks ? coordination.summary.playbooks : {};
  const cursor = coordination.cursor || {};
  const statusClass = coordinationStatusClass(coordination.status);
  const brief = coordination.brief || "Coordination is idle for the current bounded event window.";
  const summaryCard = `
    <article class="list-card">
      <div class="list-meta">
        ${badge(`status ${coordination.status || "idle"}`, statusClass)}
        ${badge(`${counts.actionable || 0} actionable`, (counts.actionable || 0) > 0 ? "good" : "info")}
        ${badge(`${counts.blocked || 0} blocked`, (counts.blocked || 0) > 0 ? "bad" : "info")}
        ${badge(`${counts.observe || 0} observe`, (counts.observe || 0) > 0 ? "warn" : "info")}
      </div>
      <p class="subtle-copy">Shared read-only coordination derived by the loopback service from canonical runtime state, control flags, and replayable events. Apply any suggested action via the operator controls above or OpenClaw.</p>
      <div class="metric-grid compact-grid">
        ${metric("Event source", coordination.event_source || "events_api")}
        ${metric("Next cursor", cursor.next_after || "—")}
        ${metric("Requested cursor", cursor.requested_after || "—")}
        ${metric("Recommendations", String(coordination.summary?.recommendations || 0))}
      </div>
      ${warnings.length ? `<div class="badges">${warnings.map((warning) => badge(warning.replaceAll("_", " "), "warn")).join("")}</div>` : ""}
    </article>
  `;
  const briefCard = `
    <article class="list-card coordination-brief">
      <div class="list-meta">
        ${badge("operator brief", "purple")}
        ${badge(`${timeline.length} recent`, timeline.length ? "info" : "warn")}
      </div>
      <h3>Shared operator brief</h3>
      <p>${escapeHtml(brief)}</p>
    </article>
  `;
  const timelineCard = `
    <article class="list-card coordination-timeline">
      <div class="panel-head compact-head">
        <div>
          <h3>Recent coordination window</h3>
          <p class="subtle-copy">Derived from the same bounded event window used for playbooks, warnings, and OpenClaw safety checks.</p>
        </div>
      </div>
      ${timeline.length ? `<div class="stack">${timeline.map((entry) => `
        <article class="coordination-timeline-item">
          <div class="list-meta">
            ${badge((entry.kind || "event").replaceAll("_", " "), coordinationTimelineKindClass(entry.kind))}
            ${entry.surface ? badge(entry.surface, "info") : ""}
            ${(Array.isArray(entry.related_playbook_ids) ? entry.related_playbook_ids : []).map((playbookId) => badge(playbookId, "purple")).join("")}
          </div>
          <strong>${escapeHtml(entry.title || entry.event_code || "Coordination event")}</strong>
          <p class="subtle-copy">${escapeHtml(entry.detail || "No additional detail was recorded for this coordination event.")}</p>
          <span class="event-time">${escapeHtml(entry.occurred_at || "unknown")}</span>
        </article>
      `).join("")}</div>` : `<p>No coordination-relevant events were retained in the current bounded window.</p>`}
    </article>
  `;

  if (!playbooks.length) {
    refs.coordinationBody.className = "stack empty";
    refs.coordinationBody.innerHTML = `${summaryCard}${briefCard}${timelineCard}<p>No playbooks are currently triggered for the latest bounded event window.</p>`;
    return;
  }

  refs.coordinationBody.className = "stack";
  refs.coordinationBody.innerHTML = [
    summaryCard,
    briefCard,
    timelineCard,
    ...playbooks.map((playbook) => {
      const evidence = Array.isArray(playbook.evidence) ? playbook.evidence : [];
      const steps = Array.isArray(playbook.steps) ? playbook.steps : [];
      const blockedBy = Array.isArray(playbook.blocked_by) ? playbook.blocked_by : [];

      return `
        <article class="list-card coordination-card">
          <div class="panel-head compact-head">
            <div>
              <h3>${escapeHtml(playbook.title || playbook.id || "Playbook")}</h3>
              <p class="subtle-copy">${escapeHtml(playbook.goal || playbook.reason || "")}</p>
            </div>
            <div class="badges">
              ${badge(playbook.status || "idle", coordinationStatusClass(playbook.status))}
              ${playbook.recommended_action ? badge(`recommend ${playbook.recommended_action}`, playbook.apply_eligible ? "good" : "warn") : badge("manual review", "info")}
            </div>
          </div>
          <p>${escapeHtml(playbook.reason || "No coordination reason available.")}</p>
          ${blockedBy.length ? `<div class="badges">${blockedBy.map((reason) => badge(reason.replaceAll("_", " "), "bad")).join("")}</div>` : ""}
          ${evidence.length ? `<div class="stack">${evidence.map((item) => `
            <div class="coordination-evidence">
              <strong>${escapeHtml(item.event_code || "event")}</strong>
              <span class="subtle">${escapeHtml(item.occurred_at || "unknown")}</span>
              ${item.action ? `<span class="subtle">action=${escapeHtml(item.action)}</span>` : ""}
            </div>
          `).join("")}</div>` : ""}
          <div class="stack">
            ${steps.map((step) => `
              <article class="coordination-step">
                <div class="list-meta">
                  ${badge(step.kind || "step", step.kind === "control_action" ? "purple" : "info")}
                  ${step.action ? badge(step.action, step.apply_eligible ? "good" : "warn") : ""}
                </div>
                <strong>${escapeHtml(step.title || "Step")}</strong>
                <p class="subtle-copy">${escapeHtml(step.detail || "")}</p>
              </article>
            `).join("")}
          </div>
        </article>
      `;
    })
  ].join("");
}

function renderTracker(tracker) {
  const issues = tracker && tracker.issues ? tracker.issues : [];
  const counts = tracker && tracker.counts ? tracker.counts : {};
  const sources = tracker && tracker.sources ? tracker.sources : {};
  const backlogSource = sources.backlog || {};
  const workflowSource = sources.workflows || {};
  const summaryCard = `
    <article class="list-card">
      <div class="list-meta">
        ${badge(`${counts.total || 0} total`, "info")}
        ${badge(`${counts.backlog || 0} backlog`, "purple")}
        ${badge(`${counts.workflows || 0} workflows`, "good")}
      </div>
      <h3>Projected read-only tracker view</h3>
      <p>Derived from <code>${escapeHtml(backlogSource.label || "IMPLEMENTATION_PLAN.md")}</code> and <code>${escapeHtml(workflowSource.path || "workflows/")}</code> without changing the canonical files or mutating external trackers yet.</p>
    </article>
  `;

  if (!issues.length) {
    refs.trackerBody.className = "stack empty";
    refs.trackerBody.innerHTML = `${summaryCard}<p>No repo-local tracker issues are projected yet.</p>`;
    return;
  }

  refs.trackerBody.className = "stack";
  refs.trackerBody.innerHTML = `${summaryCard}${issues.map((issue) => `
    <article class="list-card">
      <div class="list-meta">
        ${badge(issue.state || "ready", badgeClass(issue.state || "ready"))}
        ${badge((issue.workflow_state || "issue").replaceAll("_", " "), issue.workflow_state === "workflow_pack" ? "good" : issue.workflow_state === "backlog_alert" ? "bad" : "purple")}
        ${badge(issue.identifier || issue.id || "repo-local", "info")}
      </div>
      <h3>${escapeHtml(issue.title || "Repo-local issue")}</h3>
      <p>${escapeHtml(issue.description || "Projected from canonical repo state.")}</p>
    </article>
  `).join("")}`;
}

function renderWorkflows(workflowOverview, ownershipOverride) {
  const workflows = workflowOverview && workflowOverview.workflows ? workflowOverview.workflows : [];
  const runtime = workflowOverview && workflowOverview.runtime_state ? workflowOverview.runtime_state : null;

  if (!workflows.length) {
    refs.workflowsBody.className = "stack empty";
    refs.workflowsBody.textContent = "No workflow packs are available yet.";
    return;
  }

  const babysitter = state.snapshot && state.snapshot.babysitter ? state.snapshot.babysitter : {};
  const running = Boolean(babysitter["running?"]);
  const ownership = ownershipOverride || (state.snapshot && state.snapshot.ownership) || normalizeOwnership(state.snapshot || {});
  const workflowStartBlocked = ownership.startAllowed === false;

  refs.workflowsBody.className = "stack";
  refs.workflowsBody.innerHTML = `${runtime ? `
    <article class="list-card">
      <div class="list-meta">
        ${badge(runtime.status || "running", badgeClass(runtime.status || "running"))}
        ${badge(runtime.mode || "workflow", "info")}
        ${badge(runtime.surface || "unknown", "purple")}
      </div>
      <h3>${escapeHtml(runtime.reason || "Workflow runtime is active")}</h3>
      <p>Workflow runtime state is driven by the same canonical runtime JSON used by the rest of the control plane.</p>
    </article>
  ` : ""}${workflows.map((workflow) => {
    const entry = workflow.entry || {};
    const preflight = workflow.preflight || {};
    const run = workflow.run || {};
    const history = workflow.history || {};
    const historyEntries = Array.isArray(history.entries) ? history.entries : [];
    const latestOutcome = history.latest || null;
    const activeRun = workflow.active_run || null;
    const workflowName = entry.name || "workflow";
    const activeBadge = activeRun ? badge(`active ${activeRun.action || "run"}`, "warn") : "";
    const latestLabel = latestOutcome
      ? `${latestOutcome.action || "run"} ${latestOutcome.outcome || "unknown"} @ ${latestOutcome.finished_at || latestOutcome.started_at || "unknown"}`
      : (workflow.latest_activity_kind ? `${workflow.latest_activity_kind} @ ${workflow.latest_activity_at || "unknown"}` : "no artifacts yet");
    const historyStatus = history.status || "missing";
    const historyBadge = latestOutcome
      ? badge(`latest ${latestOutcome.outcome || "unknown"}`, workflowOutcomeBadgeClass(latestOutcome.outcome))
      : badge(historyStatus === "error" ? "history error" : "no outcomes", historyStatus === "error" ? "bad" : "info");
    const historyMeta = historyStatus === "error"
      ? `<p class="subtle-copy">History error: ${escapeHtml(history.error || "unknown")}</p>`
      : historyStatus === "missing"
        ? `<p class="subtle-copy">No recorded workflow outcomes yet.</p>`
        : `<p class="subtle-copy">Recent outcomes: ${escapeHtml(String(history.returned_count || 0))} shown / ${escapeHtml(String(history.retained_count || 0))} retained.</p>`;
    const historyList = historyEntries.length
      ? `<ul>${historyEntries.map((item) => `<li><code>${escapeHtml(item.action || "run")}</code> → <strong>${escapeHtml(item.outcome || "unknown")}</strong> @ ${escapeHtml(item.finished_at || item.started_at || "unknown")}${item.runtime_surface ? ` via <code>${escapeHtml(item.runtime_surface)}</code>` : ""}</li>`).join("")}</ul>`
      : "";

    return `
      <article class="list-card workflow-card">
        <div class="list-meta">
          ${badge(workflowName, "info")}
          ${badge(preflight.status || "missing", badgeClass(preflight.status || "missing"))}
          ${badge(run.status || "missing", badgeClass(run.status || "missing"))}
          ${historyBadge}
          ${activeBadge}
        </div>
        <h3>${escapeHtml(workflowName)}</h3>
        <p>Graph: <code>${escapeHtml(entry.graph_file || "workflow.dot")}</code></p>
        <p>Latest activity: ${escapeHtml(latestLabel)}</p>
        ${activeRun ? `<p>Active via <code>${escapeHtml(activeRun.runtime_surface || "unknown")}</code> on <code>${escapeHtml(activeRun.branch || "unknown")}</code>${activeRun.run_id ? ` (<code>${escapeHtml(activeRun.run_id)}</code>)` : ""}.</p>` : ""}
        ${historyMeta}
        ${historyList}
        <div class="control-buttons">
          ${controlButton("workflow-preflight", "Preflight", { disabled: workflowStartBlocked || isPending(`workflow:${workflowName}:preflight`), workflowName })}
          ${controlButton("workflow-run", "Run", { disabled: workflowStartBlocked || isPending(`workflow:${workflowName}:run`), workflowName })}
        </div>
      </article>
    `;
  }).join("")}`;
}

function renderQuestions(questions) {
  if (!questions.length) {
    refs.questionsBody.className = "stack empty";
    refs.questionsBody.textContent = "No questions are open.";
    return;
  }

  refs.questionsBody.className = "stack";
  refs.questionsBody.innerHTML = questions.map((question) => {
    const id = question.id || "question";
    const draft = Object.prototype.hasOwnProperty.call(state.questionDrafts, id)
      ? state.questionDrafts[id]
      : (question.answer || "");
    const pendingAnswer = isPending(`answer:${id}`);
    const pendingResolve = isPending(`resolve:${id}`);
    const statusKind = question.status_kind || "awaiting_response";
    const resolved = statusKind === "resolved";
    const inlineError = state.questionErrors[id];

    return `
      <article class="list-card question-card">
        <div class="list-meta">
          ${badge(String(statusKind).replaceAll("_", " "), badgeClass(statusKind))}
          ${badge(id, "info")}
        </div>
        <h3>${escapeHtml(question.question || "Question")}</h3>
        <p>${escapeHtml(question.suggested_action || question.suggested_command || "Awaiting operator input.")}</p>
        <label class="question-label" for="draft-${escapeHtml(id)}">Answer draft</label>
        <textarea
          id="draft-${escapeHtml(id)}"
          class="question-input"
          data-question-id="${escapeHtml(id)}"
          rows="4"
          placeholder="Write the operator answer that should land in QUESTIONS.md"
          ${resolved ? "disabled" : ""}
        >${escapeHtml(draft)}</textarea>
        <div class="question-actions">
          <button class="control-button primary" data-action="answer-question" data-question-id="${escapeHtml(id)}" ${resolved || pendingAnswer ? "disabled" : ""}>${pendingAnswer ? "Answering…" : "Answer"}</button>
          <button class="control-button secondary" data-action="resolve-question" data-question-id="${escapeHtml(id)}" ${resolved || pendingResolve ? "disabled" : ""}>${pendingResolve ? "Resolving…" : "Resolve"}</button>
        </div>
        ${inlineError ? `<div class="notice bad inline-notice">${escapeHtml(inlineError)}</div>` : ""}
      </article>
    `;
  }).join("");
}

function renderEscalations(escalations) {
  if (!escalations.length) {
    refs.escalationsBody.className = "stack empty";
    refs.escalationsBody.textContent = "No escalation artifacts yet.";
    return;
  }

  refs.escalationsBody.className = "stack";
  refs.escalationsBody.innerHTML = escalations.map((escalation) => `
    <article class="list-card">
      <div class="list-meta">
        ${badge(escalation.kind || "escalation", "bad")}
        ${badge(`repeat ${escalation.repeat_count || 0}`, "warn")}
        ${badge(escalation.requested_action || "review", "purple")}
      </div>
      <h3>${escapeHtml(escalation.summary || escalation.id || "Escalation")}</h3>
      <p>${escapeHtml(escalation.host || "Repo-local artifact")}</p>
      ${escalation.draft ? `<pre>${escapeHtml(escalation.draft)}</pre>` : ""}
    </article>
  `).join("");
}

function renderEvents(events) {
  if (!events.length) {
    refs.eventsBody.className = "stack empty";
    refs.eventsBody.textContent = "No recent events.";
    return;
  }

  refs.eventsBody.className = "stack";
  refs.eventsBody.innerHTML = events.slice().reverse().map((event) => {
    const details = Object.entries(event)
      .filter(([key]) => !["event_id", "event_code", "event_type", "occurred_at", "recorded_at"].includes(key))
      .map(([key, value]) => `<div><span class="meta-label">${escapeHtml(key)}</span> <span class="subtle">${escapeHtml(formatValue(value))}</span></div>`)
      .join("");

    return `
      <article class="event-item">
        <div class="event-head">
          <strong>${escapeHtml(event.event_code || event.event_type || "event")}</strong>
          <span class="event-time">${escapeHtml(event.occurred_at || event.recorded_at || "unknown")}</span>
        </div>
        <div class="stack">${details || '<p>No extra payload.</p>'}</div>
      </article>
    `;
  }).join("");
}

function directorObjective(context) {
  const { runtime, nextBacklog, openQuestion, activeWorkflow, latestEscalation } = context;

  if (latestEscalation?.summary) return latestEscalation.summary;
  if (openQuestion?.question) return openQuestion.question;
  if (runtime?.reason) return runtime.reason;
  if (activeWorkflow?.entry?.name) return `${activeWorkflow.entry.name} is the current quest`;
  if (nextBacklog?.text) return nextBacklog.text;
  return "Keep the loop observable, bounded, and worth following.";
}

function directorStakes(context) {
  const { ownership, topPlaybook, openQuestion, latestEscalation } = context;

  if (latestEscalation) {
    return {
      kind: "bad",
      detail: latestEscalation.summary || "Forgeloop drafted an escalation artifact and needs a human decision now."
    };
  }

  if (openQuestion) {
    return {
      kind: "warn",
      detail: openQuestion.suggested_action || "A human gate is open and the loop will stay bounded until it is answered or resolved."
    };
  }

  if (ownership.startAllowed === false) {
    return {
      kind: ownership.failClosed ? "bad" : "warn",
      detail: ownership.detail || "Manual starts are currently blocked by ownership or active-run state."
    };
  }

  if (topPlaybook?.reason) {
    return {
      kind: topPlaybook.status === "blocked" ? "bad" : "purple",
      detail: topPlaybook.reason
    };
  }

  return {
    kind: "good",
    detail: "The control room is live, the start gate is clear, and there is no immediate fail-closed pressure."
  };
}

function directorNextMove(context) {
  const { ownership, flags, topPlaybook, activeWorkflow, openQuestion, nextBacklog } = context;

  if (ownership.startAllowed === false) {
    return {
      kind: ownership.failClosed ? "bad" : "warn",
      kind_label: "blocked",
      title: "Do not launch another run yet",
      detail: ownership.detail || "Resolve the ownership or active-run blocker before intervening.",
      action: ownership.startGate.reason || null,
      action_badge: ownership.failClosed ? "bad" : "warn"
    };
  }

  if (flags["pause_requested?"]) {
    return {
      kind: "warn",
      kind_label: "pause queued",
      title: "Hold while pause remains requested",
      detail: "The canonical control files still contain [PAUSE], so the next cycle should stay stopped until the operator clears it.",
      action: "pause",
      action_badge: "warn"
    };
  }

  if (topPlaybook?.recommended_action) {
    return {
      kind: topPlaybook.apply_eligible ? "good" : "warn",
      kind_label: "recommended",
      title: topPlaybook.title || "Follow the current playbook",
      detail: topPlaybook.goal || topPlaybook.reason || "The coordination layer has a concrete suggested next move.",
      action: topPlaybook.recommended_action,
      action_badge: topPlaybook.apply_eligible ? "good" : "warn"
    };
  }

  if (flags["replan_requested?"]) {
    return {
      kind: "purple",
      kind_label: "replan queued",
      title: "Let the next loop consume [REPLAN]",
      detail: "A replan has already been requested in the canonical control files.",
      action: "replan",
      action_badge: "purple"
    };
  }

  if (openQuestion) {
    return {
      kind: "warn",
      kind_label: "human gate",
      title: `Answer ${openQuestion.id || "the open question"}`,
      detail: openQuestion.suggested_action || "The loop is waiting on operator judgment before it can proceed safely.",
      action: "answer",
      action_badge: "warn"
    };
  }

  if (activeWorkflow?.entry?.name) {
    return {
      kind: "purple",
      kind_label: "workflow active",
      title: `Track ${activeWorkflow.entry.name}`,
      detail: "A managed workflow pack is already carrying the current momentum; the next move is mostly observation unless the run blocks.",
      action: activeWorkflow.active_run?.action || "run",
      action_badge: "purple"
    };
  }

  if (nextBacklog?.text) {
    return {
      kind: "good",
      kind_label: "queue front",
      title: "Advance the next canonical backlog item",
      detail: nextBacklog.text,
      action: nextBacklog.section || "backlog",
      action_badge: "good"
    };
  }

  return {
    kind: "info",
    kind_label: "observe",
    title: "Stay on watch",
    detail: "No stronger next move is currently derived from runtime, coordination, or queue state.",
    action: null,
    action_badge: "info"
  };
}

function directorInterventionPrompt(context) {
  const { ownership, flags, topPlaybook, openQuestion, nextBacklog, latestEscalation } = context;

  if (latestEscalation) {
    return {
      kind: "bad",
      title: "Pause the show and review the escalation",
      detail: latestEscalation.summary || "Forgeloop already drafted the handoff. The next useful human move is to inspect the escalation and decide how to resume.",
      cue: latestEscalation.requested_action || "escalation",
      cue_kind: "bad"
    };
  }

  if (openQuestion) {
    return {
      kind: "warn",
      title: "Answer the open human gate",
      detail: openQuestion.question || "The runtime is waiting on operator judgment. Resolve the question to unblock the next safe move.",
      cue: openQuestion.id || "question",
      cue_kind: "warn"
    };
  }

  if (ownership.startAllowed === false) {
    return {
      kind: ownership.failClosed ? "bad" : "warn",
      title: "Decide whether to wait, reclaim, or repair state",
      detail: ownership.detail || "The start gate is not clear, so the right human move is to inspect the blocker before launching anything new.",
      cue: ownership.startGate.reason || "start-gate",
      cue_kind: ownership.failClosed ? "bad" : "warn"
    };
  }

  if (flags["replan_requested?"]) {
    return {
      kind: "purple",
      title: "Watch the queue or reprioritize before the next cycle",
      detail: "A replan is already queued. This is the clean moment to decide whether the backlog order still makes sense.",
      cue: "replan",
      cue_kind: "purple"
    };
  }

  if (topPlaybook?.recommended_action) {
    return {
      kind: topPlaybook.apply_eligible ? "good" : "warn",
      title: "Decide whether to follow the recommended playbook",
      detail: topPlaybook.goal || topPlaybook.reason || "The coordination layer sees a concrete next move; the human can endorse it or keep observing.",
      cue: topPlaybook.recommended_action,
      cue_kind: topPlaybook.apply_eligible ? "good" : "warn"
    };
  }

  if (nextBacklog?.text) {
    return {
      kind: "info",
      title: "Reprioritize now if the queue feels wrong",
      detail: `Current queue front: ${nextBacklog.text}`,
      cue: nextBacklog.section || "backlog",
      cue_kind: "info"
    };
  }

  return {
    kind: "info",
    title: "Keep watching for the next real decision",
    detail: "There is no urgent operator intervention prompt right now. Let the loop stay observable and bounded until the next stronger signal arrives.",
    cue: "observe",
    cue_kind: "info"
  };
}

function directorQueueCards(context) {
  const { backlogItems, activeWorkflow, questions, escalations } = context;
  const cards = [];

  cards.push(`
    <article class="list-card director-queue-item">
      <div class="list-meta">
        ${badge("queue snapshot", "purple")}
        ${badge(`${backlogItems.length} backlog`, backlogItems.length ? "good" : "info")}
        ${badge(`${questions.length} questions`, questions.length ? "warn" : "info")}
        ${badge(`${escalations.length} escalations`, escalations.length ? "bad" : "info")}
      </div>
      <h3>What is stacking up behind the current objective</h3>
      <p>${escapeHtml(
        escalations.length
          ? "Human pressure is rising: the queue already contains escalation artifacts."
          : questions.length
            ? "The queue contains open human gates that can change what should happen next."
            : backlogItems.length
              ? "The canonical backlog is still the main source of what comes after the current beat."
              : "There is no visible queue pressure behind the active objective right now."
      )}</p>
    </article>
  `);

  const backlogPreview = backlogItems.slice(0, 3);
  if (backlogPreview.length) {
    cards.push(`
      <article class="list-card director-queue-item">
        <div class="list-meta">
          ${badge("backlog", "good")}
          ${badge(`${backlogItems.length} queued`, "info")}
        </div>
        <h3>Canonical backlog front</h3>
        <div class="stack">
          ${backlogPreview.map((item) => `<p>${escapeHtml(item.text || item.raw_line || "Untitled backlog item")}</p>`).join("")}
        </div>
      </article>
    `);
  }

  if (activeWorkflow) {
    const latest = activeWorkflow.latest_activity_kind
      ? `${activeWorkflow.latest_activity_kind} @ ${activeWorkflow.latest_activity_at || "unknown"}`
      : "No workflow artifact yet.";
    cards.push(`
      <article class="list-card director-queue-item">
        <div class="list-meta">
          ${badge("workflow", "purple")}
          ${activeWorkflow.active_run ? badge(`active ${activeWorkflow.active_run.action || "run"}`, "warn") : badge("idle", "info")}
        </div>
        <h3>${escapeHtml(activeWorkflow.entry?.name || "Workflow pack")}</h3>
        <p>${escapeHtml(latest)}</p>
      </article>
    `);
  }

  if (questions.length || escalations.length) {
    cards.push(`
      <article class="list-card director-queue-item">
        <div class="list-meta">
          ${badge(`${questions.length} questions`, questions.length ? "warn" : "info")}
          ${badge(`${escalations.length} escalations`, escalations.length ? "bad" : "info")}
        </div>
        <h3>Human pressure queue</h3>
        <p>${escapeHtml(
          escalations[0]?.summary
            || questions[0]?.question
            || "No active human gate is currently queued."
        )}</p>
      </article>
    `);
  }

  return cards;
}

function directorFeedCards(context) {
  const { timeline, events } = context;
  const cards = [];
  const recentTimeline = timeline.slice(0, 3);
  const recentEvents = events.slice().reverse().slice(0, 4);

  if (recentTimeline.length) {
    cards.push(`
      <article class="list-card director-feed-item">
        <div class="list-meta">
          ${badge("coordination", "purple")}
          ${badge(`${recentTimeline.length} recent`, "info")}
        </div>
        <h3>Recent coordination window</h3>
        <div class="stack">
          ${recentTimeline.map((entry) => `
            <div>
              <strong>${escapeHtml(entry.title || entry.event_code || "Coordination event")}</strong>
              <p class="subtle-copy">${escapeHtml(entry.detail || "No additional detail recorded.")}</p>
              <span class="event-time">${escapeHtml(entry.occurred_at || "unknown")}</span>
            </div>
          `).join("")}
        </div>
      </article>
    `);
  }

  if (recentEvents.length) {
    cards.push(`
      <article class="list-card director-feed-item">
        <div class="list-meta">
          ${badge("events", "info")}
          ${badge(`${recentEvents.length} replayed`, "good")}
        </div>
        <h3>Latest replayable signals</h3>
        <div class="stack">
          ${recentEvents.map((event) => `
            <div>
              <strong>${escapeHtml(event.event_code || event.event_type || "event")}</strong>
              <p class="subtle-copy">${escapeHtml(directorEventSummary(event))}</p>
              <span class="event-time">${escapeHtml(event.occurred_at || event.recorded_at || "unknown")}</span>
            </div>
          `).join("")}
        </div>
      </article>
    `);
  }

  return cards;
}

function directorEventSummary(event) {
  if (event.reason) return event.reason;
  if (event.action) return `action=${event.action}`;
  if (event.mode) return `mode=${event.mode}`;
  if (event.runtime_surface) return `surface=${event.runtime_surface}`;

  const extra = Object.entries(event)
    .filter(([key, value]) => value != null && !["event_id", "event_code", "event_type", "occurred_at", "recorded_at"].includes(key))
    .slice(0, 2)
    .map(([key, value]) => `${key}=${formatValue(value)}`)
    .join(" · ");

  return extra || "No extra payload.";
}

function renderNotice() {
  refs.controlStatus.className = `notice ${state.notice.kind}`;
  refs.controlStatus.innerHTML = escapeHtml(state.notice.text);
}

function renderFatal(error) {
  refs.runtimeBody.className = "stack empty";
  refs.runtimeBody.innerHTML = `<article class="list-card"><h3>UI bootstrap failed</h3><p>${escapeHtml(error.message || String(error))}</p></article>`;
}

async function handleControlClick(event) {
  const button = event.target.closest("button[data-action]");
  if (!button) return;

  const action = button.dataset.action;

  if (action === "pause") {
    await runAction("pause", async () => {
      await postJson(controlPath("pause"), {});
      await refreshOverview("Pause requested. The daemon will stay stopped until [PAUSE] is cleared.");
    });
    return;
  }

  if (action === "clear-pause") {
    await runAction("clear-pause", async () => {
      await postJson(controlPath("clear-pause"), {});
      await refreshOverview("Pause cleared. Recovery will happen on the next daemon or loop cycle.");
    });
    return;
  }

  if (action === "replan") {
    await runAction("replan", async () => {
      await postJson(controlPath("replan"), {});
      await refreshOverview("Replan requested. The next loop can consume [REPLAN].");
    });
    return;
  }

  if (action === "run-plan" || action === "run-build") {
    const mode = action === "run-plan" ? "plan" : "build";

    await runAction("run", async () => {
      await postJson(controlPath("run"), { mode });
      await refreshOverview(`${mode} run launched via UI surface.`);
    }, {
      conflictText: "A babysitter run is already active. Wait for it to finish before launching another one."
    });
    return;
  }

  if (action === "workflow-preflight" || action === "workflow-run") {
    const workflowName = button.dataset.workflowName;
    const workflowAction = action === "workflow-preflight" ? "preflight" : "run";
    const pendingKey = `workflow:${workflowName}:${workflowAction}`;

    await runAction(pendingKey, async () => {
      await postJson(workflowActionPath(workflowName, workflowAction), { surface: "ui" });
      await refreshOverview(`${workflowName} ${workflowAction} launched via UI surface.`);
    }, {
      conflictText: "A babysitter run is already active. Wait for it to finish before launching another workflow action."
    });
  }
}

function applyLiveEvent(event) {
  if (!event || !state.snapshot) {
    scheduleOverviewRefresh();
    return;
  }

  const currentEvents = Array.isArray(state.snapshot.events) ? state.snapshot.events : [];
  const mergedEvents = mergeLiveEvent(currentEvents, event, STREAM_EVENT_LIMIT);

  state.latestEventId = event.event_id || state.latestEventId;
  state.snapshot = {
    ...state.snapshot,
    events: mergedEvents,
    events_meta: {
      ...(state.snapshot.events_meta || {}),
      latest_event_id: state.latestEventId,
      returned_count: mergedEvents.length,
      limit: STREAM_EVENT_LIMIT,
      "truncated?": (state.snapshot.events_meta && state.snapshot.events_meta["truncated?"]) || false
    }
  };

  renderEvents(mergedEvents);
  scheduleOverviewRefresh();
}

function mergeLiveEvent(events, incomingEvent, limit) {
  const eventId = incomingEvent && incomingEvent.event_id;
  const withoutDuplicate = eventId ? events.filter((event) => event.event_id !== eventId) : events.slice();
  return withoutDuplicate.concat([incomingEvent]).slice(-limit);
}

function scheduleOverviewRefresh() {
  if (state.refreshTimer) {
    clearTimeout(state.refreshTimer);
  }

  state.refreshTimer = setTimeout(async () => {
    state.refreshTimer = null;

    try {
      await refreshOverview();
    } catch (error) {
      console.error("failed to refresh overview after live event", error);
    }
  }, OVERVIEW_REFRESH_DEBOUNCE_MS);
}

function eventCursorFromSnapshot(snapshot) {
  const metaCursor = snapshot && snapshot.events_meta ? snapshot.events_meta.latest_event_id : null;
  if (metaCursor) return metaCursor;

  const events = snapshot && Array.isArray(snapshot.events) ? snapshot.events : [];
  const latest = events[events.length - 1];
  return latest ? latest.event_id || null : null;
}

function handleQuestionInput(event) {
  const input = event.target.closest("textarea[data-question-id]");
  if (!input) return;

  const id = input.dataset.questionId;
  const question = findQuestion(id);
  state.questionDrafts[id] = input.value;
  state.questionDraftRevisions[id] = question ? question.revision : null;
  delete state.questionErrors[id];
}

async function handleQuestionClick(event) {
  const button = event.target.closest("button[data-question-id][data-action]");
  if (!button) return;

  const id = button.dataset.questionId;
  const question = findQuestion(id);
  if (!question) return;

  const action = button.dataset.action;
  const draft = getQuestionDraft(question);

  if (action === "answer-question") {
    if (!draft.trim()) {
      state.questionErrors[id] = "Answer cannot be blank.";
      renderQuestions(state.snapshot.questions || []);
      return;
    }

    await runQuestionAction(id, `answer:${id}`, async () => {
      await postJson(questionActionPath(id, "answer"), {
        answer: draft,
        expected_revision: question.revision
      });

      try {
        await refreshOverview(`Answered ${id}. Recovery stays deferred to the next daemon or loop cycle.`);
        clearQuestionDraft(id);
      } catch (_refreshError) {
        setNotice("warn", `${id} was answered, but the immediate refresh failed. Keeping your draft until the stream catches up.`);
      }
    });
    return;
  }

  if (action === "resolve-question") {
    const body = { expected_revision: question.revision };
    if (draft.trim()) {
      body.answer = draft;
    }

    await runQuestionAction(id, `resolve:${id}`, async () => {
      await postJson(questionActionPath(id, "resolve"), body);

      try {
        await refreshOverview(`Resolved ${id}. Canonical files updated; no fake recovery was written.`);
        clearQuestionDraft(id);
      } catch (_refreshError) {
        setNotice("warn", `${id} was resolved, but the immediate refresh failed. Keeping your draft until the stream catches up.`);
      }
    });
  }
}

async function runAction(key, fn, opts) {
  const options = opts || {};
  setPending(key, true);

  try {
    await fn();
  } catch (error) {
    const ownershipText = error.ownership && error.ownership.detail ? error.ownership.detail : null;
    const text = ownershipText || (error.reason === "babysitter_already_running" || error.reason === "babysitter_unmanaged_active"
      ? (options.conflictText || "A run is already active.")
      : (error.message || String(error)));
    setNotice("bad", text);
  } finally {
    setPending(key, false);
    if (state.snapshot) {
      renderControls(state.snapshot);
      renderWorkflows(state.snapshot.workflows || {});
    }
  }
}

async function runQuestionAction(id, key, fn) {
  setPending(key, true);
  delete state.questionErrors[id];

  try {
    await fn();
  } catch (error) {
    if (error.reason === "question_conflict") {
      state.questionErrors[id] = "Question changed on disk. Review the refreshed revision and resubmit.";
      try {
        await refreshOverview(`${id} changed on disk; HUD refreshed to the latest revision.`);
      } catch (_refreshError) {
        setNotice("warn", `${id} changed on disk. Refresh failed, but your draft was kept locally.`);
      }
    } else {
      state.questionErrors[id] = error.message || String(error);
      setNotice("bad", state.questionErrors[id]);
      renderQuestions(state.snapshot.questions || []);
    }
  } finally {
    setPending(key, false);
    if (state.snapshot) {
      renderQuestions(state.snapshot.questions || []);
    }
  }
}

function findQuestion(id) {
  const questions = state.snapshot && state.snapshot.questions ? state.snapshot.questions : [];
  return questions.find((question) => question.id === id);
}

function reconcileQuestionDrafts(questions) {
  const liveIds = new Set(questions.map((question) => question.id));

  Object.keys(state.questionDrafts).forEach((id) => {
    if (!liveIds.has(id)) {
      clearQuestionDraft(id);
      delete state.questionErrors[id];
    }
  });

  questions.forEach((question) => {
    const id = question.id;
    if (!Object.prototype.hasOwnProperty.call(state.questionDrafts, id)) return;

    const draftRevision = state.questionDraftRevisions[id];
    if (draftRevision == null || draftRevision === question.revision) return;

    clearQuestionDraft(id);
    if (question.status_kind !== "resolved") {
      state.questionErrors[id] = "Canonical question state changed on disk. Local draft was cleared.";
    }
  });
}

function clearQuestionDraft(id) {
  delete state.questionDrafts[id];
  delete state.questionDraftRevisions[id];
  delete state.questionErrors[id];
}

function getQuestionDraft(question) {
  if (Object.prototype.hasOwnProperty.call(state.questionDrafts, question.id)) {
    return state.questionDrafts[question.id];
  }

  return question.answer || "";
}

function setPending(key, pending) {
  if (pending) {
    state.pendingActions[key] = true;
  } else {
    delete state.pendingActions[key];
  }
}

function isPending(key) {
  return Boolean(state.pendingActions[key]);
}

function setNotice(kind, text) {
  state.notice = { kind, text };
  renderNotice();
}

function controlButton(action, label, options) {
  const opts = options || {};
  const classes = ["control-button"];
  if (action === "pause") classes.push("danger");
  if (action === "clear-pause") classes.push("secondary");
  if (action === "replan") classes.push("secondary");
  if (["run-plan", "run-build", "workflow-preflight", "workflow-run"].includes(action)) classes.push("primary");

  const workflowNameAttr = opts.workflowName ? ` data-workflow-name="${escapeHtml(opts.workflowName)}"` : "";
  const idAttr = controlButtonId(action, opts);
  return `<button class="${classes.join(" ")}"${idAttr} data-action="${escapeHtml(action)}"${workflowNameAttr} ${opts.disabled ? "disabled" : ""}>${escapeHtml(label)}</button>`;
}

function controlButtonId(action, options) {
  const opts = options || {};

  if (opts.workflowName) {
    const workflowAction = action === "workflow-preflight" ? "preflight" : action === "workflow-run" ? "run" : action;
    return ` id="workflow-${sanitizeButtonIdSegment(opts.workflowName)}-${sanitizeButtonIdSegment(workflowAction)}"`;
  }

  return ` id="control-${sanitizeButtonIdSegment(action)}"`;
}

function sanitizeButtonIdSegment(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "") || "unknown";
}

function metric(label, value) {
  return `
    <article class="metric">
      <span class="metric-label">${escapeHtml(label)}</span>
      <span class="metric-value">${escapeHtml(value || "—")}</span>
    </article>
  `;
}

function badge(label, kind) {
  return `<span class="badge ${kind}">${escapeHtml(label)}</span>`;
}

function badgeClass(kind) {
  if (["available", "pending", "answered", "resolved", "idle", "running", "completed"].includes(kind)) return "good";
  if (["awaiting-response", "awaiting_response", "awaiting-human", "awaiting_human", "auth_failed", "rate_limited", "paused", "recovered", "stopping"].includes(kind)) return "warn";
  if (["disabled", "blocked", "spin", "failed", "error"].includes(kind)) return "bad";
  return "info";
}

function coordinationStatusClass(status) {
  if (status === "actionable") return "good";
  if (status === "blocked") return "bad";
  if (status === "observe") return "warn";
  return "info";
}

function coordinationTimelineKindClass(kind) {
  if (kind === "operator_action") return "purple";
  if (kind === "daemon_decision") return "info";
  if (kind === "failure_signal") return "bad";
  return "warn";
}

function workflowOutcomeBadgeClass(outcome) {
  if (outcome === "succeeded") return "good";
  if (["failed", "escalated", "start_failed"].includes(outcome)) return "bad";
  if (outcome === "stopped") return "warn";
  return "info";
}

function formatValue(value) {
  if (value == null) return "—";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

function setConnectionState(kind, label) {
  refs.pill.dataset.state = kind;
  refs.pill.textContent = label;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
