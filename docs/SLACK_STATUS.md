# Slack status channel

Preferred setup: **Bot token + channel ID** (no Incoming Webhook).

## 1. Create a Slack channel

Example: `#abyan-sentry-autofix` in the Abyan / robo-advisory workspace.

Open the channel → the URL looks like:

`https://robo-advisorygroup.slack.com/archives/C0BGPF244H3`

**Channel ID** = `C0BGPF244H3` (the `C…` part).

## 2. Slack app (Bot) — once per workspace

1. [https://api.slack.com/apps](https://api.slack.com/apps) → Create app → From scratch  
2. **OAuth & Permissions** → Bot Token Scopes → add `chat:write`  
   (optional: `chat:write.public` if the bot posts without joining)  
3. **Install to Workspace** → copy **Bot User OAuth Token** (`xoxb-…`)  
4. Invite the bot to the channel: `/invite @YourBotName`

## 3. `config.env` (Abyan Capital machine)

```env
SLACK_BOT_TOKEN=xoxb-…
SLACK_CHANNEL_ID=C0BGPF244H3
SLACK_NOTIFY_ENABLED=true
SLACK_NOTIFY_CODEGUARDIAN=true
SLACK_NOTIFY_PR_MERGED=true
# SLACK_WEBHOOK_URL=   # leave empty when using bot+channel
```

## 4. Test

```bash
./run.sh flutter test-slack
```

## Events

Same as before: PR created, PR merged (polled), CodeGuardian pass/fail, quality gate, agent failed, no_action.

## Fallback

If bot install is blocked, you can still set `SLACK_WEBHOOK_URL` instead. Bot + channel ID is preferred.
