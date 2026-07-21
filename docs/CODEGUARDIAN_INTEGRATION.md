# Combining CodeGuardian AI + Sentry Auto-Fix

**Branch:** `feature/codeguardian-integration`  
**Repos:**
- [CodeGuardian AI Flutter](https://github.com/suleman1994/codeGuardianAIFlutter)
- [Sentry Auto-Fix](https://github.com/Flutter-Devl/sentry-auto-fix)

---

## How they differ (do not merge into one tool)

| | **CodeGuardian AI** | **Sentry Auto-Fix** |
|--|---------------------|---------------------|
| **When** | **Before** merge / in CI | **After** production errors |
| **Input** | Local Flutter/Dart source + AndroidManifest / Info.plist | Live Sentry issues (stack traces, events) |
| **How** | Deterministic AST rules + optional Anthropic AI | Cursor Agent + Sentry MCP |
| **Output** | Findings (HTML / Markdown / SARIF), score, optional deterministic fixes | `fix/sentry-*` branch + draft Bitbucket PR |
| **Language** | Pure Dart CLI (Melos monorepo) | Bash + Python + Cursor CLI |
| **Best at** | Security, privacy, performance, `mounted` guards, secrets | Real crashes: TypeError, auth, routing, PlatformException |

They are **complementary**:

- CodeGuardian = **prevent** bad code from shipping  
- Sentry Auto-Fix = **remediate** what still reaches users  

Do **not** replace one with the other. Wire them into one **lifecycle**.

---

## Better end-to-end flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│  PHASE A — PREVENT (CodeGuardian)                                       │
│  Developer PR / CI                                                      │
│    → codeguardian analyze / validate                                    │
│    → block merge if gates fail (max_critical, min_score)                │
│    → optional deterministic auto-fix + SARIF upload                     │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │ code ships
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  PHASE B — DETECT (Sentry)                                              │
│  Unresolved issues on robo-staging / mob-prod / server-prod             │
└───────────────────────────────┬─────────────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  PHASE C — REMEDIATE (Sentry Auto-Fix)                                  │
│  Tier triage → Cursor Agent root-cause fix → tests → quality gates      │
│    → **NEW:** CodeGuardian validate on worktree (Flutter only)          │
│    → draft Bitbucket PR + Slack notify                                  │
└───────────────────────────────┬─────────────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  PHASE D — LEARN                                                        │
│  PR reject → rejection-lessons.json                                     │
│  Merged → optional Sentry resolve + Slack                               │
│  High-severity CodeGuardian rules that match past Sentry issues          │
│    → feed back into rules / triage markers                              │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Recommended integration (keep repos separate)

### 1. Soft couple via CLI (recommended)

Keep both GitHub repos independent. From **sentry-auto-fix** `quality_gates.py` / `run.sh`, after the agent fix and unit tests:

```bash
# Only for PROJECT_PROFILE=flutter
dart run /path/to/codeGuardianAIFlutter/.../codeguardian.dart validate \
  -p "$WORKTREE_PATH"
```

If exit code `1` (gate failure) → treat like today’s quality-gate fail → **block draft PR**.

**Config (sentry-auto-fix `config.env`):**

```env
CODEGUARDIAN_ENABLED=true
CODEGUARDIAN_CLI=/path/to/codeguardian   # or "dart run .../codeguardian.dart"
CODEGUARDIAN_MODE=validate               # analyze | validate
CODEGUARDIAN_MIN_SCORE=80
CODEGUARDIAN_FAIL_BLOCKS_PR=true
```

### 2. CI pipeline (Bitbucket / GitHub Actions)

On every PR into Abyan Flutter:

```yaml
# prevent
- codeguardian validate -p .
# optional
- codeguardian analyze -p . -f sarif > results.sarif
```

On schedule / LaunchAgent (unchanged):

```bash
./run.sh flutter once   # remediate; now includes CodeGuardian gate
```

### 3. Shared “lessons” (later)

| Source | Feed into |
|--------|-----------|
| Sentry rejection lessons (`beforeSend`, filter-only) | Agent prompt (already) |
| Repeated Sentry tier1 patterns (`mounted`, null) | New / stricter CodeGuardian rules |
| CodeGuardian critical findings that later crash in Sentry | Triage boost for matching markers |

### 4. What **not** to do

| Anti-pattern | Why |
|--------------|-----|
| Vendor CodeGuardian packages *inside* sentry-auto-fix | Different stack (Dart Melos vs Bash/Python); hard to maintain |
| Replace Cursor Agent with CodeGuardian fixer only | CodeGuardian fixes are **deterministic** and limited; Sentry needs **runtime context** (MCP) |
| Run CodeGuardian on Laravel profile | CodeGuardian is Flutter/Dart-only |
| Auto-merge either tool’s PRs | Keep human review |

---

## Concrete ownership

| Team / tool | Owns |
|-------------|------|
| **CodeGuardian** | Static rules, CI gate, security/perf reports for Flutter |
| **Sentry Auto-Fix** | Production triage, Cursor fix, Bitbucket draft PR, Slack, rejection memory |
| **Abyan Flutter repo** | `codeguardian.yaml` + baseline; `REPO_ROOT` for auto-fix |
| **Abyan Backend** | Laravel profile of sentry-auto-fix only (no CodeGuardian) |

---

## Implementation checklist on this branch

- [x] Design doc (`docs/CODEGUARDIAN_INTEGRATION.md`)
- [x] Config keys in `config.example.env` (points at `dev/v1.0` root CLI — not nested scaffold)
- [x] `quality_gates.py` hook: optional CodeGuardian `validate` after tests
- [x] `run.sh`: pass `CODEGUARDIAN_*` env into quality gates
- [x] `codeguardian_gate.py` + `test_codeguardian_gate.py`
- [x] Combined flow guide (`docs/COMBINED_FLOW.md`)
- [ ] Optional: Slack note when CG fails
- [ ] Optional: `ci_templates/bitbucket-codeguardian.yml` example for app repo

---

## Expected outcomes for management

| Metric | Prevent (CodeGuardian) | Remediate (Sentry Auto-Fix) |
|--------|------------------------|-----------------------------|
| Secrets / cleartext HTTP | Caught in CI | Rarely appears in Sentry |
| `mounted` after await | Caught statically | Still auto-fixable if missed |
| Unknown production crash | — | Detected → draft PR |
| MTTR | Lower incident volume | Faster fix once live |
| Review load | Gate PR before merge | Review draft fix PR only |

**Pitch line:**  
> CodeGuardian stops known Flutter anti-patterns before release; Sentry Auto-Fix closes the loop on real production failures with human-reviewed PRs — one lifecycle, two specialized engines.

---

## Quick start (after hooks land)

```bash
# Terminal A — install CodeGuardian once (branch with real CLI)
git clone https://github.com/suleman1994/codeGuardianAIFlutter.git
cd codeGuardianAIFlutter
git checkout origin/dev/v1.0 -B dev/v1.0
melos bootstrap
./run-codeguardian.sh validate -p /path/to/abyan-app-flutter   # must emit JSON findings

# Terminal B — sentry-auto-fix
cd /Users/mehsarairfan/sentry-auto-fix
# config.env:
#   CODEGUARDIAN_ENABLED=true
#   CODEGUARDIAN_CLI=/absolute/path/to/codeGuardianAIFlutter/run-codeguardian.sh
./run.sh flutter once
```

When a Sentry fix introduces a critical static finding, the PR is blocked until the agent (or a human) remediates it — same gate philosophy as `TEST_GATE_ENABLED`.
