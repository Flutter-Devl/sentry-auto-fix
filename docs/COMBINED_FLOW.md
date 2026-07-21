# Sentry Auto-Fix + CodeGuardian AI — Combined Flow

**Document purpose:** Explain how the two tools work together, what changed in our repo, and the new end-to-end workflow.  
**Audience:** Engineering leads, mobile/backend team, AI / management committee  
**Branch:** `feature/codeguardian-integration` on [Flutter-Devl/sentry-auto-fix](https://github.com/Flutter-Devl/sentry-auto-fix)  
**Date:** July 2026  

---

## 1. Executive summary

We did **not** merge the two GitHub repositories into one codebase.

We **combined them in a pipeline**:

| Tool | Repo | Role |
|------|------|------|
| **Sentry Auto-Fix** | [Flutter-Devl/sentry-auto-fix](https://github.com/Flutter-Devl/sentry-auto-fix) | Detects live Sentry issues → AI fix → draft Bitbucket PR |
| **CodeGuardian AI** | [suleman1994/codeGuardianAIFlutter](https://github.com/suleman1994/codeGuardianAIFlutter) | Static analysis of Flutter/Dart (security, correctness, performance) |

**Result:** CodeGuardian **prevents** known Flutter bad patterns before / around merge; Sentry Auto-Fix **remediates** real production crashes. After an auto-fix, CodeGuardian can optionally **re-scan the fix worktree** and block the draft PR if static gates fail.

---

## 2. Why combine (not replace)

| Problem | Better owner |
|---------|----------------|
| Hardcoded secrets, cleartext HTTP, missing `mounted` after `await` | **CodeGuardian** (static rules, CI) |
| Live TypeError / auth / GoRouter crash with full stack + breadcrumbs | **Sentry Auto-Fix** (Sentry MCP + Cursor Agent) |
| Vendor App Hang noise | Sentry triage (tier3) / often `NO_ACTION` |
| Proving a fix didn’t introduce new Flutter anti-patterns | **CodeGuardian validate** on the fix branch |

Replacing one with the other leaves a gap. Combining them covers **prevent → detect → remediate → gate → review**.

---

## 3. How we combined (architecture)

### Soft couple via CLI (chosen approach)

```
┌────────────────────────┐     ┌────────────────────────────┐
│  codeGuardianAIFlutter │     │  sentry-auto-fix            │
│  (own GitHub repo)     │     │  (own GitHub repo)         │
│  Dart Melos monorepo   │     │  Bash + Python + Cursor    │
└───────────┬────────────┘     └─────────────┬──────────────┘
            │                                │
            │  CLI: validate -p <worktree>   │
            │◄───────────────────────────────┤
            │         (optional hook)        │
            └────────────────────────────────┘
```

- Repos stay **separate** (different languages and release cycles).
- sentry-auto-fix calls CodeGuardian only when `CODEGUARDIAN_ENABLED=true`.
- Flutter profile only; Laravel profile skips CodeGuardian.

### What we deliberately did **not** do

- Did **not** copy CodeGuardian Dart packages into sentry-auto-fix  
- Did **not** replace Cursor Agent with CodeGuardian’s deterministic fixer  
- Did **not** enable the hook by default (opt-in until CLI path is configured)  
- Did **not** change Abyan Flutter app structure for this (CI gate in app repo is a follow-up)

---

## 4. What actually changed (in sentry-auto-fix)

Branch: **`feature/codeguardian-integration`**

| Change | File | What it does |
|--------|------|----------------|
| Design doc | `docs/CODEGUARDIAN_INTEGRATION.md` | Technical design, anti-patterns, ownership |
| **This guide** | `docs/COMBINED_FLOW.md` | Combined flow for team / management |
| New gate helper | `codeguardian_gate.py` | Runs CodeGuardian CLI against the fix worktree |
| Quality gates update | `quality_gates.py` | After tests → optional CodeGuardian validate |
| Orchestrator update | `run.sh` | Passes `CODEGUARDIAN_*` env into quality gates |
| Config template | `config.example.env` | Documents enable/CLI/mode/timeout/fail flags |

### Config keys (opt-in)

```env
CODEGUARDIAN_ENABLED=false          # set true when CLI is installed
CODEGUARDIAN_CLI=""                 # e.g. dart run /path/to/.../codeguardian.dart
CODEGUARDIAN_MODE=validate          # analyze | validate
CODEGUARDIAN_TIMEOUT=600
CODEGUARDIAN_FAIL_BLOCKS_PR=true    # fail → no draft PR
```

### Unchanged (same as before)

- Sentry pagination & tier triage  
- Cursor Agent + Sentry MCP fix loop  
- Isolated git worktree  
- Unit/widget test gate (tier1/tier2)  
- Rejection lessons + Slack (Phase 1)  
- Bitbucket draft PR creation  
- Laravel profile (no CodeGuardian)

---

## 5. Flow now (end-to-end)

### Phase A — Prevent (CodeGuardian in CI — recommended next step)

```
Developer opens PR on abyan-app-flutter
        ↓
CodeGuardian validate (Bitbucket/GitHub CI)
        ↓
Pass → review / merge
Fail → block merge until findings fixed
```

*Note: App-repo CI wiring is recommended but not shipped inside the Flutter app in this branch; only the auto-fix hook exists today.*

### Phase B — Detect (Sentry)

```
Unresolved issues on robo-staging / mob-prod (or server-prod for Laravel)
        ↓
sentry-auto-fix poll / LaunchAgent / ./run.sh flutter once
```

### Phase C — Remediate + gate (Sentry Auto-Fix + optional CodeGuardian)

```
1. Tier triage (tier1 app bugs first)
2. Isolated worktree from GIT_BASE_BRANCH
3. Cursor Agent: root-cause fix (no beforeSend for tier1/2)
4. Agent adds/runs targeted tests
5. quality_gates.py:
      - FIX_CONFIDENCE
      - beforeSend ban
      - flutter test / php artisan test
      - [NEW] CodeGuardian validate (if enabled, Flutter only)
6. If all pass → draft Bitbucket PR + Slack notify
7. If CodeGuardian/tests fail → QUALITY_GATE_FAILED → PR blocked
```

### Phase D — Learn & close

```
Human reviews draft PR
  → Merge → deploy → ./run.sh resolve-issue <SHORT_ID>
  → Decline → comment + record-rejection / sync-pr-feedback
        ↓
Lessons injected into next agent run
```

### Diagram (current combined lifecycle)

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────────┐
│  Developer  │────►│ CodeGuardian │────►│ Merge / Deploy      │
│  PR (CI)    │     │  PREVENT     │     │ (Abyan Flutter)     │
└─────────────┘     └──────────────┘     └──────────┬──────────┘
                                                    │
                                                    ▼
┌─────────────┐     ┌──────────────┐     ┌─────────────────────┐
│   Sentry    │────►│ Sentry Auto- │────►│ Cursor fix + tests  │
│  DETECT     │     │ Fix REMEDIATE│     └──────────┬──────────┘
└─────────────┘     └──────────────┘                │
                                                    ▼
                                         ┌─────────────────────┐
                                         │ CodeGuardian GATE   │
                                         │ (optional, Flutter) │
                                         └──────────┬──────────┘
                                                    │
                         ┌──────────────────────────┼──────────────────────────┐
                         ▼                          ▼                          ▼
                   Draft PR + Slack          Gate failed                 NO_ACTION
                   (human review)            (no auto PR)                (sleep/next)
```

---

## 6. Day-to-day commands

```bash
cd /Users/mehsarairfan/sentry-auto-fix
git checkout feature/codeguardian-integration

# Normal auto-fix (CodeGuardian off until configured)
./run.sh flutter once
./run.sh flutter status

# After installing CodeGuardian locally — enable in config.env:
# CODEGUARDIAN_ENABLED=true
# CODEGUARDIAN_CLI=dart run /path/to/.../codeguardian.dart
./run.sh flutter once
```

Install CodeGuardian (once):

```bash
git clone https://github.com/suleman1994/codeGuardianAIFlutter.git
cd codeGuardianAIFlutter
dart pub global activate melos
melos bootstrap
```

Then set `CODEGUARDIAN_CLI` to the `dart run …/codeguardian.dart` path for your machine.

---

## 7. Before vs after this work

| | Before | After (`feature/codeguardian-integration`) |
|--|--------|--------------------------------------------|
| Static Flutter scan on auto-fix PRs | No | Optional via CodeGuardian |
| Production Sentry → draft PR | Yes | Yes (unchanged) |
| Unit tests before PR | Yes (tier1/2) | Yes + optional CodeGuardian |
| Single merged mega-repo | N/A | Still two repos |
| Laravel | Auto-fix only | Same (no CodeGuardian) |
| Default config | — | CodeGuardian **off** until CLI set |

---

## 8. Safety & governance (unchanged principles)

- Draft PRs only — no auto-merge  
- Human review required  
- Secrets only in local `config.env` (gitignored)  
- Worktree isolation — developer branch untouched  
- Root-cause fixes preferred; `beforeSend` banned for tier1/tier2  
- CodeGuardian failure can block PR when `CODEGUARDIAN_FAIL_BLOCKS_PR=true`

---

## 9. Roadmap after this branch

| Phase | Work |
|-------|------|
| **Now** | Merge `feature/codeguardian-integration`; enable CodeGuardian when CLI is ready |
| **Next** | Add CodeGuardian `validate` to Abyan Flutter Bitbucket CI on every PR |
| **Later** | Slack message when CodeGuardian fails; map recurring Sentry issues → new CodeGuardian rules |
| **Later** | Linux/CI runner (reduce Mac dependency) |

---

## 10. Pitch line (for presentations)

> **CodeGuardian** stops known Flutter anti-patterns before release.  
> **Sentry Auto-Fix** closes the loop on real production failures with human-reviewed PRs.  
> Together: **prevent → detect → remediate → gate → review** — two specialized engines, one quality lifecycle.

---

## 11. References

| Resource | Link |
|----------|------|
| Sentry Auto-Fix repo | https://github.com/Flutter-Devl/sentry-auto-fix |
| Integration branch | https://github.com/Flutter-Devl/sentry-auto-fix/tree/feature/codeguardian-integration |
| Open PR from branch | https://github.com/Flutter-Devl/sentry-auto-fix/pull/new/feature/codeguardian-integration |
| CodeGuardian repo | https://github.com/suleman1994/codeGuardianAIFlutter |
| Technical design | `docs/CODEGUARDIAN_INTEGRATION.md` |
| Local toolkit path | `/Users/mehsarairfan/sentry-auto-fix` |
