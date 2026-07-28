#!/usr/bin/env bash
# Container entrypoint for sentry-auto-fix.
# Expects:
#   - /toolkit          = this repo (image)
#   - /workspace/app    = Flutter (or Laravel) app clone  → REPO_ROOT
#   - /toolkit/config.env mounted from host (secrets) OR env vars already set
set -euo pipefail

export PATH="${HOME}/.local/bin:/opt/flutter/bin:${HOME}/.pub-cache/bin:/usr/local/bin:${PATH}"
export CURSOR_BIN="${CURSOR_BIN:-/usr/local/bin/cursor}"
export AUTO_INSTALL_LAUNCHAGENT=false

cd /toolkit

# Prefer mounted config.env; otherwise create from example once
if [[ ! -f /toolkit/config.env ]]; then
  if [[ -f /toolkit/config.example.env ]]; then
    cp /toolkit/config.example.env /toolkit/config.env
    echo "entrypoint: created config.env from example — mount a real config.env for production"
  fi
fi

# Default REPO_ROOT inside the container unless config already sets a real path
if [[ -d /workspace/app ]]; then
  # Soft-wire REPO_ROOT when using the compose layout
  if grep -qE '^REPO_ROOT=.*/absolute/path/|REPO_ROOT=.*your-repo|^REPO_ROOT=$' /toolkit/config.env 2>/dev/null \
     || ! grep -q '^REPO_ROOT=' /toolkit/config.env 2>/dev/null; then
    if grep -q '^REPO_ROOT=' /toolkit/config.env 2>/dev/null; then
      sed -i 's|^REPO_ROOT=.*|REPO_ROOT=/workspace/app|' /toolkit/config.env
    else
      echo 'REPO_ROOT=/workspace/app' >> /toolkit/config.env
    fi
  fi
fi

# Ensure CodeGuardian points at the vendored wrapper inside the image
if grep -q '^CODEGUARDIAN_CLI=' /toolkit/config.env 2>/dev/null; then
  sed -i 's|^CODEGUARDIAN_CLI=.*|CODEGUARDIAN_CLI=/toolkit/vendor/codeguardian/bin/codeguardian.sh|' /toolkit/config.env
else
  echo 'CODEGUARDIAN_CLI=/toolkit/vendor/codeguardian/bin/codeguardian.sh' >> /toolkit/config.env
fi
if ! grep -q '^CODEGUARDIAN_ENABLED=' /toolkit/config.env 2>/dev/null; then
  echo 'CODEGUARDIAN_ENABLED=true' >> /toolkit/config.env
fi

# Git identity (required for commits/pushes from the agent worktree)
git config --global user.email "${GIT_AUTHOR_EMAIL:-sentry-autofix@localhost}"
git config --global user.name "${GIT_AUTHOR_NAME:-Sentry Auto-Fix}"
git config --global --add safe.directory /workspace/app || true
git config --global --add safe.directory '*' || true

# Bitbucket HTTPS token helper (optional): BITBUCKET_ACCESS_TOKEN + BITBUCKET_EMAIL
if [[ -n "${BITBUCKET_ACCESS_TOKEN:-}" ]]; then
  git config --global credential.helper store
  # shellcheck disable=SC1091
  set -a && source /toolkit/config.env && set +a || true
  token="${BITBUCKET_ACCESS_TOKEN}"
  email="${BITBUCKET_EMAIL:-x-token-auth}"
  printf 'https://%s:%s@bitbucket.org\n' "${email}" "${token}" > "${HOME}/.git-credentials"
  chmod 600 "${HOME}/.git-credentials"
fi

cmd="${1:-daemon}"
shift || true

profile="${ACTIVE_PROFILE:-flutter}"
case "$cmd" in
  once|daemon|loop|status|test-slack|check-bitbucket|resolve-issue)
    exec ./run.sh "$profile" "$cmd" "$@"
    ;;
  flutter|laravel)
    # Allow: docker compose run autofix flutter once
    exec ./run.sh "$cmd" "$@"
    ;;
  bash|sh)
    exec bash "$@"
    ;;
  *)
    echo "Unknown command: $cmd"
    echo "Usage: once | daemon | loop | status | test-slack | flutter once | bash"
    exit 2
    ;;
esac
