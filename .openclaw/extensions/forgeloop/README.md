# Forgeloop OpenClaw plugin

Workspace plugin that lets OpenClaw monitor and pilot Forgeloop through the loopback control-plane service.

## What it does

- reads the same `/api/overview` snapshot that powers the local HUD
- reads the shared coordination advisory from `/api/coordination` when the service exposes it, with older-service fallback to canonical `/api/events`
- sends pause / clear-pause / replan / run / stop actions through the same loopback API
- answers or resolves questions using the current canonical question revision
- can evaluate one bounded orchestration window into operator-readable playbooks and, when explicitly enabled, apply at most one pause / clear-pause / replan action

## Recommended topology

- run OpenClaw on the same VM/host as Forgeloop
- start the control plane with `./forgeloop.sh serve`
- let this plugin target `http://127.0.0.1:4010` by default
- if you need remote access, prefer Tailscale to reach that host rather than exposing the service publicly

## Tools

- `forgeloop_overview`
- `forgeloop_control`
- `forgeloop_question`
- `forgeloop_orchestrate`

## Notes

- This plugin is a control-surface seam, not a new source of truth.
- Repo-local files and `.forgeloop/runtime-state.json` stay canonical.
- Manual runs launched here use `surface: "openclaw"` so they can be distinguished from browser-HUD runs.
- `forgeloop_orchestrate` is dry-run by default, uses caller-managed `after` / `next_after` cursors instead of hidden plugin persistence, and now prefers the service-owned coordination read model that the HUD also renders.
- If `/api/coordination` is unavailable on an older service, the plugin falls back to the prior local `/api/events` + `/api/overview` evaluation path for backward compatibility.
- Optional `playbookId` targeting can scope one invocation to a single playbook without changing cursor semantics or creating a second control plane.
- Apply mode is separately gated by `allowOrchestrationApply`, still requires `allowMutations=true`, stays limited to one bounded pause / clear-pause / replan action, and blocks if the shared coordination endpoint fails unexpectedly.
