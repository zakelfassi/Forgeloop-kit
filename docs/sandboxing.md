# Running Forgeloop in Full-Auto Mode (Sandboxing)

Forgeloop’s safe-autonomy promise only works if the runtime boundary is explicit.

When you run the agent with **auto-permissions** (no approvals), it can search, edit, run tests, and iterate without a human gate.

That also means the agent can run **arbitrary commands**.

Treat the **sandbox/VM/container** as your security boundary.

## What “full-auto” means in this kit

- Claude Code (`claude`) runs with `--dangerously-skip-permissions` (auto-approve tool calls).
- Codex CLI (`codex`) runs with `--dangerously-bypass-approvals-and-sandbox` (no sandbox; use only in isolated runners).

You can override these via environment variables (see `forgeloop/config.sh` after install, or export `CLAUDE_FLAGS` / `CODEX_FLAGS`).

## Recommended baseline

- OS: Ubuntu 22.04 or 24.04
- Size: 2–4 vCPU, 4–16 GB RAM
- Disk: 80–200 GB
- Tools: `git`, `curl`, `jq`, Node.js, `pnpm`, plus the `claude` and/or `codex` CLIs

## Repo-internal isolation (experimental manual Elixir slice)

Inside the VM/container boundary, Forgeloop now has an **experimental manual self-hosting layer via disposable git worktrees**.

That current slice lets Elixir:

- launch one child `plan` or `build` run inside a disposable checkout
- give a babysitter/supervisor process a bounded place to launch, watch, pause, and clean up that child run
- keep repo-root control artifacts and `.forgeloop/runtime-state.json` canonical while shell execution happens in the disposable checkout

It is **not** a replacement for the VM/container boundary. Treat worktrees as hygiene and blast-radius reduction inside the real sandbox, not as a security primitive.

Important current limits remain open: daemon scheduling through the babysitter, workflow-lane babysitting, UI/API control surfaces, and any worktree-aware ownership-claim semantics.

Workflow-pack runners may also declare runner-side worktree behavior such as `worktree_mode`, but that remains runner-internal hygiene inside the VM/container boundary. It does not replace Forgeloop’s own sandboxing requirements.

## Local Docker sandbox (fastest way to reduce blast radius)

This is a good default if you want **auto-permissions** but don’t want an agent running on your host OS.

### Option A: mount a repo from your host

From your target repo root:

```bash
docker run --rm -it \
  -v "$PWD":/repo \
  -w /repo \
  -e OPENAI_API_KEY \
  -e ANTHROPIC_API_KEY \
  ubuntu:24.04 bash
```

Inside the container, install dependencies, install the CLIs, then run:

```bash
./forgeloop/bin/loop.sh plan 1
./forgeloop/bin/loop.sh 10
```

Notes:
- Only mount the repo, not your home directory.
- Pass only the minimum API keys/secrets required.

### Option B: clone inside the container (safer)

This avoids mounting your working copy, at the cost of extra setup.

- Start a container shell
- `git clone ...`
- Install deps + CLIs
- Run the loop inside that container

## Cloud VM runners (good for 24/7 daemons)

### Common steps (any provider)

1. Create a fresh VM (Ubuntu), add your SSH key.
2. SSH in, install base tools (`git`, `curl`, `jq`).
3. Install Node.js + `pnpm`.
4. Install the agent CLI(s): `claude` and/or `codex`.
5. Clone your target repo.
6. Install Forgeloop into the target repo:
   ```bash
   /path/to/forgeloop/install.sh /path/to/target-repo --wrapper
   ```
7. Export API keys (and optionally Slack webhook) as environment variables.
8. Run the loop in `tmux`:
   ```bash
   tmux new -s forgeloop
   ./forgeloop.sh plan 1
   ./forgeloop.sh build 10
   ```
9. (Optional) Run the daemon:
   ```bash
   ./forgeloop.sh daemon 300
   ```

### Google Cloud (gcloud)

Quick provision (recommended):

```bash
cd /path/to/forgeloop
OPENAI_API_KEY=... ANTHROPIC_API_KEY=... ops/gcp/provision.sh --name forgeloop-runner --project <gcp-project> --zone us-central1-a
```

Dry-run (prints commands only):

```bash
ops/gcp/provision.sh --name forgeloop-runner --project <gcp-project> --zone us-central1-a --dry-run
```

Manual provisioning:

Create a VM (example uses `e2-standard-4`):

```bash
gcloud compute instances create forgeloop-runner \
  --zone=us-central1-a \
  --machine-type=e2-standard-4 \
  --boot-disk-size=100GB \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud

gcloud compute ssh forgeloop-runner --zone=us-central1-a
```

Tear down when done:

```bash
gcloud compute instances delete forgeloop-runner --zone=us-central1-a
```

### Hetzner Cloud (hcloud)

Create a VM (example uses shared vCPU plans):

```bash
hcloud server create \
  --name forgeloop-runner \
  --type cx22 \
  --image ubuntu-22.04 \
  --ssh-key <your-ssh-key-name>

hcloud server ssh forgeloop-runner
```

### DigitalOcean (doctl)

```bash
doctl compute droplet create forgeloop-runner \
  --region nyc3 \
  --size s-2vcpu-4gb \
  --image ubuntu-22-04-x64 \
  --ssh-keys <your-ssh-key-id> \
  --wait

doctl compute ssh forgeloop-runner
```

### AWS (Lightsail)

Lightsail is the simplest “AWS VM” path for a single agent runner.

- Create a Linux/Unix Lightsail instance (pick a bundle size below)
- SSH in via the console or your SSH key
- Follow the Common steps above

## Ballpark monthly pricing (compute-only)

These are **rough reference points** (region, discounts, VAT, storage, snapshots, and bandwidth can change totals).

| Provider | Example plan | vCPU / RAM | Approx price | Notes |
| --- | --- | --- | --- | --- |
| Hetzner Cloud | CX22 | 2 vCPU / 4 GB | €3.79/mo (ex VAT) | Shared vCPU (very cost-effective) |
| Hetzner Cloud | CX32 | 4 vCPU / 8 GB | €6.80/mo (ex VAT) | Shared vCPU |
| DigitalOcean | Basic Droplet | 2 vCPU / 4 GB | $24/mo | Includes bandwidth allowance |
| DigitalOcean | Basic Droplet | 4 vCPU / 8 GB | $48/mo | Includes bandwidth allowance |
| AWS Lightsail | Virtual server | 2 vCPU / 4 GB | $24/mo | Includes bandwidth allowance |
| AWS Lightsail | Virtual server | 2 vCPU / 8 GB | $44/mo | Includes bandwidth allowance |
| Google Cloud | Compute Engine `e2-standard-2` | 2 vCPU / 8 GB | ~$0.067/hr (~$49/mo) | Disk/egress billed separately |
| Google Cloud | Compute Engine `e2-standard-4` | 4 vCPU / 16 GB | ~$0.134/hr (~$98/mo) | Disk/egress billed separately |

## Hardening checklist

- Use a dedicated VM/container (no personal files, no browser cookies, no SSH agent forwarding).
- Use least-privilege tokens (separate Git deploy key, limited cloud IAM).
- Prefer short-lived credentials; rotate regularly.
- Keep `FORGELOOP_AUTOPUSH=false` unless you’re on a work branch and want autonomous pushes.
- Limit network egress where possible (allowlist Git + package registries).
