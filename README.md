# Forgeloop

> **Forgeloop is the safe-autonomy layer for coding agents.**
>
> Install it in a repo, let Claude / Codex do real work, and when they start thrashing, Forgeloop pauses, preserves state, and drafts a clean human handoff instead of spinning forever.

Forgeloop is a vendorable, repo-local control plane for agentic software work.

It gives you four things that matter in practice:

1. **A repeatable loop** for planning and building against real repo checks
2. **Fail-closed backpressure** when the same failure keeps repeating
3. **Reviewable escalation artifacts** instead of silent retries and lost context
4. **Machine-readable runtime state** so humans and tooling can see what the agent is doing

Everything else in the kit—skills, knowledge capture, kickoff prompts, task lanes, log ingestion, runner provisioning—compounds on top of that control plane.

## The core promise

Most coding-agent demos show the happy path.

Forgeloop is about the unhappy path:

- the tests keep failing
- the same blocker stays unanswered
- auth breaks on one provider
- the loop needs to stop without losing the trail

When that happens, Forgeloop is designed to **fail closed, not spin**.

## What happens when an agent gets stuck

When a loop crosses the repeated-failure threshold, Forgeloop:

1. **Stops retrying**
2. **Writes `[PAUSE]` to `REQUESTS.md`**
3. **Drafts a human handoff in `ESCALATIONS.md`**
4. **Appends the blocking question to `QUESTIONS.md`**
5. **Writes machine-readable state to `.forgeloop/runtime-state.json`**

That artifact chain is the product.

## Prove it in under a minute

Install the kit into a target repo:

```bash
./install.sh /path/to/target-repo --wrapper
```

Then validate the control plane in that repo:

```bash
cd /path/to/target-repo
./forgeloop.sh evals
```

The eval suite is curated around the safe-autonomy story:

- daemon pause behavior
- repeated-failure escalation
- blocker escalation
- runtime-state transitions
- auth failover
- vendored vs repo-root entrypoint portability

See `evals/README.md` for the public proof surface.

## Quickstart

In the target repo:

```bash
./forgeloop.sh evals
./forgeloop.sh plan 1
./forgeloop.sh build 10
```

For continuous operation:

```bash
./forgeloop.sh daemon 300
```

That daemon is **interval-based**. It does not watch git in real time. It periodically checks the repo and control files, then decides whether to plan, build, pause, deploy, or ingest logs.

### Supported daemon control flags

Add these anywhere in `REQUESTS.md`:

- `[PAUSE]` — pause the daemon until removed
- `[REPLAN]` — run a planning pass before continuing
- `[DEPLOY]` — run the deploy lifecycle (`FORGELOOP_DEPLOY_PRE_CMD`, `FORGELOOP_DEPLOY_CMD`, `FORGELOOP_DEPLOY_SMOKE_CMD`)
- `[INGEST_LOGS]` — analyze logs into a new request

`[PAUSE]` may also be inserted automatically by Forgeloop when it escalates a repeated failure or blocker.

## Deployment-safe pattern

Keep validation and deployment separate.

- `FORGELOOP_VERIFY_CMD` is for typecheck/lint/tests/build only.
- `FORGELOOP_DEPLOY_PRE_CMD` is for deploy preparation such as artifact builds or database migrations.
- `FORGELOOP_DEPLOY_CMD` is for the actual restart or rollout.
- `FORGELOOP_DEPLOY_SMOKE_CMD` is for post-deploy smoke checks.

Example:

```bash
export FORGELOOP_VERIFY_CMD="npm test && npm run build"
export FORGELOOP_DEPLOY_PRE_CMD="npm run db:migrate"
export FORGELOOP_DEPLOY_CMD="sudo systemctl restart my-app"
export FORGELOOP_DEPLOY_SMOKE_CMD="curl -fsS https://example.com/api/health && curl -fsS https://example.com/"
```

By default, Forgeloop rejects deploy-like `FORGELOOP_VERIFY_CMD` values such as `systemctl restart`, `docker compose up`, or `kubectl rollout`.

## Why teams use it

- **Repo-local control plane** — vendor it into an existing repo without rebuilding your whole stack
- **Trust architecture** — repeated failures become explicit pauses and handoffs
- **State you can inspect** — the runtime always writes a machine-readable status file
- **Safer defaults** — `FORGELOOP_AUTOPUSH=false` by default
- **Model failover** — Claude/Codex routing with auth/rate-limit failover
- **Isolated-runner friendly** — designed for disposable VMs / containers when you run full-auto

## The runtime contract

The runtime source of truth lives in:

- `bin/loop.sh`
- `bin/forgeloop-daemon.sh`
- `bin/escalate.sh`
- `lib/core.sh`
- `lib/llm.sh`

The operator contract is documented in:

- `docs/runtime-control.md`
- `docs/sandboxing.md`
- `evals/README.md`

### Runtime states

`.forgeloop/runtime-state.json` is the machine-readable source of truth.

- `status` is the coarse operator state (`running`, `blocked`, `paused`, `awaiting-human`, `recovered`, `idle`)
- `transition` carries the detailed lifecycle step (`planning`, `building`, `retrying`, `escalated`, `completed`, etc.)
- `surface` tells you which surface wrote the state (`loop`, `daemon`, etc.)
- `mode` tells you which run mode is active (`build`, `plan`, `tasks`, `daemon`, etc.)

## Run safely

If you use auto-permissions / full-auto mode, treat the **VM or container as the security boundary**.

- Guide: `docs/sandboxing.md`
- GCP runner helper: `ops/gcp/provision.sh`

Quick provision example:

```bash
OPENAI_API_KEY=... ANTHROPIC_API_KEY=... \
  ops/gcp/provision.sh --name forgeloop-runner \
  --project <gcp-project> --zone us-central1-a
```

## What it installs

Forgeloop vendors into `./forgeloop` and writes the control surfaces at repo root:

- `AGENTS.md`
- `PROMPT_plan.md`
- `PROMPT_build.md`
- `IMPLEMENTATION_PLAN.md`
- `REQUESTS.md`
- `QUESTIONS.md`
- `STATUS.md`
- `CHANGELOG.md`
- `system/knowledge/*`
- `system/experts/*`

That gives agents and operators a consistent repo-local operating surface instead of ad hoc prompt glue.

## Secondary systems that compound

These are real capabilities, but they are not the lead story.

### Skills

Forgeloop includes Skills tooling (`skillforge`, `sync-skills`, repo-local `skills/`) so repeated workflows can become reusable procedures for Codex / Claude Code.

```bash
./forgeloop.sh sync-skills
./forgeloop.sh sync-skills --all
```

### Knowledge capture

Session hooks can load and capture durable repo-local knowledge:

```bash
./forgeloop.sh session-start
./forgeloop.sh session-end
```

### Kickoff

For greenfield projects, generate a prompt for a memory-backed agent to produce `docs/*` and `specs/*`:

```bash
./forgeloop.sh kickoff "<one paragraph project brief>"
```

### Tasks lane

If you want machine-readable task execution instead of a markdown checklist:

```bash
./forgeloop.sh tasks 10
```

### Log ingestion

Turn runtime logs into new requests:

```bash
./forgeloop.sh ingest-logs --file /path/to/logs.txt
```

or configure `[INGEST_LOGS]` in `REQUESTS.md` for daemon-driven ingestion.

## Install / upgrade patterns

Install into another repo from this repo:

```bash
./install.sh /path/to/target-repo --wrapper
```

If the kit is already vendored:

```bash
./forgeloop/install.sh --wrapper
```

Upgrade an existing vendored repo:

```bash
./forgeloop.sh upgrade --from /path/to/newer-forgeloop-kit --force
```

## Project layout

Key top-level paths in this repo:

- `bin/` — loop runtime, daemon, escalation, sync, kickoff, ingestion
- `lib/` — shared runtime helpers and LLM routing
- `docs/` — operator docs
- `evals/` — public proof suite
- `templates/` — installed repo surfaces
- `tests/` — broader regression suite
- `ops/gcp/` — dedicated runner provisioning

## Credits / inspiration

- [how-to-ralph-wiggum](https://github.com/ghuntley/how-to-ralph-wiggum)
- [marge-simpson](https://github.com/Soupernerd/marge-simpson)
- [compound-product](https://github.com/snarktank/compound-product)

Landing page: https://forgeloop.zakelfassi.com
