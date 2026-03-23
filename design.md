# Forgeloop V2 Design Brief

This file is the product design brief for Forgeloop’s public landing page and operator dashboard.

It is written to be usable by humans, coding agents, and design-generation tools that consume a `design.md`-style prompt.

## References

- Stitch overview: https://stitch.withgoogle.com/docs/design-md/overview/
- Stitch format: https://stitch.withgoogle.com/docs/design-md/format
- Product README: `README.md`
- Operator HUD source: `elixir/priv/static/ui/index.html`
- Landing page source: `index.html`

## Product summary

Forgeloop is the safe-autonomy control plane for coding agents.

Its job is not to make agents look magical. Its job is to make autonomous software work observable, reviewable, interruptible, and fail-closed.

The UI should make Forgeloop feel like:
- a serious operator system
- a beautiful product, not an internal tool accident
- a trustworthy control room for real autonomous work
- a new category beyond issue trackers and chat logs

## Release context

- Stable track: v1.0.0
- Current main branch: v2 alpha
- The design should help explain this transition clearly.
- The landing page should communicate both current capability and where the v2 track is headed.
- The dashboard should feel production-ready even while some surfaces remain alpha.

## Core design goals

1. Make the product feel memorable and differentiated.
2. Make the system state legible in under 5 seconds.
3. Preserve the file-first, fail-closed philosophy in the interface.
4. Reduce visual clutter while increasing operator confidence.
5. Make the landing page feel like a category-defining product, not a bash utility.
6. Make the HUD feel like a live control room, not a generic admin panel.

## Target users

### 1. Founder / technical operator
- Runs agents on real repos
- Needs confidence, control, and clarity
- Wants to see what the system is doing without reading raw files first

### 2. AI-forward engineering team
- Evaluates whether Forgeloop can become part of their delivery workflow
- Needs clear differentiation from issue trackers, CI dashboards, and chat agents
- Wants confidence that the system is reviewable and safe

### 3. Power user / self-hoster
- Cares about repo-local state, proofs, ownership conflicts, recovery, workflows, and control surfaces
- Values dense information, but only when organized with strong hierarchy

## Experience principles

### 1. Control room, not generic SaaS
The product should feel like a mission control surface for autonomous software work.

### 2. Beautiful but operational
The UI can be dramatic and branded, but must still read instantly during real usage.

### 3. Clarity over volume
Show the most important state first: ownership, runtime status, active blockers, next recommended action.

### 4. Evidence over vibes
Whenever possible, the interface should imply that the truth lives in canonical repo-local artifacts and runtime state.

### 5. Human authority remains visible
The UI must reinforce that operators can pause, clear, replan, and review; the system is not pretending to be fully autonomous.

## Desired visual direction

### Primary aesthetic
**Psychedelic RPG mission control**

Blend:
- vibrant editorial web design in the spirit of modern creative studios
- game-like control-room framing
- industrial systems UI discipline
- repo-local hacker credibility
- presentation-worthy motion and color energy

This should feel:
- alive
- vibrant
- strange in a good way
- cinematic
- high-signal
- streamer-demo worthy
- mechanically trustworthy

It should not feel:
- like a generic startup gradient landing page
- like a bootstrap admin template
- like a bland enterprise dashboard
- like shallow faux-gaming chrome without useful hierarchy

## Visual language

### Typography
Use a distinctive display face paired with a readable body face and a disciplined monospace.

Desired behavior:
- strong, recognizable headlines
- restrained body typography
- monospace reserved for commands, state, artifacts, and machine-readable labels

### Color
Use a darker operator-forward palette with vibrant, psychedelic accents.

Suggested token intent:
- background: deep obsidian / midnight mineral tone
- surface: layered dark panels with luminous separation
- accent 1: electric lime / toxic mint for live, verified, actionable state
- accent 2: ultraviolet / indigo for orchestration and system framing
- accent 3: hot magenta / ember for attention, warnings, and dramatic emphasis
- accent 4: acid gold for quests, objectives, and highlighted proof moments
- neutrals: high-contrast text and muted structural tones

The palette should feel premium, alive, and slightly unreal without becoming messy.

### Composition
Favor:
- asymmetry with disciplined alignment
- strong hero moments
- large typographic statements
- layered panels and depth
- clear status bands / rails / modules
- sectional pacing that alternates dense information and negative space

### Motion
Motion should feel intentional and system-like:
- controlled fades
- panel reveals
- subtle status transitions
- live-state pulses only where useful
- no ornamental animation that obscures state

## Information architecture

## Landing page sections
1. Hero: what Forgeloop is in one sentence
2. Why it exists: fail-closed vs agent thrash
3. How it works: canonical files, runtime state, escalations, daemon/service/HUD
4. Release tracks: v1 stable vs v2 alpha
5. Operator surfaces: CLI, HUD, OpenClaw seam, self-host proof
6. Proof section: evals + self-host proof
7. Workflow / roadmap direction
8. Install / quickstart / CTA

## HUD priorities
The operator HUD should prioritize this order:
1. runtime + ownership
2. start-gate / conflicts / actionable warnings
3. recommended actions
4. operator controls
5. coordination summary
6. active questions / escalations
7. workflows
8. tracker / backlog
9. event stream

The first screen should answer:
- What is happening?
- Is it safe to start or intervene?
- What should I do next?

## Required states to design explicitly

### Landing page
- default browsing state
- mobile navigation state
- code/example readability
- v1/v2 release-track explanation

### HUD
- loading
- empty / cold start
- live / healthy
- paused
- blocked / awaiting human
- conflict / ownership claimed elsewhere
- degraded / stale metadata
- action success
- action error
- no workflows
- no questions
- no escalations

## Component guidance

### Landing page
- hero statement with immediate product differentiation
- release-track cards or equivalent structure
- proof / trust section with commands and outcomes
- roadmap / status surface that feels honest
- command examples that remain copyable and readable

### HUD
- status rail or high-priority overview band
- ownership module with unmistakable gating language
- action deck with clear disabled reasons
- timeline / coordination module with concise summaries
- event stream that is readable but visually secondary
- workflow cards that separate ready, running, invalid, and historical outcomes

## Content tone
- crisp
- technical
- ambitious
- trustworthy
- not hypey
- not cute
- not overloaded with jargon

Preferred language themes:
- control plane
- fail closed
- canonical artifacts
- operator
- managed run
- ownership
- proof
- reviewable autonomy

## Accessibility and usability requirements
- Strong keyboard focus styles
- AA contrast minimum
- Clear disabled states
- Clear empty/loading/error states
- Responsive behavior for laptop-first, then tablet/mobile
- Avoid relying on color alone for status
- Preserve readable command/code blocks

## Constraints
- Keep current architecture: static landing page + additive HUD served by the existing service
- No design that requires a heavy frontend framework rewrite by default
- Do not obscure canonical file-first product behavior
- Do not imply autonomous behavior the product does not actually provide
- Keep implementation realistic for the current repo

## Initial redesign direction

### Landing page concept
A vibrant, psychedelic product narrative that feels like a studio-quality launch site for the operating system of safe autonomous software work. It should feel worthy of demos, screenshots, slide decks, videos, and social clips.

### HUD concept
A clearer RPG control-room layout with a dominant top band for runtime, ownership, objectives, and next actions. It should feel like an operator game interface for real systems work: dramatic, but still legible and trustworthy.

## Success criteria
The redesign is successful if:
- a new visitor understands Forgeloop’s purpose quickly
- the product feels distinctly more premium and ownable
- the HUD feels easier to scan under pressure
- release-track messaging is clearer
- the system feels more like a cohesive product and less like accumulated features

## User-selected direction
- Reference feel: beaucoup.studio energy — modern, alive, different, vibrant, almost psychedelic
- Primary direction: game-like
- Landing-page priority: product depth
- Content goal: worthy of tech-streamer demos, presentations, slide decks, and video content
- HUD tone: RPG control room
- Visual constraints: go with the flow; no explicit hard no's yet

## Remaining judgment calls
- how far to push motion without harming clarity
- whether to keep some paper/editorial DNA from the current landing page or fully pivot into darker luminous surfaces
- whether to introduce a stronger emblem / mark system as part of the redesign
