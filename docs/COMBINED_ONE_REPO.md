# Combined branch: Sentry Auto-Fix + CodeGuardian (one clone)

**Branch:** `feature/combined-sentry-codeguardian`  
**Model:** one GitHub repo, one checkout, one `./setup.sh` for dependencies.

## What’s in this branch

| Piece | Location | Role |
|-------|----------|------|
| Sentry → Cursor → Bitbucket | repo root (`run.sh`, …) | Detect & remediate production issues |
| CodeGuardian CLI | `vendor/codeguardian/` | Static Flutter gate on fix worktrees |
| Gate hook | `codeguardian_gate.py` + `quality_gates.py` | Runs after unit tests, can block draft PR |

Dashboard/server from upstream CodeGuardian are **not** vendored — only packages needed for `validate` / `analyze`.

Upstream source: [codeGuardianAIFlutter `dev/v1.0`](https://github.com/suleman1994/codeGuardianAIFlutter) (see `vendor/codeguardian/VENDOR_INFO.txt`).

## One-time setup

```bash
git clone https://github.com/Flutter-Devl/sentry-auto-fix.git
cd sentry-auto-fix
git checkout feature/combined-sentry-codeguardian
./setup.sh          # venv + melos bootstrap + wire CODEGUARDIAN_* in config.env
# edit config.env
./run.sh flutter once
# optional background:
./run.sh flutter install-auto
```

`setup.sh` does **deps only** — LaunchAgent stays on `install-auto` / first `start`.

## Day-to-day

Same as before:

```bash
./run.sh flutter once
./run.sh flutter start
./run.sh flutter status
```

CodeGuardian alone:

```bash
./vendor/codeguardian/bin/codeguardian.sh validate -p /path/to/abyan-app-flutter
```

## Disable CodeGuardian

In `config.env`:

```env
CODEGUARDIAN_ENABLED=false
```

## Soft-couple branch

`feature/codeguardian-integration` still documents an external CLI path. Prefer this combined branch for production machines that should use a single clone.
