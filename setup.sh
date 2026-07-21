#!/usr/bin/env bash
# One-time dependency setup for the combined Sentry Auto-Fix + CodeGuardian toolkit.
# Does NOT install the LaunchAgent — use: ./run.sh flutter install-auto  (or start).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

CG_ROOT="$ROOT/vendor/codeguardian"
CG_WRAPPER="$CG_ROOT/bin/codeguardian.sh"

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
  echo "    Created config.env from config.example.env — edit secrets before running."
else
  echo "    config.env already present"
fi

echo "==> Dart / Flutter (CodeGuardian)"
if ! command -v dart >/dev/null 2>&1; then
  echo "ERROR: dart not on PATH. Install Flutter SDK and ensure dart is available." >&2
  exit 1
fi
echo "    dart: $(command -v dart) ($(dart --version 2>&1 | head -1))"

if ! command -v melos >/dev/null 2>&1; then
  echo "    activating melos..."
  dart pub global activate melos
fi
# Ensure pub-cache bin is usable for this shell
export PATH="${PATH}:$(dart pub cache path 2>/dev/null || true)/bin"
export PATH="${HOME}/.pub-cache/bin:${PATH}"
if ! command -v melos >/dev/null 2>&1; then
  echo "ERROR: melos not found after activate. Add \$HOME/.pub-cache/bin to PATH." >&2
  exit 1
fi

echo "==> Bootstrap vendored CodeGuardian"
if [[ ! -d "$CG_ROOT/packages/codeguardian_cli" ]]; then
  echo "ERROR: missing $CG_ROOT/packages — incomplete checkout?" >&2
  exit 1
fi
chmod +x "$CG_WRAPPER"
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
# Enable + point at vendored CLI (idempotent)
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

echo ""
echo "Setup complete (deps only — LaunchAgent not installed)."
echo ""
echo "Next:"
echo "  1. Edit config.env  (REPO_ROOT, Sentry, Bitbucket, Cursor)"
echo "  2. Optional background:  ./run.sh flutter install-auto"
echo "  3. Run once:            ./run.sh flutter once"
echo "  4. Or start loop:       ./run.sh flutter start"
echo ""
echo "CodeGuardian alone:"
echo "  $CG_WRAPPER validate -p \"\$REPO_ROOT\""
