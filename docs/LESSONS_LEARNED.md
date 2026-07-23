# Lessons learned (sentry-auto-fix)

Hard constraints from real incidents. Also mirrored in `.cursor/rules/lessons-learned.mdc`.

## 2026-07-23 — False “tests/CodeGuardian passed” on NO_ACTION

**Symptom:** Slack showed CodeGuardian/gates passed (and PR create failed) when the agent correctly chose no fix.

**Root cause:** Agent emitted `BRANCH_NAME=none` with `NO_ACTION`. Parser treated `none` as a real branch, so gates ran against the empty worktree and Slack fired success events.

**Fix / policy:**
- Ignore placeholder field values in `parse_agent_output.py`.
- Skip quality gates unless `BRANCH_NAME` matches `fix/sentry-*`.
- Slack success paths (tests/CG/gates/branch) require a real fix branch; otherwise only `no_action`.
- Prompt: on `NO_ACTION`, do not print placeholder `BRANCH_NAME` / `ISSUE_*` / `TEST_*` lines.

## Related (same combined branch work)

- Do not list `beforeSend` as an agent Possible Solution.
- CodeGuardian Slack must summarize findings, not paste raw JSON.
- Enable and wire CG + test Slack events; draft-PR-only status is incomplete.
