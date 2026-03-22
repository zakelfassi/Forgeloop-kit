# OpenClaw plugin seam

Forgeloop now ships a **repo-local OpenClaw workspace plugin seam** at:

```text
.openclaw/extensions/forgeloop/
```

This is intentionally a **control-surface seam**, not a new runtime or provider.

## What it talks to

The plugin targets the same loopback control-plane service that powers the local HUD:

```bash
./forgeloop.sh serve
```

Default base URL:

```text
http://127.0.0.1:4010
```

That means:

- the repo-local files stay canonical
- `.forgeloop/runtime-state.json` stays canonical
- the plugin does not bypass the babysitter/worktree/runtime-state path
- manual runs launched through the plugin record `surface: "openclaw"`

## Recommended topology

Recommended first:

- run Forgeloop, the HUD/service, and OpenClaw on the **same host/VM**
- keep the service loopback-only
- use OpenClaw as the operator/agent surface above that local service

If you want remote operator access, prefer **Tailscale to the host** over exposing the service publicly. If you do that, point the plugin `baseUrl` at the Tailscale-reachable service URL explicitly.

## Plugin tools

The current seam registers four tools:

- `forgeloop_overview`
- `forgeloop_control`
- `forgeloop_question`
- `forgeloop_orchestrate`

These map directly onto the existing loopback JSON API:

- overview/status snapshots plus dedicated recent-event tails from `/api/events`
- pause / clear-pause / replan / manual plan-build / stop / workflow preflight-run
- answer / resolve question
- bounded event-window review over `/api/events?after=...` with caller-managed replay cursors

## Config

`openclaw.plugin.json` defines:

- `baseUrl` — service base URL
- `requestTimeoutMs` — HTTP timeout
- `allowMutations` — when `false`, control/question tools refuse to mutate state
- `allowOrchestrationApply` — when `true` and `allowMutations` is also `true`, `forgeloop_orchestrate` may apply one bounded pause / clear-pause / replan action
- `orchestrationDefaultLimit` — default replay window size for `forgeloop_orchestrate`

## Bounded orchestration contract

`forgeloop_orchestrate` is intentionally narrow:

- dry-run/recommend mode is the default
- the caller supplies `after` and receives `next_after`; the plugin does not persist cursors
- it reads canonical replay/tail metadata from `/api/events`
- it can apply **at most one** bounded action per invocation, and only from:
  - `pause`
  - `clear_pause`
  - `replan`
- if replay is truncated, the cursor is missing, or `/api/events` is unavailable, it falls back safely to read-only recommendations and does not mutate the control plane

All mutations still flow through the same loopback control endpoints and canonical repo-local artifacts.

## Important limits

- This does **not** make OpenClaw a Forgeloop runtime/provider.
- This does **not** bypass the fail-closed repo-local artifact chain.
- This does **not** add hidden plugin-owned cursor persistence or long-lived `/api/stream` orchestration loops yet.
- This does **not** yet auto-trigger runs, workflow actions, or question mutations from OpenClaw orchestration.
- This does **not** yet add broader daemon-integrated OpenClaw orchestration, event compaction/search, or native graph execution beyond the current bounded workflow history and event replay view.

Those are later slices.
