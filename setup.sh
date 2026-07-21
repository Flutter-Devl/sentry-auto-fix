#!/usr/bin/env bash
# One-time setup for the combined Sentry Auto-Fix + CodeGuardian toolkit.
#
#   ./setup.sh              # deps only (venv + Melos + wire CodeGuardian)
#   ./setup.sh --auto       # deps + install Flutter background LaunchAgent
#   ./setup.sh --auto flutter laravel
#
# After --auto, the Mac daemon keeps polling Sentry forever (same as before).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

CG_ROOT="$ROOT/vendor/codeguardian"
CG_WRAPPER="$CG_ROOT/bin/codeguardian.sh"

INSTALL_AUTO=false
AUTO_PROFILES=()

usage() {
  cat <<'EOF'
Usage: ./setup.sh [--auto] [flutter|laravel ...]

  (no flags)     Install dependencies only.
  --auto         After deps, install LaunchAgent background auto-run
                 (default profile: flutter). Pass flutter and/or laravel
                 to install one or both.

Examples:
  ./setup.sh
  ./setup.sh --auto
  ./setup.sh --auto flutter laravel
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --auto|--install-auto)
      INSTALL_AUTO=true
      shift
      ;;
    flutter|laravel)
      AUTO_PROFILES+=("$1")
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$INSTALL_AUTO" == "true" && ${#AUTO_PROFILES[@]} -eq 0 ]]; then
  AUTO_PROFILES=(flutter)
fi

echo "==> Python venv"
if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q -r requirements.txt
echo "    OK (.venv + requirements)"

echo "==> config.env"
if [[ ! -f config.env ]]; then
  cp config.example.env config.env
  echo "    Created config.env from config.example.env — edit secrets before --auto / run."
else
  echo "    config.env already present"
fi

echo "==> Dart / Flutter (CodeGuardian)"
if ! command -v dart >/dev/null 2>&1; then
  echo "ERROR: dart not on PATH. Install Flutter SDK and ensure dart is available." >&2
  exit 1
fi
echo "    dart: $(command -v dart) ($(dart --version 2>&1 | head -1))"

export PATH="${HOME}/.pub-cache/bin:${PATH}"
if ! command -v melos >/dev/null 2>&1; then
  echo "    activating melos..."
  dart pub global activate melos
fi
if ! command -v melos >/dev/null 2>&1; then
  echo "ERROR: melos not found after activate. Add \$HOME/.pub-cache/bin to PATH." >&2
  exit 1
fi

echo "==> Bootstrap vendored CodeGuardian"
if [[ ! -d "$CG_ROOT/packages/codeguardian_cli" ]]; then
  echo "ERROR: missing $CG_ROOT/packages — incomplete checkout?" >&2
  exit 1
fi
chmod +x "$CG_WRAPPER" "$ROOT/run.sh"
(
  cd "$CG_ROOT"
  dart pub get >/dev/null
  melos bootstrap
)
echo "    OK (melos bootstrap)"

echo "==> Smoke-test CodeGuardian CLI"
"$CG_WRAPPER" --help >/dev/null
echo "    OK ($CG_WRAPPER)"

echo "==> Wire CodeGuardian into config.env"
python3 - <<PY
from pathlib import Path
import re
p = Path("config.env")
text = p.read_text()
wrapper = "${CG_WRAPPER}"
replacements = {
    "CODEGUARDIAN_ENABLED": "true",
    "CODEGUARDIAN_CLI": wrapper,
    "CODEGUARDIAN_MODE": "validate",
}
for key, val in replacements.items():
    pattern = rf"^{key}=.*$"
    line = f"{key}={val}"
    if re.search(pattern, text, flags=re.M):
        text = re.sub(pattern, line, text, count=1, flags=re.M)
    else:
        text = text.rstrip() + f"\n{line}\n"
p.write_text(text)
print(f"    CODEGUARDIAN_ENABLED=true")
print(f"    CODEGUARDIAN_CLI={wrapper}")
PY

config_ready_for_auto() {
  # shellcheck disable=SC1091
  set -a && source config.env && set +a
  local missing=()
  [[ -z "${REPO_ROOT:-}" || "${REPO_ROOT}" == *"/absolute/path/"* || "${REPO_ROOT}" == *your-repo* ]] && missing+=("REPO_ROOT")
  [[ -z "${SENTRY_ORG_SLUG:-}" || "${SENTRY_ORG_SLUG}" == "your-org-slug" ]] && missing+=("SENTRY_ORG_SLUG")
  [[ -z "${SENTRY_PROJECT_SLUG:-}" || "${SENTRY_PROJECT_SLUG}" == "your-project-slug" ]] && missing+=("SENTRY_PROJECT_SLUG")
  [[ -z "${SENTRY_AUTH_TOKEN:-}" ]] && missing+=("SENTRY_AUTH_TOKEN")
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "config.env not ready for auto-run. Fill: ${missing[*]}" >&2
    return 1
  fi
  if [[ ! -d "${REPO_ROOT}" ]]; then
    echo "REPO_ROOT does not exist: ${REPO_ROOT}" >&2
    return 1
  fi
  return 0
}

if [[ "$INSTALL_AUTO" == "true" ]]; then
  echo "==> Install background auto-run (LaunchAgent)"
  if ! config_ready_for_auto; then
    echo ""
    echo "Deps are ready. Edit config.env, then re-run:"
    echo "  ./setup.sh --auto"
    echo "Or start later with:  ./run.sh flutter start"
    exit 1
  fi
  for profile in "${AUTO_PROFILES[@]}"; do
    echo "    installing profile: ${profile}"
    "$ROOT/run.sh" "$profile" install-auto
  done
  echo ""
  echo "Setup complete — background automation is ON."
  echo "  It starts on login, restarts if it crashes, runs forever."
  echo ""
  echo "Monitor:"
  echo "  ./run.sh flutter status"
  echo "  ./run.sh flutter auto-status"
  echo "  tail -f logs/flutter/daemon.log"
  echo ""
  echo "Stop:"
  echo "  ./run.sh flutter stop-auto"
  exit 0
fi

echo ""
echo "Setup complete (deps only)."
echo ""
echo "Next (same automation model as before):"
echo "  1. Edit config.env   (REPO_ROOT, Sentry, Bitbucket, Cursor)"
echo "  2. One command to automate forever:"
echo "       ./setup.sh --auto"
echo "     or:"
echo "       ./run.sh flutter start"
echo "  3. One-shot test:"
echo "       ./run.sh flutter once"
echo ""
echo "CodeGuardian alone:"
echo "  $CG_WRAPPER validate -p \"\$REPO_ROOT\""
