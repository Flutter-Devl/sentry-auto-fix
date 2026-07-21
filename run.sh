#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

# ---------------------------------------------------------------------------
# Profile argument — optional first positional arg: flutter | laravel
# Shift it off so remaining positional args ($1, $2, ...) are the subcommand.
# Examples:
#   ./run.sh once                → flutter (default)
#   ./run.sh flutter once        → flutter profile explicitly
#   ./run.sh laravel daemon      → laravel profile
# ---------------------------------------------------------------------------
ACTIVE_PROFILE=""
if [[ "${1:-}" == "flutter" || "${1:-}" == "laravel" ]]; then
  ACTIVE_PROFILE="$1"
  shift
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing config.env. Run: cp config.example.env config.env"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

# ---------------------------------------------------------------------------
# Finalize active profile: CLI arg > config PROJECT_PROFILE > default flutter
# ---------------------------------------------------------------------------
ACTIVE_PROFILE="${ACTIVE_PROFILE:-${PROJECT_PROFILE:-flutter}}"

# ---------------------------------------------------------------------------
# Laravel profile overlay — override base keys with LARAVEL_* values so the
# rest of the script is profile-agnostic (it always reads the base key names).
# ---------------------------------------------------------------------------
if [[ "$ACTIVE_PROFILE" == "laravel" ]]; then
  [[ -n "${LARAVEL_REPO_ROOT:-}"              ]] && REPO_ROOT="$LARAVEL_REPO_ROOT"
  [[ -n "${LARAVEL_GIT_BASE_BRANCH:-}"        ]] && GIT_BASE_BRANCH="$LARAVEL_GIT_BASE_BRANCH"
  [[ -n "${LARAVEL_CODE_PATH:-}"              ]] && CODE_PATH="$LARAVEL_CODE_PATH"
  [[ -n "${LARAVEL_SENTRY_ORG_SLUG:-}"        ]] && SENTRY_ORG_SLUG="$LARAVEL_SENTRY_ORG_SLUG"
  [[ -n "${LARAVEL_SENTRY_PROJECT_SLUG:-}"    ]] && SENTRY_PROJECT_SLUG="$LARAVEL_SENTRY_PROJECT_SLUG"
  [[ -n "${LARAVEL_SENTRY_REGION_URL:-}"      ]] && SENTRY_REGION_URL="$LARAVEL_SENTRY_REGION_URL"
  [[ -n "${LARAVEL_SENTRY_QUERY:-}"           ]] && SENTRY_QUERY="$LARAVEL_SENTRY_QUERY"
  [[ -n "${LARAVEL_SENTRY_AUTH_TOKEN:-}"      ]] && SENTRY_AUTH_TOKEN="$LARAVEL_SENTRY_AUTH_TOKEN"
  [[ -n "${LARAVEL_BITBUCKET_WORKSPACE:-}"    ]] && BITBUCKET_WORKSPACE="$LARAVEL_BITBUCKET_WORKSPACE"
  [[ -n "${LARAVEL_BITBUCKET_REPO_SLUG:-}"    ]] && BITBUCKET_REPO_SLUG="$LARAVEL_BITBUCKET_REPO_SLUG"
  [[ -n "${LARAVEL_BITBUCKET_AUTH:-}"         ]] && BITBUCKET_AUTH="$LARAVEL_BITBUCKET_AUTH"
  [[ -n "${LARAVEL_BITBUCKET_EMAIL:-}"        ]] && BITBUCKET_EMAIL="$LARAVEL_BITBUCKET_EMAIL"
  [[ -n "${LARAVEL_BITBUCKET_ACCESS_TOKEN:-}" ]] && BITBUCKET_ACCESS_TOKEN="$LARAVEL_BITBUCKET_ACCESS_TOKEN"
  [[ -n "${LARAVEL_BITBUCKET_PR_ENABLED:-}"   ]] && BITBUCKET_PR_ENABLED="$LARAVEL_BITBUCKET_PR_ENABLED"
  [[ -n "${LARAVEL_BITBUCKET_PR_REVIEWERS:-}" ]] && BITBUCKET_PR_REVIEWERS="$LARAVEL_BITBUCKET_PR_REVIEWERS"
  PROJECT_PROFILE="laravel"
fi

: "${REPO_ROOT:?REPO_ROOT is required in config.env (or LARAVEL_REPO_ROOT for laravel profile)}"
: "${SENTRY_ORG_SLUG:?SENTRY_ORG_SLUG is required}"
: "${SENTRY_PROJECT_SLUG:?SENTRY_PROJECT_SLUG is required}"

# PR creation is optional — if no token is set, agent pushes the branch and you open the PR manually
if [[ -z "${BITBUCKET_ACCESS_TOKEN:-}" ]]; then
  BITBUCKET_PR_ENABLED=false
fi

CURSOR_BIN="${CURSOR_BIN:-cursor}"
CURSOR_AGENT_MODEL="${CURSOR_AGENT_MODEL:-composer-2.5}"
GIT_BASE_BRANCH="${GIT_BASE_BRANCH:-develop}"
CODE_PATH="${CODE_PATH:-lib}"
PROJECT_PROFILE="${PROJECT_PROFILE:-flutter}"
SENTRY_QUERY="${SENTRY_QUERY:-is:unresolved level:error}"
SENTRY_LIMIT="${SENTRY_LIMIT:-25}"
SENTRY_PAGE_SIZE="${SENTRY_PAGE_SIZE:-100}"
SENTRY_MAX_PAGES="${SENTRY_MAX_PAGES:-10}"
SENTRY_REGION_URL="${SENTRY_REGION_URL:-https://us.sentry.io}"
SENTRY_TRIAGE_SIMPLE_FIRST="${SENTRY_TRIAGE_SIMPLE_FIRST:-true}"
POLL_SECONDS="${POLL_SECONDS:-900}"
AUTO_INSTALL_LAUNCHAGENT="${AUTO_INSTALL_LAUNCHAGENT:-true}"
PR_DRAFT="${PR_DRAFT:-true}"
CLOSE_SOURCE_BRANCH="${CLOSE_SOURCE_BRANCH:-true}"
BITBUCKET_PR_REVIEWERS="${BITBUCKET_PR_REVIEWERS:-}"
BITBUCKET_AUTH="${BITBUCKET_AUTH:-bearer}"
BITBUCKET_PR_ENABLED="${BITBUCKET_PR_ENABLED:-true}"
REQUIRE_TESTS_TIER12="${REQUIRE_TESTS_TIER12:-true}"
TEST_GATE_ENABLED="${TEST_GATE_ENABLED:-true}"
FIX_CONFIDENCE_MIN="${FIX_CONFIDENCE_MIN:-medium}"
TEST_TIMEOUT_SECONDS="${TEST_TIMEOUT_SECONDS:-600}"
SYNC_PR_FEEDBACK_ON_RUN="${SYNC_PR_FEEDBACK_ON_RUN:-true}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
SLACK_CHANNEL_ID="${SLACK_CHANNEL_ID:-}"
SLACK_NOTIFY_ENABLED="${SLACK_NOTIFY_ENABLED:-true}"
SLACK_NOTIFY_RUN_START="${SLACK_NOTIFY_RUN_START:-false}"
SLACK_NOTIFY_CODEGUARDIAN="${SLACK_NOTIFY_CODEGUARDIAN:-true}"
SLACK_NOTIFY_PR_MERGED="${SLACK_NOTIFY_PR_MERGED:-true}"
# Vendored CodeGuardian defaults (one repo — no second clone). Override in config.env.
_CG_VENDOR_CLI="${SCRIPT_DIR}/vendor/codeguardian/bin/codeguardian.sh"
CODEGUARDIAN_ENABLED="${CODEGUARDIAN_ENABLED:-true}"
CODEGUARDIAN_CLI="${CODEGUARDIAN_CLI:-}"
if [[ -z "${CODEGUARDIAN_CLI}" && -x "${_CG_VENDOR_CLI}" ]]; then
  CODEGUARDIAN_CLI="${_CG_VENDOR_CLI}"
fi
CODEGUARDIAN_MODE="${CODEGUARDIAN_MODE:-validate}"
CODEGUARDIAN_TIMEOUT="${CODEGUARDIAN_TIMEOUT:-600}"
CODEGUARDIAN_FAIL_BLOCKS_PR="${CODEGUARDIAN_FAIL_BLOCKS_PR:-true}"
unset _CG_VENDOR_CLI

# ---------------------------------------------------------------------------
# Profile-namespaced paths — each profile gets its own state + log directory
# so flutter and laravel runs never clobber each other's state.
# ---------------------------------------------------------------------------
STATE_DIR="${SCRIPT_DIR}/.state/${ACTIVE_PROFILE}"
LOG_DIR="${SCRIPT_DIR}/logs/${ACTIVE_PROFILE}"
LOG_FILE="${LOG_DIR}/run.log"
STATUS_FILE="${STATE_DIR}/run.status"
LAST_RUN_FILE="${STATE_DIR}/last-run.log"
LOCK_DIR="${STATE_DIR}/run.lock"
USER_BRANCH_FILE="${STATE_DIR}/user-branch.txt"
WORKTREE_PATH="${STATE_DIR}/fix-worktree"
VENV_DIR="${SCRIPT_DIR}/.venv"
PYTHON_BIN="python3"

log_line() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

log_status() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$msg" > "$STATUS_FILE"
  echo "$msg" >> "$LOG_FILE"
}

ensure_python_env() {
  if [[ ! -d "$VENV_DIR" ]]; then
    log_line "python: creating venv (${VENV_DIR})"
    python3 -m venv "$VENV_DIR"
  fi
  if ! "${VENV_DIR}/bin/python3" -c "import requests" 2>/dev/null; then
    log_line "python: installing requirements.txt into venv"
    "${VENV_DIR}/bin/pip" install -q -r "${SCRIPT_DIR}/requirements.txt"
  fi
  PYTHON_BIN="${VENV_DIR}/bin/python3"
}

# LaunchAgent has no login-shell PATH — ensure common locations are searchable.
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

resolve_cursor_bin() {
  local candidate resolved=""

  if [[ -n "${CURSOR_BIN:-}" && "${CURSOR_BIN}" != "cursor" && -x "${CURSOR_BIN}" ]]; then
    return 0
  fi

  for candidate in \
    "${CURSOR_BIN:-}" \
    "${HOME}/.local/bin/cursor" \
    "/usr/local/bin/cursor" \
    "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"; do
    [[ -z "$candidate" ]] && continue
    if [[ -x "$candidate" ]]; then
      resolved="$candidate"
      break
    fi
  done

  if [[ -z "$resolved" ]] && command -v cursor >/dev/null 2>&1; then
    resolved="$(command -v cursor)"
  fi

  if [[ -n "$resolved" ]]; then
    CURSOR_BIN="$resolved"
    return 0
  fi

  return 1
}

resolve_cursor_bin || true

# bearer = repository access token (Authorization: Bearer ...)
# basic  = Atlassian API token (curl -u email:token)
if [[ -z "${BITBUCKET_EMAIL:-}" && "${BITBUCKET_AUTH}" == "basic" ]]; then
  echo "BITBUCKET_EMAIL is required when BITBUCKET_AUTH=basic"
  exit 1
fi

bitbucket_curl() {
  local url="$1"
  shift
  case "${BITBUCKET_AUTH}" in
    basic)
      curl -s -u "${BITBUCKET_EMAIL}:${BITBUCKET_ACCESS_TOKEN}" "$url" "$@"
      ;;
    bearer)
      curl -s -H "Authorization: Bearer ${BITBUCKET_ACCESS_TOKEN}" "$url" "$@"
      ;;
    *)
      echo "Unknown BITBUCKET_AUTH=${BITBUCKET_AUTH} (use bearer or basic)" >&2
      return 1
      ;;
  esac
}

bitbucket_http_code() {
  local url="$1"
  shift
  case "${BITBUCKET_AUTH}" in
    basic)
      curl -s -o /dev/null -w "%{http_code}" -u "${BITBUCKET_EMAIL}:${BITBUCKET_ACCESS_TOKEN}" "$url" "$@"
      ;;
    bearer)
      curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${BITBUCKET_ACCESS_TOKEN}" "$url" "$@"
      ;;
  esac
}

build_reviewers_json() {
  local reviewers=() entry trimmed
  IFS=',' read -ra reviewers <<< "${BITBUCKET_PR_REVIEWERS}"
  local json="["
  local first=true
  for entry in "${reviewers[@]}"; do
    trimmed="${entry#"${entry%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -z "$trimmed" ]] && continue
    if [[ "$first" == true ]]; then
      first=false
    else
      json+=","
    fi
    if [[ "$trimmed" == *:* ]]; then
      json+="{\"account_id\":\"${trimmed}\"}"
    else
      json+="{\"username\":\"${trimmed}\"}"
    fi
  done
  json+="]"
  if [[ "$json" == "[]" ]]; then
    echo ""
  else
    echo "$json"
  fi
}

preflight() {
  log_status "preflight: checking Python deps"
  ensure_python_env
  log_status "preflight: python=${PYTHON_BIN}"

  log_status "preflight: checking cursor CLI"
  if ! resolve_cursor_bin; then
    log_status "FAILED: cursor CLI not found"
    echo ""
    echo "Cursor CLI not found. LaunchAgent runs without your shell PATH."
    echo "Set in config.env:"
    echo "  CURSOR_BIN=${HOME}/.local/bin/cursor"
    echo "Or reinstall auto-run after fix: ./run.sh install-auto"
    exit 1
  fi
  log_status "preflight: cursor=${CURSOR_BIN}"

  if [[ -z "${BITBUCKET_ACCESS_TOKEN:-}" ]]; then
    BITBUCKET_PR_ENABLED=false
    log_status "preflight: no BITBUCKET_ACCESS_TOKEN — PR creation disabled (branch-push only)"
    echo ""
    echo "No Bitbucket token set — auto-PR disabled."
    echo "The agent will fix the code and push the branch."
    echo "Open the PR manually in Bitbucket after the run."
    echo ""
  else
    log_status "preflight: checking Bitbucket API (${BITBUCKET_AUTH})"
    local http_code
    http_code="$(bitbucket_http_code \
      "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}")"
    if [[ "$http_code" != "200" ]]; then
      BITBUCKET_PR_ENABLED=false
      log_status "WARN: Bitbucket API returned HTTP ${http_code}"
      echo ""
      echo "Bitbucket auth check failed (HTTP ${http_code}) — continuing without auto-PR."
      echo "Fix the token and run: ./run.sh check-bitbucket"
      echo ""
    else
      BITBUCKET_PR_ENABLED=true
      log_status "preflight: Bitbucket ok"
    fi
  fi
  log_status "preflight: ok"
}

check_bitbucket() {
  echo "Bitbucket auth mode: ${BITBUCKET_AUTH}"
  if [[ -z "${BITBUCKET_ACCESS_TOKEN:-}" ]]; then
    echo "No token set — PR creation is disabled (branch-push only mode)."
    echo "To enable auto-PR: set BITBUCKET_ACCESS_TOKEN in config.env"
    return 0
  fi
  if [[ "${BITBUCKET_ACCESS_TOKEN}" == *PASTE_* ]]; then
    echo "ERROR: Replace the placeholder in BITBUCKET_ACCESS_TOKEN with a real token"
    return 1
  fi
  if [[ "$BITBUCKET_ACCESS_TOKEN" == *$'\n'* ]]; then
    echo "ERROR: Token contains line breaks — must be a single line in config.env"
    return 1
  fi
  if ! [[ "$BITBUCKET_ACCESS_TOKEN" =~ ^[A-Za-z0-9_+=/.-]+$ ]]; then
    echo "ERROR: Token has invalid characters (copy again from Bitbucket — use plain text, not Word/Slack)"
    return 1
  fi
  local repo_code pr_code
  repo_code="$(bitbucket_http_code \
    "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}")"
  pr_code="$(bitbucket_http_code \
    "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pullrequests?pagelen=1")"
  echo "GET repository: HTTP ${repo_code}"
  echo "GET pullrequests: HTTP ${pr_code}"
  if [[ "$repo_code" == "200" && "$pr_code" == "200" ]]; then
    echo "OK — token can read repo and pull requests."
    BITBUCKET_PR_ENABLED=true
    return 0
  fi
  echo "FAILED — update config.env and recreate token with correct scopes."
  return 1
}

parse_last_run_field() {
  local field="$1"
  local value=""

  if [[ -f "${STATE_DIR}/run-result.env" ]]; then
    value="$(grep -E "^${field}=" "${STATE_DIR}/run-result.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  fi

  if [[ -z "$value" && -f "$LAST_RUN_FILE" ]]; then
    value="$(grep -E "^${field}=" "$LAST_RUN_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  fi

  if [[ -z "$value" && -f "$LAST_RUN_FILE" ]]; then
    value="$("$PYTHON_BIN" "${SCRIPT_DIR}/parse_agent_output.py" field "$LAST_RUN_FILE" "$field" 2>/dev/null || true)"
  fi

  value="${value//\`/}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  echo "$value"
}

extract_run_result_env() {
  local result_file="${STATE_DIR}/run-result.env"
  : > "$result_file"
  if [[ -f "$LAST_RUN_FILE" ]]; then
    "$PYTHON_BIN" "${SCRIPT_DIR}/parse_agent_output.py" env "$LAST_RUN_FILE" "$result_file" || true
  fi
}

prepare_sentry_pagination() {
  log_line "pagination: auto-prefetch (pages=${SENTRY_MAX_PAGES}, size=${SENTRY_PAGE_SIZE})"
  "$PYTHON_BIN" "${SCRIPT_DIR}/sentry_pagination.py" --state-dir "${STATE_DIR}" prepare \
    >> "$LOG_FILE" 2>&1 || log_line "pagination: prefetch failed (agent will search MCP directly)"
}

post_run_sentry_pagination() {
  "$PYTHON_BIN" "${SCRIPT_DIR}/sentry_pagination.py" --state-dir "${STATE_DIR}" \
    post-run --result "${STATE_DIR}/run-result.env" >> "$LOG_FILE" 2>&1 || true
}

read_sentry_effective_query() {
  local query="${SENTRY_QUERY}"
  if [[ -f "${STATE_DIR}/sentry-search-context.txt" ]]; then
    local ctx
    ctx="$(grep -E '^effective_query=' "${STATE_DIR}/sentry-search-context.txt" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    [[ -n "$ctx" ]] && query="$ctx"
  fi
  echo "$query"
}

create_bitbucket_pr() {
  local branch="$1"
  local title="$2"
  local description="$3"
  local reviewers_json response http_code pr_url

  reviewers_json="$(build_reviewers_json)"
  response="$(python3 - "$branch" "$title" "$description" "$GIT_BASE_BRANCH" "$PR_DRAFT" "$CLOSE_SOURCE_BRANCH" "$reviewers_json" <<'PY'
import json, sys
branch, title, description, dest, draft, close_branch, reviewers_raw = sys.argv[1:8]
payload = {
    "title": title,
    "description": description,
    "source": {"branch": {"name": branch}},
    "destination": {"branch": {"name": dest}},
    "draft": draft.lower() == "true",
    "close_source_branch": close_branch.lower() == "true",
}
if reviewers_raw:
    reviewers = json.loads(reviewers_raw)
    if reviewers:
        payload["reviewers"] = reviewers
print(json.dumps(payload))
PY
)"

  log_line "creating Bitbucket draft PR for branch ${branch} (close_source_branch=${CLOSE_SOURCE_BRANCH})"
  case "${BITBUCKET_AUTH}" in
    basic)
      response="$(curl -s -w "\n__HTTP_CODE__:%{http_code}" -u "${BITBUCKET_EMAIL}:${BITBUCKET_ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -X POST \
        "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pullrequests" \
        -d "$response")"
      ;;
    bearer)
      response="$(curl -s -w "\n__HTTP_CODE__:%{http_code}" \
        -H "Authorization: Bearer ${BITBUCKET_ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -X POST \
        "https://api.bitbucket.org/2.0/repositories/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pullrequests" \
        -d "$response")"
      ;;
  esac

  http_code="${response##*__HTTP_CODE__:}"
  response="${response%__HTTP_CODE__:*}"

  if [[ "$http_code" == "201" ]]; then
    pr_url="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('links',{}).get('html',{}).get('href',''))" <<< "$response")"
    pr_id="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" <<< "$response")"
    pr_title="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('title',''))" <<< "$response")"
    log_line "PR_URL=${pr_url}"
    echo "PR_URL=${pr_url}" >> "$LAST_RUN_FILE"
    echo "PR_URL=${pr_url}" >> "$LOG_FILE"
    if [[ -n "$pr_id" ]]; then
      echo "PR_ID=${pr_id}" >> "$LAST_RUN_FILE"
      if [[ -f "${STATE_DIR}/run-result.env" ]]; then
        echo "PR_URL=${pr_url}" >> "${STATE_DIR}/run-result.env"
        echo "PR_ID=${pr_id}" >> "${STATE_DIR}/run-result.env"
      fi
      track_created_pr "$pr_id" "$pr_url" "$branch" "$pr_title"
    fi
    return 0
  fi

  log_line "PR create failed (HTTP ${http_code})"
  echo "PR create failed (HTTP ${http_code}). Response saved to logs."
  echo "$response" >> "$LOG_FILE"
  return 1
}

PR_BODY_FILE="${STATE_DIR}/pr-body.md"
REJECTION_LESSONS_FILE="${STATE_DIR}/rejection-lessons.json"

rejection_lessons_prompt_block() {
  ensure_python_env
  "$PYTHON_BIN" "${SCRIPT_DIR}/rejection_lessons.py" --state-dir "${STATE_DIR}" prompt 2>/dev/null || echo "(none recorded yet)"
}

sync_pr_feedback() {
  if [[ -z "${BITBUCKET_ACCESS_TOKEN:-}" ]]; then
    echo "BITBUCKET_ACCESS_TOKEN required to sync PR feedback"
    return 1
  fi
  ensure_python_env
  "$PYTHON_BIN" "${SCRIPT_DIR}/rejection_lessons.py" --state-dir "${STATE_DIR}" sync-bitbucket \
    --workspace "${BITBUCKET_WORKSPACE}" \
    --repo-slug "${BITBUCKET_REPO_SLUG}" \
    --access-token "${BITBUCKET_ACCESS_TOKEN}" \
    --auth "${BITBUCKET_AUTH}" \
    --email "${BITBUCKET_EMAIL:-}"
}

record_rejection() {
  local short_id="${1:-}"
  local reason="${2:-}"
  local branch="${3:-}"
  local reviewer="${4:-}"

  if [[ -z "$short_id" || -z "$reason" ]]; then
    echo "Usage: $0 [profile] record-rejection <SHORT_ID> \"reason\" [branch] [reviewer]"
    return 1
  fi

  ensure_python_env
  "$PYTHON_BIN" "${SCRIPT_DIR}/rejection_lessons.py" --state-dir "${STATE_DIR}" record \
    --issue-short-id "$short_id" \
    --reason "$reason" \
    --branch "$branch" \
    --reviewer "$reviewer"
}

list_rejections() {
  ensure_python_env
  "$PYTHON_BIN" "${SCRIPT_DIR}/rejection_lessons.py" --state-dir "${STATE_DIR}" list
}

run_quality_gates() {
  if last_run_no_action; then
    log_line "quality-gates: skipped (NO_ACTION)"
    return 0
  fi

  local branch
  branch="$(parse_last_run_field "BRANCH_NAME")"
  if [[ -z "$branch" ]]; then
    log_line "quality-gates: skipped (no branch)"
    return 0
  fi

  log_status "quality-gates: verifying tests and fix policy"
  ensure_python_env
  if "$PYTHON_BIN" "${SCRIPT_DIR}/quality_gates.py" \
    --state-dir "${STATE_DIR}" \
    --worktree "${WORKTREE_PATH}" \
    --profile "${PROJECT_PROFILE}" \
    --require-tests-tier12 "${REQUIRE_TESTS_TIER12}" \
    --min-confidence "${FIX_CONFIDENCE_MIN}" \
    --test-gate-enabled "${TEST_GATE_ENABLED}" \
    --test-timeout "${TEST_TIMEOUT_SECONDS}" \
    --codeguardian-enabled "${CODEGUARDIAN_ENABLED}" \
    --codeguardian-cli "${CODEGUARDIAN_CLI}" \
    --codeguardian-mode "${CODEGUARDIAN_MODE}" \
    --codeguardian-timeout "${CODEGUARDIAN_TIMEOUT}" \
    --codeguardian-fail-blocks-pr "${CODEGUARDIAN_FAIL_BLOCKS_PR}" >> "$LOG_FILE" 2>&1; then
    log_line "quality-gates: passed"
    return 0
  fi

  log_line "quality-gates: FAILED — PR creation blocked"
  log_status "quality-gates: FAILED (tests/confidence/policy)"
  echo "QUALITY_GATE_FAILED=true" >> "${STATE_DIR}/run-result.env"
  return 1
}

quality_gate_failed() {
  [[ -f "${STATE_DIR}/run-result.env" ]] && grep -q '^QUALITY_GATE_FAILED=true$' "${STATE_DIR}/run-result.env" 2>/dev/null
}

slack_is_configured() {
  if [[ -n "${SLACK_BOT_TOKEN:-}" && -n "${SLACK_CHANNEL_ID:-}" ]]; then
    return 0
  fi
  [[ -n "${SLACK_WEBHOOK_URL:-}" ]]
}

slack_notify() {
  local event="$1"
  shift

  [[ "${SLACK_NOTIFY_ENABLED}" == "true" ]] || return 0
  slack_is_configured || return 0

  ensure_python_env
  "$PYTHON_BIN" "${SCRIPT_DIR}/slack_notify.py" run-outcome \
    --bot-token "${SLACK_BOT_TOKEN}" \
    --channel-id "${SLACK_CHANNEL_ID}" \
    --webhook-url "${SLACK_WEBHOOK_URL}" \
    --profile "${ACTIVE_PROFILE}" \
    --event "$event" \
    --repo-slug "${BITBUCKET_REPO_SLUG}" \
    "$@" >> "$LOG_FILE" 2>&1 || log_line "slack: notify failed (non-fatal)"
}

read_detail_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    # Keep Slack payload bounded
    head -c 4000 "$path" | tr '\n' ' ' | sed 's/  */ /g'
  fi
}

track_created_pr() {
  local pr_id="$1"
  local pr_url="$2"
  local branch="$3"
  local title="${4:-}"
  local short_id tier issue_url

  short_id="$(parse_last_run_field "ISSUE_SHORT_ID")"
  tier="$(parse_last_run_field "ISSUE_TIER")"
  issue_url="$(parse_last_run_field "ISSUE_URL")"

  ensure_python_env
  "$PYTHON_BIN" "${SCRIPT_DIR}/pr_tracker.py" --state-dir "${STATE_DIR}" track \
    --pr-id "$pr_id" \
    --pr-url "$pr_url" \
    --branch "$branch" \
    --title "$title" \
    ${short_id:+--issue-short-id "$short_id"} \
    ${tier:+--issue-tier "$tier"} \
    ${issue_url:+--issue-url "$issue_url"} >> "$LOG_FILE" 2>&1 || log_line "pr-tracker: track failed (non-fatal)"
}

poll_merged_prs() {
  [[ "${SLACK_NOTIFY_ENABLED}" == "true" ]] || return 0
  [[ "${SLACK_NOTIFY_PR_MERGED}" == "true" ]] || return 0
  slack_is_configured || return 0
  [[ -n "${BITBUCKET_ACCESS_TOKEN:-}" ]] || return 0

  ensure_python_env
  "$PYTHON_BIN" "${SCRIPT_DIR}/pr_tracker.py" --state-dir "${STATE_DIR}" poll-merged \
    --workspace "${BITBUCKET_WORKSPACE}" \
    --repo-slug "${BITBUCKET_REPO_SLUG}" \
    --access-token "${BITBUCKET_ACCESS_TOKEN}" \
    --auth "${BITBUCKET_AUTH}" \
    --email "${BITBUCKET_EMAIL:-}" \
    --bot-token "${SLACK_BOT_TOKEN}" \
    --channel-id "${SLACK_CHANNEL_ID}" \
    --webhook-url "${SLACK_WEBHOOK_URL}" \
    --profile "${ACTIVE_PROFILE}" >> "$LOG_FILE" 2>&1 || log_line "pr-tracker: poll-merged failed (non-fatal)"
}

slack_notify_run_outcome() {
  local agent_exit="${1:-0}"
  local short_id tier branch pr_url issue_url detail event="" gate_reason cg_status
  local common_args=()

  short_id="$(parse_last_run_field "ISSUE_SHORT_ID")"
  tier="$(parse_last_run_field "ISSUE_TIER")"
  branch="$(parse_last_run_field "BRANCH_NAME")"
  pr_url="$(parse_last_run_field "PR_URL")"
  issue_url="$(parse_last_run_field "ISSUE_URL")"
  gate_reason="$(parse_last_run_field "QUALITY_GATE_REASON")"
  cg_status="$(parse_last_run_field "CODEGUARDIAN_STATUS")"

  common_args=(
    ${short_id:+--issue-short-id "$short_id"}
    ${tier:+--issue-tier "$tier"}
    ${branch:+--branch "$branch"}
    ${pr_url:+--pr-url "$pr_url"}
    ${issue_url:+--issue-url "$issue_url"}
    ${gate_reason:+--gate-reason "$gate_reason"}
    ${cg_status:+--cg-status "$cg_status"}
  )

  if [[ "$agent_exit" -ne 0 ]]; then
    slack_notify "agent_failed" "${common_args[@]}" \
      --detail "Cursor agent exited with code ${agent_exit}"
    return 0
  fi

  if last_run_no_action; then
    slack_notify "no_action" "${common_args[@]}" \
      --detail "No tier1/tier2/tier3 candidate to fix this cycle"
    return 0
  fi

  # Explicit CodeGuardian outcomes (full detail file when present)
  if [[ "${SLACK_NOTIFY_CODEGUARDIAN}" == "true" ]]; then
    if [[ "$cg_status" == "failed" ]]; then
      detail="$(read_detail_file "${STATE_DIR}/codeguardian-detail.txt")"
      slack_notify "codeguardian_failed" "${common_args[@]}" \
        --detail "${detail:-CodeGuardian validate failed}"
    elif [[ "$cg_status" == "passed" ]]; then
      detail="$(read_detail_file "${STATE_DIR}/codeguardian-detail.txt")"
      slack_notify "codeguardian_passed" "${common_args[@]}" \
        --detail "${detail:-CodeGuardian validate passed}"
    fi
  fi

  if quality_gate_failed; then
    if [[ "$gate_reason" == "codeguardian" ]]; then
      # Already notified as codeguardian_failed above
      return 0
    fi
    detail="$(read_detail_file "${STATE_DIR}/test-gate-detail.txt")"
    [[ -z "$detail" ]] && detail="Tests/confidence/policy check failed — branch may exist on origin"
    slack_notify "quality_gate_failed" "${common_args[@]}" --detail "$detail"
    return 0
  fi

  if [[ -n "$pr_url" ]]; then
    slack_notify "pr_created" "${common_args[@]}" \
      --detail "Draft PR opened for autofix branch"
  elif [[ -n "$branch" ]]; then
    if [[ "${BITBUCKET_PR_ENABLED}" != "true" ]]; then
      detail="BITBUCKET_PR_ENABLED=false — open PR manually in Bitbucket"
    else
      detail="PR was not created — check run.log"
    fi
    slack_notify "branch_pushed" "${common_args[@]}" --detail "$detail"
  fi
}


build_sentry_issue_url() {
  local short_id="$1"
  [[ -n "$short_id" ]] || return 0
  # Search link — works even if numeric issue id is unknown
  python3 - "$short_id" "$SENTRY_ORG_SLUG" "$SENTRY_PROJECT_SLUG" <<'PY'
import sys, urllib.parse
short_id, org, project = sys.argv[1:4]
query = urllib.parse.quote(f"is:unresolved {short_id}")
print(f"https://{org}.sentry.io/issues/?project={project}&query={query}")
PY
}

build_pr_description() {
  local short_id="$1"
  local tier="$2"
  local issue_url branch description resolve_section

  issue_url="$(parse_last_run_field "ISSUE_URL")"
  if [[ -z "$issue_url" && -n "$short_id" ]]; then
    issue_url="$(build_sentry_issue_url "$short_id")"
  fi

  branch="$(parse_last_run_field "BRANCH_NAME")"
  description="Automated Sentry fix."

  if [[ -n "$short_id" ]]; then
    description="${description}

**Issue:** ${short_id}"
  fi
  if [[ -n "$tier" ]]; then
    description="${description}
**Tier:** ${tier}"
  fi
  if [[ -n "$issue_url" ]]; then
    description="${description}
**Sentry:** ${issue_url}"
  fi

  if [[ -f "$PR_BODY_FILE" ]] && [[ -s "$PR_BODY_FILE" ]]; then
    description="${description}

---

$(cat "$PR_BODY_FILE")"
  else
    description="${description}

## Sentry Issue
- **ID:** ${short_id:-unknown}
- **Link:** ${issue_url:-_(add from Sentry MCP)_}
- **Summary:** _(not captured — see commit diff)_

## Fix Strategy
- **Root cause:** _(not captured)_
- **Strategy:** _(not captured)_

## Tests
- **Added/updated:** _(not captured)_
- **Command run:** _(not captured)_
- **Result:** _(not captured)_

## Possible Solutions
1. _(not captured)_
2. _(not captured)_

## Chosen Solution & Why
- **Picked:** _(not captured)_
- **Why:** _(not captured)_"
  fi

  if [[ -n "$issue_url" ]]; then
    resolve_section="## After merge — resolve in Sentry

1. Open the issue: ${issue_url}
2. Deploy / verify the fix on **${SENTRY_PROJECT_SLUG}** (staging first if applicable)
3. Confirm new events stopped (or rate dropped) in Sentry
4. In Sentry → **Resolve** (or **Archive**) the issue
5. **Branch:** \`${branch:-unknown}\` is deleted automatically on merge (\`close_source_branch=true\`)"
    if [[ "$description" != *"After merge — resolve in Sentry"* ]]; then
      description="${description}

---

${resolve_section}"
    fi
  fi

  echo "$description"
}

maybe_create_pr_from_last_run() {
  [[ "${BITBUCKET_PR_ENABLED}" == "true" ]] || {
    log_line "PR skipped: BITBUCKET_PR_ENABLED=false"
    return 0
  }

  if quality_gate_failed; then
    log_line "PR skipped: quality gates failed (tests/confidence/policy)"
    return 0
  fi

  if last_run_no_action; then
    log_line "PR skipped: agent reported NO_ACTION"
    return 0
  fi

  local branch short_id tier title description
  branch="$(parse_last_run_field "BRANCH_NAME")"
  short_id="$(parse_last_run_field "ISSUE_SHORT_ID")"
  tier="$(parse_last_run_field "ISSUE_TIER")"

  if [[ -z "$branch" ]]; then
    log_line "PR skipped: could not parse BRANCH_NAME from agent output (stream-json)"
    return 0
  fi

  if grep -qE "^PR_URL=https?://" "$LAST_RUN_FILE" 2>/dev/null; then
    log_line "PR already created for this run"
    return 0
  fi

  title="fix(sentry): ${short_id:-unknown}"
  description="$(build_pr_description "$short_id" "$tier")"
  log_line "creating PR: branch=${branch} draft=${PR_DRAFT} base=${GIT_BASE_BRANCH}"
  create_bitbucket_pr "$branch" "$title" "$description" || true
}

acquire_lock() {
  mkdir -p "${STATE_DIR}"

  if [[ -d "$LOCK_DIR" ]]; then
    local lock_pid=""
    if [[ -f "${LOCK_DIR}/pid" ]]; then
      lock_pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
    fi

    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      log_line "skipped: run already in progress (pid=${lock_pid})"
      return 1
    fi

    if [[ -n "$lock_pid" ]]; then
      log_line "removing lock from dead process (pid=${lock_pid})"
    else
      log_line "removing orphan lock"
    fi
    rm -rf "$LOCK_DIR"
  fi

  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log_line "skipped: could not acquire lock"
    return 1
  fi

  echo "$$" > "${LOCK_DIR}/pid"
  date -u +%Y-%m-%dT%H:%M:%SZ > "${LOCK_DIR}/started_at"
  return 0
}

release_lock() {
  rm -f "${LOCK_DIR}/pid" "${LOCK_DIR}/started_at"
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

save_user_git_state() {
  local branch
  branch="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)"
  if [[ -z "$branch" ]]; then
    branch="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "HEAD")"
  fi
  echo "$branch" > "$USER_BRANCH_FILE"
  log_line "saved developer branch: ${branch}"
}

restore_user_git_state() {
  local saved current
  [[ -f "$USER_BRANCH_FILE" ]] || return 0
  saved="$(tr -d '[:space:]' < "$USER_BRANCH_FILE")"
  [[ -n "$saved" && "$saved" != "HEAD" ]] || return 0

  current="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)"
  if [[ "$current" == "$saved" ]]; then
    return 0
  fi

  log_line "restoring developer branch: ${saved} (auto-fix left repo on ${current:-detached})"
  if git -C "$REPO_ROOT" switch "$saved" 2>/dev/null; then
    log_line "restored developer branch: ${saved}"
  else
    log_line "WARN: could not switch back to ${saved} — finish/commit your work, then: git switch ${saved}"
  fi
}

prepare_fix_worktree() {
  local base_ref="origin/${GIT_BASE_BRANCH}"

  log_status "worktree: preparing isolated fix environment"
  git -C "$REPO_ROOT" fetch origin "$GIT_BASE_BRANCH" 2>/dev/null || git -C "$REPO_ROOT" fetch origin || true

  if [[ -d "$WORKTREE_PATH" ]] && git -C "$WORKTREE_PATH" rev-parse --git-dir >/dev/null 2>&1; then
    log_line "worktree: resetting ${WORKTREE_PATH}"
    git -C "$WORKTREE_PATH" fetch origin 2>/dev/null || true
    git -C "$WORKTREE_PATH" switch -C "$GIT_BASE_BRANCH" "$base_ref" 2>/dev/null || \
      git -C "$WORKTREE_PATH" switch -C "$GIT_BASE_BRANCH" "$GIT_BASE_BRANCH" 2>/dev/null || true
    git -C "$WORKTREE_PATH" reset --hard "$base_ref" 2>/dev/null || true
    git -C "$WORKTREE_PATH" clean -fd 2>/dev/null || true
  else
    rm -rf "$WORKTREE_PATH"
    log_line "worktree: creating ${WORKTREE_PATH} from ${base_ref}"
    if ! git -C "$REPO_ROOT" worktree add -f "$WORKTREE_PATH" "$base_ref" 2>/dev/null; then
      git -C "$REPO_ROOT" worktree add -f "$WORKTREE_PATH" "$GIT_BASE_BRANCH"
    fi
  fi
}

cleanup_run_environment() {
  restore_user_git_state
}

force_unlock() {
  if [[ -d "$LOCK_DIR" ]]; then
    rm -rf "$LOCK_DIR"
    log_line "lock removed"
  else
    log_line "no lock present"
  fi
}

print_summary() {
  echo ""
  echo "════════════════ RUN SUMMARY ════════════════"

  local short_id tier branch pr_url issue_url result_file="${STATE_DIR}/run-result.env"

  short_id="$(parse_last_run_field "ISSUE_SHORT_ID")"
  tier="$(parse_last_run_field "ISSUE_TIER")"
  branch="$(parse_last_run_field "BRANCH_NAME")"
  pr_url="$(parse_last_run_field "PR_URL")"
  issue_url="$(parse_last_run_field "ISSUE_URL")"

  if [[ -f "$result_file" ]] && grep -q '^NO_ACTION=true$' "$result_file" 2>/dev/null; then
    echo "  Result : NO_ACTION — no new actionable issue found"
  elif quality_gate_failed; then
    echo "  Result : QUALITY_GATE_FAILED — branch pushed but PR blocked (see log)"
    [[ -n "$branch" ]] && echo "  Branch : ${branch}"
  elif [[ -n "$short_id" ]]; then
    echo "  Result : ✓ fix pushed"
    echo "  Issue  : ${short_id}${tier:+ (${tier})}"
    [[ -n "$issue_url" ]] && echo "  Sentry : ${issue_url}"
    [[ -n "$branch"   ]] && echo "  Branch : ${branch}"
    if [[ -n "$pr_url" ]]; then
      echo "  PR     : ${pr_url}"
    elif [[ -n "$branch" && -n "$BITBUCKET_WORKSPACE" && -n "$BITBUCKET_REPO_SLUG" ]]; then
      echo "  PR     : https://bitbucket.org/${BITBUCKET_WORKSPACE}/${BITBUCKET_REPO_SLUG}/pull-requests/new?source=${branch}&t=1"
    fi
  else
    echo "  Result : unknown — check log below"
  fi

  echo ""
  echo "  Log    : $LOG_FILE"
  echo "════════════════════════════════════════════"
}

show_status() {
  echo "== Current status =="
  if [[ -f "$STATUS_FILE" ]]; then
    cat "$STATUS_FILE"
  else
    echo "(no status file yet)"
  fi
  echo ""
  print_summary
}

run_once() {
  local prompt fix_workspace="${WORKTREE_PATH}" effective_query code_hint pattern_hint lessons_block test_cmd
  effective_query="$(read_sentry_effective_query)"
  lessons_block="$(rejection_lessons_prompt_block)"
  case "${PROJECT_PROFILE}" in
    laravel|php|backend|be)
      code_hint="Match Laravel/PHP patterns (Eloquent, jobs, middleware, form requests, try/catch, null-safe operators)."
      pattern_hint="app/ and routes/"
      test_cmd="php artisan test --filter=<RelevantTestClassOrMethod>"
      ;;
    flutter|mobile|dart)
      code_hint="Match Flutter/Dart patterns (Riverpod, async guards, mounted checks, existing SDK usage)."
      pattern_hint="lib/"
      test_cmd="flutter test test/path/to/relevant_test.dart"
      ;;
    *)
      code_hint="Match existing project patterns and conventions in ${CODE_PATH}/."
      pattern_hint="${CODE_PATH}/"
      test_cmd="run the project's standard test command for changed files"
      ;;
  esac
  read -r -d '' prompt <<PROMPT || true
You are an autonomous Sentry-to-fix operator for this repository.

IMPORTANT — do NOT touch the developer's main checkout:
- Developer works in: ${REPO_ROOT}
- You work ONLY in isolated worktree: ${fix_workspace}
- NEVER run git checkout, git switch, or git worktree in ${REPO_ROOT}
- ALL git branch/commit/push commands run inside ${fix_workspace} only
- Edit application code under ${fix_workspace}/${CODE_PATH}/ only (not ${REPO_ROOT}/${CODE_PATH}/)

IMPORTANT visibility rules:
- Print progress markers as plain lines: PHASE: searching_sentry | PHASE: selecting_issue | PHASE: fixing_code | PHASE: committing | PHASE: pushing | PHASE: creating_pr | PHASE: done
- Do NOT create temp Python/shell scripts to call mcp.sentry.dev. Use Sentry MCP tools directly.
- Do NOT write tokens into repo files.

Goal:
- Detect unresolved Sentry issues using Sentry MCP
- Pick exactly one actionable issue
- Fix it
- Commit to a new branch
- Push branch to origin
- Do NOT create the PR yourself — run.sh creates it after you finish

Constraints:
- Use Sentry MCP tools only for issue discovery/details (no Sentry REST token)
- Fix workspace (ONLY place to edit code + git): ${fix_workspace}
- Developer repo (read-only — do NOT checkout here): ${REPO_ROOT}
- Sentry org: ${SENTRY_ORG_SLUG}
- Sentry project: ${SENTRY_PROJECT_SLUG}
- Sentry region: ${SENTRY_REGION_URL}
- Search query: ${effective_query}
- Search page size: ${SENTRY_PAGE_SIZE} (up to ${SENTRY_MAX_PAGES} pages — see pagination below)
- Triage simple errors first: ${SENTRY_TRIAGE_SIMPLE_FIRST}
- Base branch: ${GIT_BASE_BRANCH}
- PR draft: ${PR_DRAFT} (created by run.sh, not by you)
- PR reviewers: ${BITBUCKET_PR_REVIEWERS}
- Pre-fetched candidates file (may be empty): ${STATE_DIR}/sentry-candidates.json

## Lessons from rejected auto-fix PRs (MUST NOT repeat)
${lessons_block}
If your proposed fix matches any rejected pattern above, print NO_ACTION instead of pushing.

Fix strategy — reproduce before fix (mandatory):
1. From Sentry MCP, identify the user action / API call / state that triggers the error
2. Locate the exact throw site in ${pattern_hint} (not vendor/native unless tier3)
3. Search the repo for similar past fixes and match existing patterns
4. Apply the smallest root-cause change at the source
5. Add or update an automated test that would have caught this bug
6. Run the test command and confirm it passes before pushing

Fix strategy playbook:
- null/type errors → guard or correct type at source (never swallow)
- auth 401/403 → token refresh / session handling (never filter events)
- routing/navigation → fix route guards / navigation logic
- platform/vendor timeout (tier3 only) → timeout handler + fallback UX, or NO_ACTION
- NEVER use beforeSend / Sentry filters for tier1 or tier2

Fix quality — long-term, production-safe (NOT quick hacks):
- Fix the ROOT CAUSE in application code so the error **stops happening** — not just stops appearing in Sentry
- ${code_hint}
- **NEVER use beforeSend / Sentry filters / return null from _sentryBeforeSend** for tier1 or tier2 issues — that only hides events; the bug still happens and Sentry stays unresolved
- beforeSend filters are **banned** unless tier3 AND the stack is proven third-party/native-only AND no ${CODE_PATH}/ code can fix it — if so print NO_ACTION instead of a filter-only PR
- For tier1/tier2: fix the throwing code path (null guard, correct type, auth handling, routing, state lifecycle) — the issue should be verifiable as fixed in Sentry after deploy
- Do NOT: empty catch blocks, catch-and-ignore, onTimeout/onError handlers whose only purpose is to stop Sentry reporting
- Do NOT: change unrelated code, refactor drive-by, or weaken validation just to stop Sentry noise
- Do NOT: break existing user flows — if the fix could regress core paths, pick a safer option or print NO_ACTION
- Prefer: minimal diff that a senior engineer would merge — correct, readable, maintainable
- If the only viable "fix" is a hack, filter, or high regression risk → print NO_ACTION (do not push a bad PR)
- In pr-body.md "Possible Solutions": include a rejected **Sentry filter / beforeSend** option and explain why hiding events is NOT a real fix

Procedure:
1) PHASE: searching_sentry — fetch unresolved issues:
   - **MANDATORY:** Read ${STATE_DIR}/sentry-candidates.json first.
   - If it contains candidates, you MUST pick from that list only — do NOT pick issues outside it.
   - Pick the **first** candidate in the file (lowest tier / highest priority). If tier is "tier1", fix that issue — never pick tier3 while tier1 candidates exist.
   - If candidates.json is empty, call search_issues MCP with tier1 queries first: TypeError, PlatformException, StateError, GoRouter, Null check, unauthorized — before any App Hanging / LaunchDarkly issue.
   - Pagination (MCP): only after tier1 searches return nothing, search tier2, then tier3 last.
2) PHASE: selecting_issue — pick one issue not already branched (origin/fix/sentry-<shortid-lower>-*).
   Print every short ID you considered on this page exactly once:
   SEARCHED_ISSUES=ROBO-STAGING-F1,ROBO-STAGING-F2,...
   Tier order when SENTRY_TRIAGE_SIMPLE_FIRST=true (STRICT — fix higher tiers before lower):
   - **tier1 (FIRST):** type errors, routing/navigation errors, state lifecycle, null/type-null, unauthorized/auth (401/403), platform/runtime exceptions — stack in ${pattern_hint} preferred
   - **tier2:** other provider/JSON/async/framework issues in ${pattern_hint}
   - **tier3 (LAST — only when tier1 and tier2 are exhausted on current pages):** LaunchDarkly, App Hanging, ANR, pasteboard hangs, third-party SDK noise (Adjust/Iterable), native-only stacks
   If ${STATE_DIR}/sentry-candidates.json lists issues with "tier", pick the lowest tier number first.
   Do NOT pick tier3 (LaunchDarkly, App Hang, ANR, pasteboard, vendor filters) while any tier1 or tier2 issue remains unbranched and actionable in Sentry or in sentry-candidates.json.
3) PHASE: fixing_code — reproduce trigger → read surrounding code + similar fixes; implement durable root-cause fix in ${fix_workspace}/${CODE_PATH}/; add/update automated test(s); run tests and confirm pass.
4) PHASE: committing — in ${fix_workspace}: commit: fix(sentry): <SHORT_ID> <title>
5) PHASE: pushing — in ${fix_workspace}: push branch fix/sentry-<shortid-lower>-<slug> to origin
6) PHASE: done — write PR body to:
   ${STATE_DIR}/pr-body.md

   Use this EXACT markdown structure (fill every field from Sentry MCP):

   ## Sentry Issue
   - **ID:** ROBO-STAGING-XX
   - **Link:** (permalink from Sentry MCP — required)
   - **Title:** (issue title from Sentry)
   - **Tier:** tier1|tier2|tier3
   - **Summary:** one line — what failed and where in ${pattern_hint}

   ## Possible Solutions
   1. **Option A — (name)** — what it is. Pros: … Cons: …
   2. **Option B — (name)** — what it is. Pros: … Cons: …
   3. **Option C — (optional)** — what it is. Pros: … Cons: …

   ## Chosen Solution & Why
   - **Picked:** Option N — (short name)
   - **Why:** why this over the others (root cause, matches app patterns, lowest regression risk, long-term maintainable)
   - **Why not a quick fix:** one line on why hack/suppress-only options were rejected

   ## Fix Strategy
   - **Root cause:** what actually failed and why
   - **Trigger:** user action / API call / state that reproduces it
   - **Strategy:** null_guard | auth_refresh | routing | lifecycle | vendor_fallback | other
   - **Files changed:** list main files under ${pattern_hint}

   ## Tests
   - **Added/updated:** path/to/test_file (required for tier1 and tier2)
   - **Command run:** \`${test_cmd}\` (use the exact command you ran)
   - **Result:** PASSED or FAILED (must be PASSED before pushing tier1/tier2)
   - **What the test proves:** one line — which failure path is now covered

   ## After merge — resolve in Sentry
   1. Deploy / verify the fix on ${SENTRY_PROJECT_SLUG} (staging first)
   2. Confirm **new events stopped** in Sentry (not just filtered — check issue event graph)
   3. Open the issue link and click **Resolve** (or run: ./run.sh resolve-issue <SHORT_ID>)
   4. Note: beforeSend filters do NOT resolve issues — they only hide new events; prefer root-cause fixes

   Then print final lines exactly:
   ISSUE_SHORT_ID=...
   ISSUE_TIER=tier1|tier2|tier3
   ISSUE_URL=https://...   (Sentry issue permalink from MCP)
   BRANCH_NAME=...
   FIX_CONFIDENCE=high|medium|low
   FIX_STRATEGY=null_guard|auth_refresh|routing|lifecycle|vendor_fallback|other
   TEST_COMMAND=<exact test command run>
   TEST_RESULT=PASSED|FAILED
If no suitable issue exists, print NO_ACTION and PHASE: done.
If you cannot explain the trigger or add a passing test for tier1/tier2, print NO_ACTION.
PROMPT

  "$CURSOR_BIN" agent \
    --print \
    --trust \
    --force \
    --approve-mcps \
    --output-format stream-json \
    --stream-partial-output \
    --workspace "$fix_workspace" \
    --model "$CURSOR_AGENT_MODEL" \
    "$prompt"
}

run_once_locked() {
  if ! acquire_lock; then
    return 0
  fi

  mkdir -p "${LOG_DIR}" "${STATE_DIR}"
  trap 'cleanup_run_environment; release_lock' EXIT INT TERM

  log_status "starting run"
  preflight

  # Detect PRs that merged since last cycle (Slack "PR merged")
  poll_merged_prs

  if [[ "${SLACK_NOTIFY_RUN_START}" == "true" ]]; then
    slack_notify "run_started" --detail "Polling Sentry and running Cursor agent"
  fi

  if [[ "${SYNC_PR_FEEDBACK_ON_RUN}" == "true" && -n "${BITBUCKET_ACCESS_TOKEN:-}" ]]; then
    log_line "feedback: syncing declined/rejected PR lessons from Bitbucket"
    sync_pr_feedback >> "$LOG_FILE" 2>&1 || log_line "feedback: sync skipped or failed (non-fatal)"
  fi

  save_user_git_state
  prepare_fix_worktree
  prepare_sentry_pagination

  echo ""
  echo "Run started (isolated worktree — your branch is untouched)."
  echo "  Your branch: $(cat "$USER_BRANCH_FILE" 2>/dev/null || echo unknown)"
  echo "  Fix worktree: ${WORKTREE_PATH}"
  echo ""
  echo "Watch progress in another terminal:"
  echo "  tail -f ${LOG_FILE}"
  echo "  tail -f ${STATUS_FILE}"
  echo "  ./run.sh status"
  echo ""

  log_status "agent: running (may take 10-30 min)"
  log_line "starting cursor agent (streaming output below)..."

  : > "$LAST_RUN_FILE"
  : > "$PR_BODY_FILE"
  rm -f "${STATE_DIR}/run-result.env"
  set +e
  run_once 2>&1 | tee -a "$LOG_FILE" | tee "$LAST_RUN_FILE"
  local agent_exit=${PIPESTATUS[0]}
  set -e

  if [[ "$agent_exit" -eq 0 ]]; then
    log_status "agent: finished ok"
  else
    log_status "agent: finished with exit ${agent_exit}"
  fi

  log_line "cursor agent finished (exit=${agent_exit})"
  extract_run_result_env
  post_run_sentry_pagination

  if [[ "$agent_exit" -eq 0 ]]; then
    run_quality_gates || true
    log_status "post-run: creating Bitbucket PR if needed"
    maybe_create_pr_from_last_run
  fi

  slack_notify_run_outcome "$agent_exit"

  print_summary
  cleanup_run_environment
  release_lock
  trap - EXIT INT TERM
  return "$agent_exit"
}

last_run_no_action() {
  if [[ -f "${STATE_DIR}/run-result.env" ]]; then
    grep -q '^NO_ACTION=true$' "${STATE_DIR}/run-result.env" 2>/dev/null
    return $?
  fi
  if [[ -f "$LAST_RUN_FILE" ]] && grep -qE 'BRANCH_NAME=fix/sentry-' "$LAST_RUN_FILE"; then
    return 1
  fi
  [[ -f "$LAST_RUN_FILE" ]] && grep -qE '(^|\n)NO_ACTION\s*(\n|$)' "$LAST_RUN_FILE"
}

run_loop() {
  local max_runs="${1:-0}"
  local count=0

  log_line "loop mode: fix issues one-by-one until NO_ACTION or limit reached"
  if [[ "$max_runs" -gt 0 ]]; then
    log_line "loop limit: ${max_runs} issue(s)"
  else
    log_line "loop limit: unlimited (until NO_ACTION)"
  fi

  while true; do
    count=$((count + 1))
    log_line "loop: starting issue ${count}"
    run_once_locked || true

    if last_run_no_action; then
      log_line "loop: NO_ACTION — no more issues to fix"
      break
    fi

    if [[ "$max_runs" -gt 0 && "$count" -ge "$max_runs" ]]; then
      log_line "loop: reached limit of ${max_runs} issue(s)"
      break
    fi

    log_line "loop: waiting ${POLL_SECONDS}s before next issue..."
    sleep "$POLL_SECONDS"
  done

  log_line "loop: finished after ${count} run(s)"
}

PLIST_LABEL="com.sentry.autofix.${ACTIVE_PROFILE}"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_LABEL}.plist"
DAEMON_LOG="${LOG_DIR}/daemon.log"
DAEMON_ERR="${LOG_DIR}/daemon.err"

install_auto() {
  local abs_run abs_dir uid domain daemon_path dart_bin flutter_bin dart_dir flutter_dir
  abs_run="${SCRIPT_DIR}/run.sh"
  abs_dir="${SCRIPT_DIR}"
  uid="$(id -u)"
  domain="gui/${uid}"

  mkdir -p "${LOG_DIR}" "${HOME}/Library/LaunchAgents"
  chmod +x "$abs_run"

  # Capture Flutter/Dart locations at install time so the LaunchAgent can run
  # CodeGuardian validate (dart) the same way an interactive shell can.
  dart_bin="$(command -v dart 2>/dev/null || true)"
  flutter_bin="$(command -v flutter 2>/dev/null || true)"
  dart_dir=""
  flutter_dir=""
  [[ -n "$dart_bin" ]] && dart_dir="$(cd "$(dirname "$dart_bin")" && pwd)"
  [[ -n "$flutter_bin" ]] && flutter_dir="$(cd "$(dirname "$flutter_bin")" && pwd)"
  daemon_path="${dart_dir}:${flutter_dir}:${HOME}/.pub-cache/bin:${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  # Collapse empty segments from missing dart/flutter
  daemon_path="$(echo "$daemon_path" | sed -E 's/::+/:/g; s/^://; s/:$//')"

  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${abs_run}</string>
    <string>${ACTIVE_PROFILE}</string>
    <string>daemon</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${abs_dir}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${daemon_path}</string>
    <key>HOME</key>
    <string>${HOME}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${DAEMON_LOG}</string>
  <key>StandardErrorPath</key>
  <string>${DAEMON_ERR}</string>
</dict>
</plist>
PLIST

  launchctl bootout "$domain/${PLIST_LABEL}" 2>/dev/null || true
  launchctl bootstrap "$domain" "$PLIST_PATH"
  launchctl enable "$domain/${PLIST_LABEL}" 2>/dev/null || true
  launchctl kickstart -k "$domain/${PLIST_LABEL}" 2>/dev/null || true

  echo ""
  echo "Auto-run installed."
  echo "  Starts on Mac login, restarts if it crashes"
  echo "  Runs: fix issue → wait ${POLL_SECONDS}s → next issue (forever)"
  echo "  PATH includes dart/flutter for CodeGuardian: ${daemon_path}"
  echo ""
  echo "Monitor:"
  echo "  tail -f ${DAEMON_LOG}"
  echo "  tail -f ${LOG_FILE}"
  echo "  ./run.sh auto-status"
  echo ""
  echo "Stop:"
  echo "  ./run.sh stop-auto"
}

stop_auto() {
  local uid domain
  uid="$(id -u)"
  domain="gui/${uid}"
  launchctl bootout "$domain/${PLIST_LABEL}" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  force_unlock
  echo "Auto-run stopped."
}

auto_status() {
  local uid domain
  uid="$(id -u)"
  domain="gui/${uid}"
  echo "== LaunchAgent auto-run =="
  if [[ -f "$PLIST_PATH" ]]; then
    echo "Installed: yes ($PLIST_PATH)"
    launchctl print "$domain/${PLIST_LABEL}" 2>/dev/null | head -15 || echo "Service not loaded"
  else
    echo "Installed: no — run: ./run.sh (auto-installs on first start)"
  fi
  echo ""
  show_status
}

is_auto_installed() {
  [[ -f "$PLIST_PATH" ]]
}

ensure_background_auto_run() {
  [[ "${AUTO_INSTALL_LAUNCHAGENT}" == "true" ]] || return 1
  is_auto_installed && return 0

  log_line "auto-run: first start — installing background service (LaunchAgent)"
  install_auto
  return 0
}

start_auto_run() {
  if ensure_background_auto_run; then
    echo ""
    echo "Sentry auto-fix is running in the background."
    echo "  Fix → PR → wait ${POLL_SECONDS}s → next issue (pagination automatic)"
    echo ""
    echo "Monitor:"
    echo "  ./run.sh status"
    echo "  tail -f ${LOG_FILE}"
    echo ""
    return 0
  fi

  if is_auto_installed; then
    local uid domain
    uid="$(id -u)"
    domain="gui/${uid}"
    launchctl kickstart -k "$domain/${PLIST_LABEL}" 2>/dev/null || true
    echo "Background auto-run already installed."
    auto_status
    return 0
  fi

  echo "AUTO_INSTALL_LAUNCHAGENT=false — starting foreground daemon (terminal must stay open)"
  run_daemon_foreground
}

run_daemon_foreground() {
  while true; do
    log_line "daemon: waiting ${POLL_SECONDS}s between cycles"
    poll_merged_prs
    run_once_locked || true
    if last_run_no_action; then
      log_line "daemon: NO_ACTION — sleeping until next poll"
    fi
    sleep "$POLL_SECONDS"
  done
}

resolve_sentry_issue() {
  local short_id="${1:-}"
  local issue_id="${2:-}"

  if [[ -z "${SENTRY_AUTH_TOKEN:-}" ]]; then
    echo "SENTRY_AUTH_TOKEN required in config.env (needs issue/event write scope to resolve)"
    return 1
  fi

  if [[ -z "$issue_id" && -n "$short_id" ]]; then
    issue_id="$("$PYTHON_BIN" - "$short_id" <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPT_DIR"])
from sentry_client import SentryClient
short_id = sys.argv[1]
client = SentryClient(
    auth_token=os.environ["SENTRY_AUTH_TOKEN"],
    org_slug=os.environ["SENTRY_ORG_SLUG"],
    region_url=os.environ.get("SENTRY_REGION_URL", "https://us.sentry.io"),
    project_slug=os.environ.get("SENTRY_PROJECT_SLUG"),
)
issue_id = client.find_issue_id_by_short_id(short_id, query="is:unresolved")
if not issue_id:
    issue_id = client.find_issue_id_by_short_id(short_id, query="")
print(issue_id or "")
PY
)"
  fi

  if [[ -z "$issue_id" ]]; then
    echo "Could not find Sentry issue for: ${short_id:-$issue_id}"
    return 1
  fi

  log_line "resolving Sentry issue id=${issue_id} (${short_id:-unknown})"
  SCRIPT_DIR="$SCRIPT_DIR" SENTRY_AUTH_TOKEN="$SENTRY_AUTH_TOKEN" SENTRY_ORG_SLUG="$SENTRY_ORG_SLUG" \
    SENTRY_REGION_URL="$SENTRY_REGION_URL" SENTRY_PROJECT_SLUG="$SENTRY_PROJECT_SLUG" \
    "$PYTHON_BIN" - "$issue_id" <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPT_DIR"])
from sentry_client import SentryClient
client = SentryClient(
    auth_token=os.environ["SENTRY_AUTH_TOKEN"],
    org_slug=os.environ["SENTRY_ORG_SLUG"],
    region_url=os.environ.get("SENTRY_REGION_URL", "https://us.sentry.io"),
    project_slug=os.environ.get("SENTRY_PROJECT_SLUG"),
)
client.resolve_issue(sys.argv[1])
print(f"Resolved issue {sys.argv[1]}")
PY
}

mode="${1:-start}"
mkdir -p "${LOG_DIR}" "${STATE_DIR}"

case "$mode" in
  start)
    start_auto_run
    ;;
  once)
    run_once_locked
    ;;
  loop)
    run_loop "${2:-0}"
    ;;
  daemon)
    run_daemon_foreground
    ;;
  status)
    show_status
    ;;
  unlock)
    force_unlock
    ;;
  check-bitbucket)
    check_bitbucket
    ;;
  create-pr)
    if [[ -n "${2:-}" ]]; then
      create_bitbucket_pr "$2" "${3:-fix(sentry): manual PR}" "Manual PR from sentry-auto-fix"
    else
      extract_run_result_env
      maybe_create_pr_from_last_run
    fi
    ;;
  reset-pagination)
    "$PYTHON_BIN" "${SCRIPT_DIR}/sentry_pagination.py" --state-dir "${STATE_DIR}" reset
    ;;
  resolve-issue)
    ensure_python_env
    resolve_sentry_issue "${2:-}" "${3:-}"
    ;;
  record-rejection)
    record_rejection "${2:-}" "${3:-}" "${4:-}" "${5:-}"
    ;;
  list-rejections)
    list_rejections
    ;;
  sync-pr-feedback)
    sync_pr_feedback
    ;;
  test-slack)
    ensure_python_env
    if ! slack_is_configured; then
      echo "Set SLACK_BOT_TOKEN + SLACK_CHANNEL_ID (preferred) or SLACK_WEBHOOK_URL"
      exit 1
    fi
    "$PYTHON_BIN" "${SCRIPT_DIR}/slack_notify.py" test \
      --bot-token "${SLACK_BOT_TOKEN}" \
      --channel-id "${SLACK_CHANNEL_ID}" \
      --webhook-url "${SLACK_WEBHOOK_URL}" \
      --profile "${ACTIVE_PROFILE}"
    ;;
  install-auto)
    install_auto
    ;;
  stop-auto)
    stop_auto
    ;;
  auto-status)
    auto_status
    ;;
  *)
    echo "Usage: $0 [flutter|laravel] [command]"
    echo ""
    echo "Profile (optional first arg — defaults to PROJECT_PROFILE in config.env):"
    echo "  flutter        target Flutter repo + Sentry project (default)"
    echo "  laravel        target Laravel repo + Sentry project (uses LARAVEL_* config keys)"
    echo ""
    echo "Default (no args):"
    echo "  start          auto-install background service on first run, then run forever"
    echo ""
    echo "Manual runs:"
    echo "  once           fix 1 issue in foreground (~10-30 min)"
    echo "  loop [N]       fix issues back-to-back until NO_ACTION (optional max N)"
    echo "  daemon         foreground poll loop (terminal must stay open)"
    echo ""
    echo "Monitor / maintain:"
    echo "  auto-status    is background auto-run active? + last result"
    echo "  status         summary of last run"
    echo "  check-bitbucket  test Bitbucket token"
    echo "  unlock         clear stuck lock"
    echo "  create-pr [branch]  open draft PR manually"
    echo "  reset-pagination  clear Sentry page/exclusion state"
    echo "  resolve-issue <SHORT_ID>  mark issue resolved in Sentry (after deploy)"
    echo "  record-rejection <SHORT_ID> \"reason\" [branch] [reviewer]"
    echo "  list-rejections  show stored PR rejection lessons"
    echo "  sync-pr-feedback  import declined/commented fix/sentry PRs from Bitbucket"
    echo "  test-slack     send a test message (bot+channel or webhook)"
    echo "  install-auto   reinstall background service (per-profile LaunchAgent)"
    echo "  stop-auto      disable background auto-run"
    echo ""
    echo "Examples:"
    echo "  $0 once                      # Flutter (default)"
    echo "  $0 flutter once              # Flutter explicit"
    echo "  $0 laravel once              # Laravel"
    echo "  $0 laravel install-auto      # Install laravel background service"
    echo ""
    echo "Automatic each cycle (no manual steps): Sentry pagination, fix, push, draft PR"
    exit 1
    ;;
esac
