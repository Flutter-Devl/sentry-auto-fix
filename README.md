# Sentry Auto-Fix

Automated **Sentry → Cursor Agent → Bitbucket** pipeline that detects unresolved production errors, fixes them using AI in an isolated git worktree, and pushes `fix/sentry-*` branches — one branch per Sentry issue.

Works entirely on your Mac. No paid automation platform. No cloud runner.

---

## How it works

```
Sentry (live issues)
       ↓
sentry_pagination.py — fetches & tier-ranks up to 1,000 issues per cycle
       ↓
Cursor Agent + Sentry MCP — reads full stack trace, fixes root cause in code
       ↓
git push fix/sentry-<issue>-<slug> → origin
       ↓
Bitbucket draft PR (if token set) — or open PR manually from Bitbucket banner
```

Each run fixes **one issue** and pushes one branch. Run it in a loop or on a schedule to work through the backlog automatically.

---

## Profiles

This project supports multiple repos from a single `config.env` using **profiles**. Pass the profile name as the first argument to `run.sh`.

| Profile | Repo | Sentry project | Base branch | Code path |
|---|---|---|---|---|
| `flutter` (default) | Flutter mobile app | (configure in base keys) | `develop` | `lib/` |
| `laravel` | `robo-adv/abyan-backend` | `server-prod` | `master` | `app/` |

Each profile has its own:
- Isolated state directory: `.state/flutter/` or `.state/laravel/`
- Isolated log directory: `logs/flutter/` or `logs/laravel/`
- Separate LaunchAgent (background service) so both can run independently

---

## Quick start

**Branch:** `feature/combined-sentry-codeguardian` — Sentry Auto-Fix + vendored CodeGuardian in **one clone**.

```bash
git clone https://github.com/Flutter-Devl/sentry-auto-fix.git
cd sentry-auto-fix
git checkout feature/combined-sentry-codeguardian

# 1) One-time deps
./setup.sh

# 2) Edit secrets / REPO_ROOT once
$EDITOR config.env
# cursor agent login   # or set CURSOR_API_KEY in config.env

# 3) One-time: turn on forever automation (LaunchAgent) — same model as before
./setup.sh --auto
# equivalent: ./run.sh flutter start
```

After that it keeps working in the background (login + KeepAlive). Monitor with `./run.sh flutter status`.

One-shot without daemon:

```bash
./run.sh flutter once
./run.sh laravel once
```

---

## All commands

### Profile argument (always first, optional)

```bash
./run.sh                  # flutter profile (default)
./run.sh flutter <cmd>    # flutter profile explicit
./run.sh laravel <cmd>    # laravel profile
```

### Run modes

| Command | What it does |
|---|---|
| `./run.sh [profile]` | **Default start** — installs background service on first run, then runs forever |
| `./run.sh [profile] once` | Fix **one issue** in foreground (~10–30 min), then exit |
| `./run.sh [profile] loop [N]` | Fix issues back-to-back until `NO_ACTION` (optional max N issues) |
| `./run.sh [profile] daemon` | Foreground poll loop — terminal must stay open |

### Monitor & status

| Command | What it does |
|---|---|
| `./run.sh [profile] status` | Summary of the last run (issue, branch, PR link) |
| `./run.sh [profile] auto-status` | Is the background LaunchAgent running? + last result |

### Background service (LaunchAgent)

| Command | What it does |
|---|---|
| `./run.sh [profile] install-auto` | Install background service (auto-starts on Mac login) |
| `./run.sh [profile] stop-auto` | Stop and uninstall background service |

### Bitbucket

| Command | What it does |
|---|---|
| `./run.sh [profile] check-bitbucket` | Test Bitbucket token and PR scope |
| `./run.sh [profile] create-pr [branch]` | Manually open a draft PR for a pushed branch |

### Maintenance

| Command | What it does |
|---|---|
| `./run.sh [profile] unlock` | Clear a stuck run lock (if a previous run crashed) |
| `./run.sh [profile] reset-pagination` | Reset Sentry page cursor and exclusion list |
| `./run.sh [profile] resolve-issue <SHORT_ID>` | Mark a Sentry issue resolved after deploy |
| `./run.sh [profile] record-rejection <SHORT_ID> "reason"` | Store PR rejection lesson for future runs |
| `./run.sh [profile] list-rejections` | List stored rejection lessons |
| `./run.sh [profile] sync-pr-feedback` | Import declined PR feedback from Bitbucket |
| `./run.sh [profile] test-slack` | Send test message to Slack webhook |
| `./run.sh [profile] list-rejections` | List stored rejection lessons |
| `./run.sh [profile] sync-pr-feedback` | Sync declined PR feedback from Bitbucket |

### Examples

```bash
# Laravel — fix issues one by one until no more remain
./run.sh laravel loop

# Laravel — fix at most 3 issues then stop
./run.sh laravel loop 3

# Flutter — install background service (runs every 5 min, persists after reboot)
./run.sh flutter install-auto

# Stop the laravel background service
./run.sh laravel stop-auto

# Watch the laravel run live in another terminal
tail -f /Users/mac/Documents/sentry-auto-fix/logs/laravel/run.log

# After merging a fix, mark it resolved in Sentry
./run.sh laravel resolve-issue SERVER-PROD-9KY3

# Manually open a PR for a branch the agent pushed
./run.sh laravel create-pr fix/sentry-server-prod-9ky3-refinitiv-retry-connection-exception
```

---

## Configuration (`config.env`)

### Flutter profile (base keys)

```env
REPO_ROOT=/absolute/path/to/flutter-repo
GIT_BASE_BRANCH=develop
CODE_PATH=lib
PROJECT_PROFILE=flutter

SENTRY_ORG_SLUG=your-org-slug
SENTRY_PROJECT_SLUG=your-flutter-project
SENTRY_AUTH_TOKEN=""          # org:read, project:read, event:read
SENTRY_QUERY="is:unresolved level:error"

BITBUCKET_WORKSPACE=your-workspace
BITBUCKET_REPO_SLUG=your-flutter-repo
BITBUCKET_AUTH=bearer
BITBUCKET_ACCESS_TOKEN=""     # repository:read + pullrequest:write

CURSOR_BIN=/usr/local/bin/cursor
CURSOR_AGENT_MODEL=composer-2.5
CURSOR_API_KEY=""             # from cursor.com/settings
```

### Laravel profile (`LARAVEL_` prefix keys)

These override the base keys when `laravel` profile is active.

```env
LARAVEL_REPO_ROOT=/Users/mac/Documents/workspace/abyan-backend
LARAVEL_GIT_BASE_BRANCH=master
LARAVEL_CODE_PATH=app

LARAVEL_SENTRY_ORG_SLUG=abyan-capital-hu
LARAVEL_SENTRY_PROJECT_SLUG=server-prod
LARAVEL_SENTRY_REGION_URL=https://us.sentry.io
LARAVEL_SENTRY_AUTH_TOKEN=""  # set in config.env

LARAVEL_BITBUCKET_WORKSPACE=robo-adv
LARAVEL_BITBUCKET_REPO_SLUG=abyan-backend
LARAVEL_BITBUCKET_AUTH=bearer
LARAVEL_BITBUCKET_ACCESS_TOKEN=""   # leave empty = push branch only, no auto-PR
LARAVEL_BITBUCKET_PR_ENABLED=false  # flip to true once token is available
```

> **Laravel PR note:** Bitbucket App Passwords were deprecated July 2026. New repository-level access tokens require repo admin access. Until the token is provided, the agent pushes the branch and Bitbucket shows a "Create pull request" banner automatically.
>
> To enable auto-PR later: set `LARAVEL_BITBUCKET_ACCESS_TOKEN` + `LARAVEL_BITBUCKET_PR_ENABLED=true`. Ask a repo admin to generate a token at:
> `https://bitbucket.org/robo-adv/abyan-backend/admin/access-tokens`

### All config variables reference

| Variable | Required | Description |
|---|---|---|
| `REPO_ROOT` | Yes | Absolute path to the app repo to fix |
| `GIT_BASE_BRANCH` | Yes | Branch to branch off from (`develop`, `master`) |
| `CODE_PATH` | Yes | `lib` (Flutter) / `app` (Laravel) / `src` (Node) |
| `PROJECT_PROFILE` | Yes | `flutter` \| `laravel` \| `generic` |
| `SENTRY_ORG_SLUG` | Yes | Your Sentry organization slug |
| `SENTRY_PROJECT_SLUG` | Yes | Sentry project slug to query |
| `SENTRY_REGION_URL` | No | Default: `https://us.sentry.io` |
| `SENTRY_AUTH_TOKEN` | Recommended | Enables REST pagination; scopes: org:read, project:read, event:read |
| `SENTRY_QUERY` | No | Default: `is:unresolved level:error` |
| `SENTRY_PAGE_SIZE` | No | Issues per page, max 100 (default: 100) |
| `SENTRY_MAX_PAGES` | No | Pages to prefetch per cycle (default: 10) |
| `SENTRY_TRIAGE_SIMPLE_FIRST` | No | `true` = tier1 before tier3 (default: true) |
| `BITBUCKET_WORKSPACE` | Yes | Bitbucket workspace slug |
| `BITBUCKET_REPO_SLUG` | Yes | Bitbucket repo slug |
| `BITBUCKET_AUTH` | Yes | `bearer` (token) or `basic` (email + token) |
| `BITBUCKET_ACCESS_TOKEN` | No | Leave empty to disable auto-PR (push branch only) |
| `BITBUCKET_PR_ENABLED` | No | `true` / `false` override (auto-set when token missing) |
| `BITBUCKET_PR_REVIEWERS` | No | Comma-separated usernames or account IDs |
| `PR_DRAFT` | No | `true` = open as draft PR (default: true) |
| `CLOSE_SOURCE_BRANCH` | No | `true` = delete fix branch after merge (default: true) |
| `CURSOR_BIN` | No | Path to `cursor` CLI (auto-detected if blank) |
| `CURSOR_AGENT_MODEL` | No | Default: `composer-2.5` |
| `CURSOR_API_KEY` | No | API key from cursor.com/settings (alternative to `cursor agent login`) |
| `POLL_SECONDS` | No | Seconds between cycles in loop/daemon mode (default: 300) |
| `AUTO_INSTALL_LAUNCHAGENT` | No | `true` = install background service on first `./run.sh` (default: true) |

---

## Triage system

The agent always fixes the highest-priority issue first.

| Tier | Issue types | Priority |
|---|---|---|
| **tier1** | `TypeError`, `NullPointerException`, null checks, auth errors (401/403), routing/navigation crashes, platform exceptions | **First** |
| **tier2** | Framework issues, provider/JSON/async errors, unexpected state in app code | Second |
| **tier3** | `App Hanging`, `ANR`, LaunchDarkly noise, third-party SDK errors (Adjust, Iterable), native-only stacks | **Last** |

Issues already branched (`origin/fix/sentry-*`) are automatically skipped.

---

## Fix quality rules

The agent is instructed to:

- Fix the **root cause** so the error stops occurring — not just stop it appearing in Sentry
- Match existing code patterns (Eloquent / null-safe operators for Laravel; Riverpod / mounted checks for Flutter)
- Never use `beforeSend` / Sentry filters as a fix for tier1 or tier2 issues
- Never write empty catch blocks or catch-and-ignore
- Prefer minimal diffs that a senior engineer would merge

If no safe fix exists, it prints `NO_ACTION` instead of pushing a risky PR.

---

## File layout

```
sentry-auto-fix/
├── run.sh                      # Main entrypoint — all commands live here
├── sentry_pagination.py        # Tier ranking + Sentry REST pagination
├── sentry_client.py            # Sentry REST API client
├── parse_agent_output.py       # Parse Cursor stream-json output
├── agent_runner.py             # Cursor agent prompt builder
├── bitbucket_client.py         # Bitbucket REST API client
├── webhook_server.py           # Optional: local Sentry webhook receiver
├── state.py                    # Processed issue state store
├── config.env                  # Your secrets (gitignored)
├── config.example.env          # Template with all variables
├── config.example.flutter.env  # Flutter-specific template
├── config.example.laravel.env  # Laravel-specific template
├── requirements.txt
└── .state/                     # Runtime state (gitignored)
    ├── flutter/
    │   ├── fix-worktree/       # Isolated git worktree for Flutter fixes
    │   ├── sentry-candidates.json
    │   ├── run.status
    │   └── run-result.env
    └── laravel/
        ├── fix-worktree/       # Isolated git worktree for Laravel fixes
        ├── sentry-candidates.json
        ├── run.status
        └── run-result.env
```

---

## Safety

| Concern | How it's handled |
|---|---|
| Your active branch | Saved before run, restored after — never touched |
| Code changes | Made only in `.state/<profile>/fix-worktree/` — isolated from your checkout |
| Secrets | `config.env` is gitignored — never committed |
| Bad fixes | Draft PRs only — requires human review and merge |
| Concurrent runs | Lock file prevents two runs at the same time |
| Crash recovery | Lock auto-released; run `./run.sh unlock` if stuck |
| Quality gates | Tests must pass for tier1/tier2; low confidence blocks PR |
| Rejection memory | Declined PR feedback stored and injected into future agent runs |

---

## Quality gates (post-agent, before PR)

After the agent pushes a branch, `quality_gates.py` runs automatically:

| Check | When | Action if failed |
|---|---|---|
| **FIX_CONFIDENCE** | Always | `low` blocks PR (config: `FIX_CONFIDENCE_MIN=medium`) |
| **Automated tests** | tier1 / tier2 | Must run and pass (`REQUIRE_TESTS_TIER12=true`) |
| **beforeSend ban** | tier1 / tier2 | Diff touching Sentry filters blocks PR |

Config in `config.env`:

```env
REQUIRE_TESTS_TIER12=true
TEST_GATE_ENABLED=true
FIX_CONFIDENCE_MIN=medium
TEST_TIMEOUT_SECONDS=600
```

Agent must write **Fix Strategy** and **Tests** sections in `pr-body.md` and print:

```text
FIX_CONFIDENCE=high|medium|low
FIX_STRATEGY=null_guard|auth_refresh|routing|...
TEST_COMMAND=flutter test test/foo_test.dart
TEST_RESULT=PASSED
```

---

## PR rejection feedback loop

When reviewers decline or comment on auto-fix PRs, capture the lesson so the agent does not repeat it.

| Command | Description |
|---|---|
| `./run.sh record-rejection ROBO-STAGING-F8 "beforeSend filter not acceptable"` | Manual entry |
| `./run.sh list-rejections` | Show stored lessons |
| `./run.sh sync-pr-feedback` | Import declined / commented `fix/sentry-*` PRs from Bitbucket |

Lessons are stored in `.state/<profile>/rejection-lessons.json` and injected into every agent prompt.

Auto-sync on each run: `SYNC_PR_FEEDBACK_ON_RUN=true` (default).

---

## Slack notifications (status channel)

Preferred: **Bot token + channel ID** (no Incoming Webhook). See `docs/SLACK_STATUS.md`.

```env
SLACK_BOT_TOKEN=xoxb-…
SLACK_CHANNEL_ID=C0BGPF244H3          # from channel URL …/archives/C…
SLACK_NOTIFY_ENABLED=true
SLACK_NOTIFY_CODEGUARDIAN=true
SLACK_NOTIFY_PR_MERGED=true
```

Invite the bot to the channel, then: `./run.sh flutter test-slack`

| Event | Slack |
|-------|-------|
| Draft PR created | 📋 PR link + issue/branch |
| PR merged | ✅ polled from Bitbucket each cycle |
| CodeGuardian passed / failed | 🛡️ / 🛑 + detail |
| Quality gate / agent / no_action | 🚫 / ⚠️ / ⏭️ |

Optional fallback: `SLACK_WEBHOOK_URL` if bot token is not available.

---
