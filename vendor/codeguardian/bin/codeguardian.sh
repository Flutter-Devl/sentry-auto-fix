#!/usr/bin/env bash
# Vendored CodeGuardian CLI entrypoint (forwards all args).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/packages/codeguardian_cli/bin/codeguardian.dart"
if [[ ! -f "$CLI" ]]; then
  echo "codeguardian: missing $CLI — run ./setup.sh from repo root" >&2
  exit 2
fi
cd "$ROOT"
exec dart run "$CLI" "$@"
