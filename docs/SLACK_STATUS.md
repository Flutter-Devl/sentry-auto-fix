# Slack status channel (Phase 2)

Incoming Webhook posts full run status to one Slack channel.

## Setup (one time)

1. In Slack, open the channel → **Integrations** → **Incoming Webhooks** → Add  
2. Copy the URL (`https://hooks.slack.com/services/...`)  
3. In `config.env`:

```env
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/T…/B…/…
SLACK_NOTIFY_ENABLED=true
SLACK_NOTIFY_CODEGUARDIAN=true
SLACK_NOTIFY_PR_MERGED=true
SLACK_NOTIFY_RUN_START=false
```

4. Test:

```bash
./run.sh flutter test-slack
```

## Events

| Event | When |
|--------|------|
| `pr_created` | Draft Bitbucket PR opened |
| `pr_merged` | Tracked autofix PR becomes `MERGED` (polled each cycle) |
| `codeguardian_passed` | CodeGuardian validate passed on the fix worktree |
| `codeguardian_failed` | CodeGuardian failed (blocks PR when configured) |
| `quality_gate_failed` | Tests / confidence / beforeSend policy blocked PR |
| `branch_pushed` | Branch on origin but no PR |
| `agent_failed` | Cursor agent non-zero exit |
| `no_action` | Nothing to fix this cycle |
| `run_started` | Only if `SLACK_NOTIFY_RUN_START=true` |

Each message includes profile, Sentry issue, branch, PR link, gate reason, and a detail block (CG/test output truncated for Slack limits).

## PR merged how it works

1. When a draft PR is created, its id is stored in `.state/<profile>/tracked-prs.json`  
2. Each `./run.sh … once` / daemon cycle calls Bitbucket for tracked PRs  
3. Newly `MERGED` PRs post `pr_merged` once (who merged + commit when available)

Latency ≈ your `POLL_SECONDS` (e.g. 15 minutes), not instant webhooks.
