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

The current seam registers three tools:

- `forgeloop_overview`
- `forgeloop_control`
- `forgeloop_question`

These map directly onto the existing loopback JSON API:

- overview/status snapshots
- pause / clear-pause / replan / manual plan-build / stop / workflow preflight-run
- answer / resolve question

## Config

`openclaw.plugin.json` defines:

- `baseUrl` — service base URL
- `requestTimeoutMs` — HTTP timeout
- `allowMutations` — when `false`, control/question tools refuse to mutate state

## Important limits

- This does **not** make OpenClaw a Forgeloop runtime/provider.
- This does **not** bypass the fail-closed repo-local artifact chain.
- This does **not** yet add daemon-integrated OpenClaw orchestration.
- This does **not** yet add workflow-aware daemon scheduling, richer workflow history, or native graph execution.

Those are later slices.
