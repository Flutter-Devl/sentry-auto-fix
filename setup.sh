#!/usr/bin/env bash
# Quick setup checks for sentry-auto-fix
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Python venv"
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
pip install -q -r requirements.txt

echo "==> Load config"
if [[ ! -f config.env ]]; then
  echo "Missing config.env — copy from config.example.env"
  exit 1
fi
set -a && source config.env && set +a

echo "==> Cursor auth"
if [[ -z "${CURSOR_API_KEY:-}" ]]; then
  echo "CURSOR_API_KEY empty — run: cursor agent login"
  cursor agent login || true
fi
cursor agent --print "Reply OK" || {
  echo "Cursor auth failed. Set CURSOR_API_KEY in config.env or run cursor agent login"
  exit 1
}

echo "==> Sentry API"
python - <<'PY'
import os, requests
token = os.environ["SENTRY_AUTH_TOKEN"]
org = os.environ["SENTRY_ORG_SLUG"]
url = f"{os.environ.get('SENTRY_REGION_URL', 'https://us.sentry.io').rstrip('/')}/api/0/organizations/{org}/issues/"
r = requests.get(url, headers={"Authorization": f"Bearer {token}"}, params={"query": "is:unresolved", "limit": 1}, timeout=30)
r.raise_for_status()
print(f"Sentry OK — sample issues returned: {len(r.json())}")
PY

if [[ "${BITBUCKET_ACCESS_TOKEN:-}" == *PASTE_* ]] || [[ -z "${BITBUCKET_ACCESS_TOKEN:-}" ]]; then
  echo "WARN: Set BITBUCKET_ACCESS_TOKEN in config.env before real runs"
else
  echo "==> Bitbucket API"
  python - <<'PY'
import os, requests
ws = os.environ["BITBUCKET_WORKSPACE"]
repo = os.environ["BITBUCKET_REPO_SLUG"]
token = os.environ["BITBUCKET_ACCESS_TOKEN"]
url = f"https://api.bitbucket.org/2.0/repositories/{ws}/{repo}"
r = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=30)
r.raise_for_status()
print(f"Bitbucket OK — repo: {r.json().get('full_name')}")
PY
fi

echo ""
echo "All checks done. Next:"
echo "  DRY_RUN=true python orchestrator.py poll"
echo "  python orchestrator.py fix --issue-id <NUMERIC_ID>"
