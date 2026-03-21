const state = {
  stream: null,
  connected: false,
  hasSnapshot: false,
};

const refs = {
  pill: document.getElementById("connection-pill"),
  runtimeBrief: document.getElementById("runtime-brief"),
  canonicalBrief: document.getElementById("canonical-brief"),
  runtimeBody: document.getElementById("runtime-body"),
  providerBody: document.getElementById("provider-body"),
  backlogBody: document.getElementById("backlog-body"),
  questionsBody: document.getElementById("questions-body"),
  escalationsBody: document.getElementById("escalations-body"),
  eventsBody: document.getElementById("events-body"),
};

boot();

async function boot() {
  setConnectionState("loading", "Booting…");

  try {
    const snapshot = await fetchOverview();
    applySnapshot(snapshot);
    state.hasSnapshot = true;
    setConnectionState("live", "Live stream connected");
  } catch (error) {
    renderFatal(error);
    setConnectionState("offline", "Bootstrap failed");
  }

  connectStream();
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
    setConnectionState(state.hasSnapshot ? "reconnecting" : "offline", state.hasSnapshot ? "Reconnecting…" : "Stream unavailable");
  };
}

function applySnapshot(snapshot) {
  renderRuntime(snapshot.runtime_state, snapshot.babysitter);
  renderProviders(snapshot.provider_health);
  renderBacklog(snapshot.backlog);
  renderQuestions(snapshot.questions || []);
  renderEscalations(snapshot.escalations || []);
  renderEvents(snapshot.events || []);
}

function renderRuntime(runtime, babysitter) {
  const runtimeStatus = runtime?.status || "idle";
  const babysitterRunning = Boolean(babysitter && babysitter["running?"]);
  const babysitterState = babysitterRunning ? "Babysitter active" : "Babysitter idle";
  refs.runtimeBrief.textContent = `Runtime: ${runtimeStatus}`;
  refs.canonicalBrief.textContent = `${babysitterState}. Canonical files stay in the repo root.`;

  if (!runtime) {
    refs.runtimeBody.className = "stack empty";
    refs.runtimeBody.textContent = "No runtime state yet.";
    return;
  }

  refs.runtimeBody.className = "stack";
  refs.runtimeBody.innerHTML = [
    metric("Status", runtime.status),
    metric("Transition", runtime.transition || "—"),
    metric("Surface", runtime.surface || "—"),
    metric("Mode", runtime.mode || "—"),
    metric("Branch", runtime.branch || "—"),
    metric("Reason", runtime.reason || "—"),
    metric("Requested action", runtime.requested_action || "—"),
    metric("Babysitter", babysitterRunning ? "running" : "idle")
  ].join("");
}

function renderProviders(providerHealth) {
  const providers = providerHealth?.providers || [];

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
          ${badge(provider.status.replaceAll("_", " "), statusClass)}
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
  const items = backlog?.items || [];

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
  refs.questionsBody.innerHTML = questions.map((question) => `
    <article class="list-card">
      <div class="list-meta">
        ${badge(question.status_kind || "open", badgeClass(question.status_kind))}
        ${badge(question.id || "question", "info")}
      </div>
      <h3>${escapeHtml(question.question || "Question")}</h3>
      <p>${escapeHtml(question.answer || question.suggested_action || "Awaiting operator input.")}</p>
    </article>
  `).join("");
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

function renderFatal(error) {
  refs.runtimeBody.className = "stack empty";
  refs.runtimeBody.innerHTML = `<article class="list-card"><h3>UI bootstrap failed</h3><p>${escapeHtml(error.message || String(error))}</p></article>`;
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
  if (["available", "pending", "answered"].includes(kind)) return "good";
  if (["awaiting-response", "awaiting_human", "auth_failed", "rate_limited"].includes(kind)) return "warn";
  if (["disabled", "blocked", "spin"].includes(kind)) return "bad";
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
