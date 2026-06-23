# Sentry Auto-Fix

Self-hosted **Sentry → Cursor Agent → Bitbucket PR** automation for any codebase (Flutter, Laravel/PHP, etc.).

Detects unresolved Sentry issues, fixes them in an **isolated git worktree**, pushes `fix/sentry-*` branches, and opens **draft PRs** for human review.

Works on **macOS** with Cursor CLI + Sentry MCP. No paid automation platforms.

---

## Who is this for?

| Team | `PROJECT_PROFILE` | `CODE_PATH` | Example |
|------|-------------------|-------------|---------|
| **Flutter / mobile** | `flutter` | `lib` | `abyan-app-flutter` |
| **Laravel / PHP backend** | `laravel` | `app` | Laravel API repo |
| **Other** | `generic` | `src` | Custom layout |

Same workflow for everyone: **detect → triage → fix → draft PR**.

---

## Features

- Cursor Agent + Sentry MCP (no Sentry token required for fixes; token optional for pagination)
- **Tiered triage:** TypeError, PlatformException, auth errors first → LaunchDarkly / App Hang last
- **REST pagination** with Sentry API cursor (up to ~1000 issues per cycle)
- **Isolated worktree** — never switches your active git branch
- **Auto draft PR** with structured body (solutions, chosen fix, Sentry resolve link)
- **macOS LaunchAgent** — `./run.sh` runs in background after first start

---

## Quick start

```bash
git clone https://github.com/YOUR_USER/sentry-auto-fix.git
cd sentry-auto-fix
chmod +x run.sh

cp config.example.env config.env
# Or: cp config.example.flutter.env config.env
# Or: cp config.example.laravel.env config.env

# Fill secrets in config.env, then:
cursor agent login
./run.sh check-bitbucket
./run.sh
```

---

## Configuration

See `config.example.env`. Key variables:

| Variable | Description |
|----------|-------------|
| `REPO_ROOT` | Absolute path to the app repo to fix |
| `CODE_PATH` | `lib` (Flutter), `app` (Laravel), `src` (Node), etc. |
| `PROJECT_PROFILE` | `flutter` \| `laravel` \| `generic` |
| `SENTRY_AUTH_TOKEN` | Optional but recommended for pagination |
| `BITBUCKET_ACCESS_TOKEN` | Repository token with PR write scope |

### Sentry token scopes

Organization **Read**, Project **Read**, Issue & Event **Read**.

---

## Commands

| Command | Description |
|---------|-------------|
| `./run.sh` | Start background auto-fix (default) |
| `./run.sh once` | Fix one issue in foreground |
| `./run.sh status` | Last run summary |
| `./run.sh check-bitbucket` | Test Bitbucket token |
| `./run.sh reset-pagination` | Reset Sentry page cursor |
| `./run.sh stop-auto` | Stop background service |

---

## Triage order

| Tier | Examples | When |
|------|----------|------|
| **tier1** | TypeError, PlatformException, auth/401, routing, null checks | **First** |
| **tier2** | Framework/provider/JSON/async issues in app code | After tier1 |
| **tier3** | LaunchDarkly, App Hang, ANR, vendor SDK noise | **Last** |

---

## Architecture

```
Sentry issues
    ↓
run.sh (orchestrator)
    ↓
sentry_pagination.py (tier-priority prefetch)
    ↓
Cursor Agent + Sentry MCP (fix in .state/fix-worktree)
    ↓
git push fix/sentry-* → Bitbucket draft PR
```

---

## File layout

```
sentry-auto-fix/
├── run.sh                    # Main entrypoint
├── sentry_pagination.py      # Tier + pagination logic
├── parse_agent_output.py     # Parse Cursor stream-json
├── sentry_client.py          # Sentry REST client
├── config.example.env
├── config.example.flutter.env
├── config.example.laravel.env
├── requirements.txt
└── .state/                   # Runtime (gitignored)
```

---

## Using inside an app monorepo

You can either:

1. **Clone separately** and point `REPO_ROOT` at your app repo (recommended for BE team)
2. **Copy into** `your-repo/scripts/sentry-auto-fix/` and add `config.env` locally (gitignored)

Do **not** commit `config.env` (contains tokens).

---

## Safety

- Draft PRs only — human review required
- Secrets in `config.env` only — never committed
- Worktree isolation — main checkout untouched
- Mac must be on for background runs

---

## Origin

Built for [Abyan](https://abyan.com.sa) mobile (Flutter) and shared with backend team.  
Originally developed as `scripts/sentry-auto-fix` in `abyan-app-flutter`.
