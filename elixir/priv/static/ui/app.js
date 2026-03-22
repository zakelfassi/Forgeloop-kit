const STREAM_EVENT_LIMIT = 50;
const OVERVIEW_REFRESH_DEBOUNCE_MS = 250;

const state = {
  stream: null,
  hasSnapshot: false,
  snapshot: null,
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
  controlStatus: document.getElementById("control-status"),
  controlsBody: document.getElementById("controls-body"),
  runtimeBody: document.getElementById("runtime-body"),
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
  setConnectionState("loading", "Booting…");
  renderNotice();

  try {
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
  refs.controlsBody.addEventListener("click", handleControlClick);
  refs.workflowsBody.addEventListener("click", handleControlClick);
  refs.questionsBody.addEventListener("input", handleQuestionInput);
  refs.questionsBody.addEventListener("click", handleQuestionClick);
}

async function fetchOverview() {
  const response = await fetch("/api/overview?limit=50", { headers: { Accept: "application/json" } });

  if (!response.ok) {
    throw new Error(`overview request failed (${response.status})`);
  }

  const payload = await response.json();

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

  if (!response.ok || !payload || payload.ok !== true) {
    throw buildRequestError(response, payload);
  }

  return payload.data;
}

function buildRequestError(response, payload) {
  const error = new Error(
    payload && payload.error && payload.error.reason
      ? payload.error.reason.replaceAll("_", " ")
      : `request failed (${response.status})`
  );

  error.status = response.status;
  error.payload = payload;
  error.reason = payload && payload.error ? payload.error.reason : null;
  return error;
}

function connectStream() {
  if (state.stream) {
    state.stream.close();
  }

  const stream = new EventSource(`/api/stream?limit=${STREAM_EVENT_LIMIT}`);
  state.stream = stream;

  stream.addEventListener("snapshot", (event) => {
    try {
      const payload = JSON.parse(event.data);
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
  state.latestEventId = eventCursorFromSnapshot(snapshot);
  state.snapshot = snapshot;
  renderControls(snapshot);
  renderRuntime(snapshot.runtime_state, snapshot.babysitter, snapshot.control_flags);
  renderProviders(snapshot.provider_health);
  renderBacklog(snapshot.backlog);
  renderCoordination(snapshot.coordination);
  renderTracker(snapshot.tracker);
  renderWorkflows(snapshot.workflows || {});
  renderQuestions(snapshot.questions || []);
  renderEscalations(snapshot.escalations || []);
  renderEvents(snapshot.events || []);
  renderNotice();
}

function renderControls(snapshot) {
  const flags = snapshot.control_flags || {};
  const babysitter = snapshot.babysitter || {};
  const activeRun = babysitter.active_run || {};
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

  refs.controlsBody.className = "stack";
  refs.controlsBody.innerHTML = `
    <div class="control-overview">
      <div class="badges">
        ${badge(pauseRequested ? "pause requested" : "pause clear", pauseRequested ? "warn" : "good")}
        ${badge(replanRequested ? "replan queued" : "replan clear", replanRequested ? "purple" : "info")}
        ${badge(deployRequested ? "deploy queued" : "deploy clear", deployRequested ? "warn" : "info")}
        ${badge(ingestLogsRequested ? "ingest queued" : "ingest clear", ingestLogsRequested ? "purple" : "info")}
        ${badge(workflowTargetStatus, workflowRequested ? (workflowTargetValid ? "pink" : "bad") : "info")}
        ${badge(running ? "run active" : "idle", running ? "warn" : "good")}
        ${badge(runtimeSurface === "—" ? "surface idle" : `surface ${runtimeSurface}`, "info")}
      </div>
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
          ${controlButton("run-plan", "Run plan", { disabled: running || isPending("run") })}
          ${controlButton("run-build", "Run build", { disabled: running || isPending("run") })}
        </div>
        <p class="subtle-copy">Manual runs use <code>surface: "ui"</code> and still flow through the babysitter, worktree, and existing escalation chain.</p>
      </div>
    </div>
  `;
}

function renderRuntime(runtime, babysitter, controlFlags) {
  const runtimeStatus = runtime && runtime.status ? runtime.status : "idle";
  const babysitterRunning = Boolean(babysitter && babysitter["running?"]);
  const babysitterState = babysitterRunning ? "Babysitter active" : "Babysitter idle";
  const pauseRequested = Boolean(controlFlags && controlFlags["pause_requested?"]);
  refs.runtimeBrief.textContent = `Runtime: ${runtimeStatus}`;
  refs.canonicalBrief.textContent = `${babysitterState}. ${pauseRequested ? "[PAUSE] is present." : "[PAUSE] is clear."}`;

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
      </div>
      <h3>${escapeHtml(runtime.reason || "Runtime state recorded")}</h3>
      <p>Requested action: ${escapeHtml(runtime.requested_action || "—")}</p>
    </article>
  `;
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
  const counts = coordination.summary && coordination.summary.playbooks ? coordination.summary.playbooks : {};
  const cursor = coordination.cursor || {};
  const statusClass = coordinationStatusClass(coordination.status);
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

  if (!playbooks.length) {
    refs.coordinationBody.className = "stack empty";
    refs.coordinationBody.innerHTML = `${summaryCard}<p>No playbooks are currently triggered for the latest bounded event window.</p>`;
    return;
  }

  refs.coordinationBody.className = "stack";
  refs.coordinationBody.innerHTML = summaryCard + playbooks.map((playbook) => {
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
  }).join("");
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

function renderWorkflows(workflowOverview) {
  const workflows = workflowOverview && workflowOverview.workflows ? workflowOverview.workflows : [];
  const runtime = workflowOverview && workflowOverview.runtime_state ? workflowOverview.runtime_state : null;

  if (!workflows.length) {
    refs.workflowsBody.className = "stack empty";
    refs.workflowsBody.textContent = "No workflow packs are available yet.";
    return;
  }

  const babysitter = state.snapshot && state.snapshot.babysitter ? state.snapshot.babysitter : {};
  const running = Boolean(babysitter["running?"]);

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
          ${controlButton("workflow-preflight", "Preflight", { disabled: running || isPending(`workflow:${workflowName}:preflight`), workflowName })}
          ${controlButton("workflow-run", "Run", { disabled: running || isPending(`workflow:${workflowName}:run`), workflowName })}
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
      await postJson("/api/control/pause", {});
      await refreshOverview("Pause requested. The daemon will stay stopped until [PAUSE] is cleared.");
    });
    return;
  }

  if (action === "clear-pause") {
    await runAction("clear-pause", async () => {
      await postJson("/api/control/clear-pause", {});
      await refreshOverview("Pause cleared. Recovery will happen on the next daemon or loop cycle.");
    });
    return;
  }

  if (action === "replan") {
    await runAction("replan", async () => {
      await postJson("/api/control/replan", {});
      await refreshOverview("Replan requested. The next loop can consume [REPLAN].");
    });
    return;
  }

  if (action === "run-plan" || action === "run-build") {
    const mode = action === "run-plan" ? "plan" : "build";

    await runAction("run", async () => {
      await postJson("/api/control/run", { mode });
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
      await postJson(`/api/workflows/${encodeURIComponent(workflowName)}/${workflowAction}`, { surface: "ui" });
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
      await postJson(`/api/questions/${encodeURIComponent(id)}/answer`, {
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
      await postJson(`/api/questions/${encodeURIComponent(id)}/resolve`, body);

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
    const text = error.reason === "babysitter_already_running" || error.reason === "babysitter_unmanaged_active"
      ? (options.conflictText || "A run is already active.")
      : (error.message || String(error));
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
  return `<button class="${classes.join(" ")}" data-action="${escapeHtml(action)}"${workflowNameAttr} ${opts.disabled ? "disabled" : ""}>${escapeHtml(label)}</button>`;
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
