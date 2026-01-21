# Ralph Kit

Ralph Kit is a portable **implementation + augmentation** of the workflow described in **The Ralph Playbook**.

- Playbook (how/why): https://github.com/ghuntley/how-to-ralph-wiggum
- This repo (do/ship): scripts + markdown templates you can apply to any codebase.

## What it adds (augmentations)
- **Portable kit** vendorable as `ralph/` into any repo
- **Multi-model routing** (Codex for plan/review/security; Claude for build) + optional failover
- **`plan-work` mode** for branch-scoped planning (avoids unreliable “filter tasks at runtime”)
- **Safer defaults**: `RALPH_AUTOPUSH=false` by default
- **Runtime isolation**: logs/state in `.ralph/` (auto gitignored by installer)
- **Optional Slack loop**: `ask.sh` + `QUESTIONS.md`, `notify.sh`
- **Optional daemon** with `[PAUSE]`, `[REPLAN]`, `[DEPLOY]` triggers in `REQUESTS.md`
- **Optional structured review/security gate** via JSON schemas

## Install into another repo

From this repo:
```bash
./install.sh /path/to/target-repo --wrapper
```

If the kit is already vendored in a target repo at `./ralph`:
```bash
./ralph/install.sh --wrapper
```

## Run (in the target repo)

```bash
./ralph/bin/loop.sh plan 1
./ralph/bin/loop.sh 10
```

Daemon mode:
```bash
./ralph/bin/ralph-daemon.sh 300
```

## Run safely (VMs / Docker)

If you’re using auto-permissions (`--dangerously-skip-permissions`, `--full-auto`), run in an isolated environment:
- `docs/sandboxing.md`

## Config

Edit `ralph/config.sh` (in the target repo) to set:
- `RALPH_AUTOPUSH=true` if you want auto-push
- `RALPH_TEST_CMD` (optional) to run after review auto-fixes
- `RALPH_DEPLOY_CMD` (optional) used by the daemon on `[DEPLOY]`

## Notes
- Optional Slack integration uses `.env.local` with `SLACK_WEBHOOK_URL=...`.
