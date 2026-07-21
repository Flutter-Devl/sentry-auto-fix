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

## One-time setup (then it keeps running)

```bash
git clone https://github.com/Flutter-Devl/sentry-auto-fix.git
cd sentry-auto-fix
git checkout feature/combined-sentry-codeguardian

./setup.sh              # venv + Melos + wire CODEGUARDIAN_*
# edit config.env once (REPO_ROOT, Sentry, Bitbucket, Cursor)

./setup.sh --auto       # install Flutter LaunchAgent — automation forever
# or: ./run.sh flutter start
```

Same bash automation model as classic Sentry Auto-Fix: deps once, then background daemon. CodeGuardian validate runs inside each Flutter fix cycle automatically.

```bash
./run.sh flutter status
./run.sh flutter auto-status
./run.sh flutter stop-auto
./run.sh flutter once          # foreground one-shot
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
