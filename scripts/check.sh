#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" == "--setup" ]]; then
  (cd "$repo_root/daemon" && npm ci)
  (cd "$repo_root/app" && flutter pub get)
elif [[ $# -ne 0 ]]; then
  echo "Usage: scripts/check.sh [--setup]" >&2
  exit 2
fi

(cd "$repo_root/daemon" && npm run typecheck && npm test && npm run build)
(cd "$repo_root/app" && flutter analyze --no-pub && flutter test --no-pub)
(cd "$repo_root" && openspec validate --all --strict --no-interactive)
