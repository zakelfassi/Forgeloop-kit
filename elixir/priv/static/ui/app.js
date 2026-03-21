const state = {
  stream: null,
  hasSnapshot: false,
  snapshot: null,
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

  const stream = new EventSource("/api/stream?limit=50");
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

  stream.onerror = () => {
    setConnectionState(
      state.hasSnapshot ? "reconnecting" : "offline",
      state.hasSnapshot ? "Reconnecting…" : "Stream unavailable"
    );
  };
}

function applySnapshot(snapshot) {
  reconcileQuestionDrafts(snapshot.questions || []);
  state.snapshot = snapshot;
  renderControls(snapshot);
  renderRuntime(snapshot.runtime_state, snapshot.babysitter, snapshot.control_flags);
  renderProviders(snapshot.provider_health);
  renderBacklog(snapshot.backlog);
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
  const running = Boolean(babysitter["running?"]);
  const runtimeSurface = babysitter.runtime_surface || activeRun.runtime_surface || "—";

  refs.controlsBody.className = "stack";
  refs.controlsBody.innerHTML = `
    <div class="control-overview">
      <div class="badges">
        ${badge(pauseRequested ? "pause requested" : "pause clear", pauseRequested ? "warn" : "good")}
        ${badge(replanRequested ? "replan queued" : "replan clear", replanRequested ? "purple" : "info")}
        ${badge(running ? "run active" : "idle", running ? "warn" : "good")}
        ${badge(runtimeSurface === "—" ? "surface idle" : `surface ${runtimeSurface}`, "info")}
      </div>
      <p class="subtle-copy">UI actions update the canonical files first. Clearing pause does not write <code>recovered</code>; that still happens on the next daemon or loop cycle.</p>
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

  if (!items.length) {
    refs.backlogBody.className = "stack empty";
    refs.backlogBody.textContent = backlog && backlog["needs_build?"] ? "Plan file exists but no pending items were parsed." : "No pending plan items.";
    return;
  }

  refs.backlogBody.className = "stack";
  refs.backlogBody.innerHTML = items.map((item) => `
    <article class="list-card">
      <div class="list-meta">
        ${badge(item.status || "pending", "good")}
        ${badge(item.section || "general", "purple")}
        ${badge(`line ${item.line_number}`, "info")}
      </div>
      <h3>${escapeHtml(item.text || item.raw_line || "Untitled item")}</h3>
    </article>
  `).join("");
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
      .filter(([key]) => key !== "event_type" && key !== "recorded_at")
      .map(([key, value]) => `<div><span class="meta-label">${escapeHtml(key)}</span> <span class="subtle">${escapeHtml(formatValue(value))}</span></div>`)
      .join("");

    return `
      <article class="event-item">
        <div class="event-head">
          <strong>${escapeHtml(event.event_type || "event")}</strong>
          <span class="event-time">${escapeHtml(event.recorded_at || "unknown")}</span>
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
  }
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
  if (action === "run-plan" || action === "run-build") classes.push("primary");

  return `<button class="${classes.join(" ")}" data-action="${escapeHtml(action)}" ${opts.disabled ? "disabled" : ""}>${escapeHtml(label)}</button>`;
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
