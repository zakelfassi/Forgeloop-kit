---
name: director-mode-proof
description: "Validate both the standard Forgeloop HUD and the spectator-facing Director Mode against the same canonical loopback state. Use when changing elixir/priv/static/ui/*, when adding stream/broadcast presentation features, or when you need to prove the HUD spectacle still reflects repo-local truth."
---

# Director Mode Proof

## Inputs
- A Forgeloop checkout with HUD changes or stream-mode changes
- The current loopback service and HUD entrypoints
- The existing proof surfaces:
  - `bash bin/self-host-proof.sh`
  - `tests/manual/hud-contract.agent-browser.sh`
  - `node --check elixir/priv/static/ui/app.js`
  - `cd elixir && mix test`

## Outputs
- A clear pass/fail read on whether both HUD scenes remain tied to canonical loopback state
- Screenshot and log artifacts from the existing browser/self-host proof path
- Any follow-up fixes needed in HUD layout, derived summaries, or proof selectors

## Steps
1. Confirm the scope.
   - Read `design.md` and the current `IMPLEMENTATION_PLAN.md` item for Director Mode.
   - Keep the goal additive: presentation layer only, no second control plane.
2. Run the cheap checks first.
   - `node --check elixir/priv/static/ui/app.js`
   - `cd elixir && mix test`
3. Run the real HUD proof.
   - Start with `bash bin/self-host-proof.sh` when the slice affects the real service/HUD flow.
   - Use `tests/manual/hud-contract.agent-browser.sh` when you need the browser-driven HUD proof directly.
4. Verify both scenes.
   - Confirm the standard operator HUD still renders and remains actionable.
   - Confirm Director Mode renders from the same canonical snapshot/stream data.
   - Check that ownership/start-gate truth stays visible and is not buried by spectacle.
5. Reject unsafe presentation drift.
   - Do not allow raw AI chain-of-thought.
   - Do not allow invented narration, fake queue state, or hidden side channels.
   - If commentary exists, it must be bounded and attributable to runtime, coordination, workflow, backlog, question, escalation, or event data already exposed by the loopback service.
6. Record what failed.
   - If proof fails, note whether the break is in layout, selector stability, derived summaries, or the underlying HUD data flow.
   - Fix the smallest real issue, then rerun the relevant proof path.

## Acceptance checklist
- Both HUD scenes render from the same loopback contract.
- Operator controls still work.
- Ownership/start-gate truth remains visible.
- No second source of truth was introduced.
- Browser proof artifacts remain reviewable.

## Examples
- "Use director-mode-proof after changing `elixir/priv/static/ui/app.js` to add the Director Mode scene switch."
- "Use director-mode-proof before shipping a stream-mode polish pass so we know the HUD still reflects canonical repo-local state."
