# Docker (Ubuntu worker)

Run Sentry Auto-Fix on a **dedicated Ubuntu host** (same cloud account as APIs is fine — **not** the API box) via Docker.

## What the image includes

- Ubuntu 24.04  
- Flutter SDK (stable) + Melos  
- Vendored CodeGuardian (bootstrapped at build)  
- Python venv + toolkit  
- Cursor Agent CLI (`CURSOR_API_KEY` at runtime)  
- Wrapper so `run.sh`’s `cursor agent …` works headless  

## Host layout

```text
sentry-auto-fix/
  Dockerfile
  docker-compose.yml
  data/
    config.env          # secrets (gitignored) — copy from config.example.env
    app/                # clone of abyan-app-flutter
    state/              # persisted .state
    logs/               # persisted logs
```

```bash
mkdir -p data/state data/logs
cp config.example.env data/config.env
# edit data/config.env — set Sentry, Bitbucket, Slack, etc.
# REPO_ROOT is rewritten to /workspace/app by the entrypoint when using compose

git clone git@bitbucket.org:robo-adv/abyan-app-flutter.git data/app
# or HTTPS with a bot token
```

Set Cursor key (do not put in git):

```bash
export CURSOR_API_KEY=...   # or add to a local .env next to compose
```

In `data/config.env` also set (or rely on compose env):

```env
CURSOR_API_KEY=...
CODEGUARDIAN_ENABLED=true
SENTRY_RESOLVE_AFTER_MERGE=auto
AUTO_INSTALL_LAUNCHAGENT=false
```

## Build & test

```bash
docker compose build

# Slack
docker compose run --rm autofix test-slack

# One fix cycle (may take 10–30+ min)
docker compose run --rm autofix once

# Follow logs
docker compose run --rm autofix bash -lc 'tail -f /toolkit/logs/flutter/run.log'
```

## Run forever

```bash
docker compose up -d
docker compose logs -f autofix
docker compose restart autofix
docker compose down
```

## Give this to the server person

| Item | Value |
|------|--------|
| Host | Separate Ubuntu VM (not API) |
| RAM | 8–16 GB |
| Disk | ≥50 GB |
| Ports inbound | none required |
| Outbound | Sentry, Bitbucket, Cursor, Slack, pub.dev, GitHub |
| Deploy | `docker compose up -d` from this repo |
| Secrets | `data/config.env` + `CURSOR_API_KEY` |

## Caveats

1. **Cursor in Docker** — use `CURSOR_API_KEY` (headless). Interactive `agent login` is unreliable in containers.  
2. First **image build** is large/slow (Flutter SDK).  
3. Mount the **app repo** writable so the agent can push.  
4. Do not run this compose stack on the API container host under the API’s memory budget — use the dedicated worker VM.

## Without Compose

```bash
docker build -t sentry-autofix .
docker run --rm -it \
  -e CURSOR_API_KEY \
  -v "$PWD/data/config.env:/toolkit/config.env:ro" \
  -v "$PWD/data/app:/workspace/app" \
  -v "$PWD/data/state:/toolkit/.state" \
  -v "$PWD/data/logs:/toolkit/logs" \
  sentry-autofix once
```
