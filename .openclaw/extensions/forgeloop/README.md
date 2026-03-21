# Forgeloop OpenClaw plugin

Workspace plugin that lets OpenClaw monitor and pilot Forgeloop through the loopback control-plane service.

## What it does

- reads the same `/api/overview` snapshot that powers the local HUD
- sends pause / clear-pause / replan / run / stop actions through the same loopback API
- answers or resolves questions using the current canonical question revision

## Recommended topology

- run OpenClaw on the same VM/host as Forgeloop
- start the control plane with `./forgeloop.sh serve`
- let this plugin target `http://127.0.0.1:4010` by default
- if you need remote access, prefer Tailscale to reach that host rather than exposing the service publicly

## Tools

- `forgeloop_overview`
- `forgeloop_control`
- `forgeloop_question`

## Notes

- This plugin is a control-surface seam, not a new source of truth.
- Repo-local files and `.forgeloop/runtime-state.json` stay canonical.
- Manual runs launched here use `surface: "openclaw"` so they can be distinguished from browser-HUD runs.
