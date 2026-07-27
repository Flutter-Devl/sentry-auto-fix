# Slack status channel

Posts PR / CodeGuardian / gate status to a Slack channel.

**Preferred:** Slack Bot (`chat.postMessage`) — same pattern as Agile Assistant.  
**Fallback:** Incoming Webhook URL.

## Setup — Slack Bot (recommended)

1. Go to [https://api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From scratch**.
2. Name it (e.g. `Sentry Auto-Fix`) and pick workspace `robo-advisorygroup`.
3. **OAuth & Permissions** → Bot Token Scopes → add:
   - `chat:write` (required)
   - `channels:read` (optional, helpful)
   - `reactions:read` only if you need reactions later
4. **Install to Workspace** → Approve.
5. Copy **Bot User OAuth Token** (`xoxb-...`) → `SLACK_BOT_TOKEN`.
6. Open your status channel (or create one). Copy link; ID is the last segment starting with `C`  
   (example: `https://robo-advisorygroup.slack.com/archives/C0BGPF244H3` → `C0BGPF244H3`).
7. Set `SLACK_CHANNEL_ID=C0BGPF244H3` (or `SLACK_REVIEW_CHANNEL_ID` — both work).
8. In the channel: `/invite @Sentry Auto-Fix` (your app name).

`SLACK_SIGNING_SECRET` is **not required** for status posts (only for inbound slash commands / interactivity).

```env
SLACK_BOT_TOKEN=xoxb-...
SLACK_CHANNEL_ID=C0BGPF244H3
SLACK_NOTIFY_ENABLED=true
SLACK_NOTIFY_CODEGUARDIAN=true
SLACK_NOTIFY_PR_MERGED=true
```

Test:

```bash
./run.sh flutter test-slack
```

## Setup — Incoming Webhook (optional fallback)

If your workspace allows Incoming Webhooks, you can set `SLACK_WEBHOOK_URL` instead.  
Bot token takes priority when both are set.

## Events

| Event | When |
|--------|------|
| `gates_passed` / `quality_gate_failed` | Tests + CodeGuardian outcome |
| `pr_created` | Draft Bitbucket PR opened |
| `pr_merged` / `pr_declined` | Tracked PR becomes MERGED or DECLINED (polled each cycle) |
| `sentry_resolved` | Auto-resolved in Sentry after merge + quiet window |
| `sentry_resolve_ready` | Quiet enough to resolve (`SENTRY_RESOLVE_AFTER_MERGE=prompt`) |
| `sentry_still_noisy` | PR merged but issue still getting events |
| `sentry_resolve_failed` / `sentry_resolve_abandoned` | Resolve error or gave up after max age |
| `branch_pushed` / `agent_failed` / `no_action` | As labeled |

**Merged / declined:** messages are sent on the **next** autofix cycle (daemon/`once`), not instantly when someone clicks merge in Bitbucket.

### Sentry resolve after merge

```env
SENTRY_RESOLVE_AFTER_MERGE=auto   # auto | prompt | off
SENTRY_RESOLVE_MIN_AGE_HOURS=6
SENTRY_RESOLVE_MAX_AGE_DAYS=14
```

- **auto** — after min age, if `lastSeen` is still before merge (± skew), resolve the issue and Slack `sentry_resolved`.
- **prompt** — when quiet, Slack `sentry_resolve_ready` with `./run.sh resolve-issue SHORT_ID` (no auto resolve).
- **off** — manual only.

Token needs **event:write** or **issue:write** (plus read scopes) for `auto`.

For **declined** PRs, Slack includes **Rejection reason** from the reviewer’s Bitbucket comment (when present), and stores it in rejection lessons for future agent runs.

## PR body Quality section

Draft Bitbucket PRs include a **## Quality** checklist (Tests + CodeGuardian summary) from the gate run so reviewers do not need Slack.

## PR merged

Tracked in `.state/<profile>/tracked-prs.json` and polled each cycle (~`POLL_SECONDS`).
