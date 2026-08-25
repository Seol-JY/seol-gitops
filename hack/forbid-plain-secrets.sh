#!/usr/bin/env bash
set -euo pipefail
bad=0
while IFS= read -r -d '' f; do
  if grep -qE '^kind:[[:space:]]*Secret[[:space:]]*$' -- "$f"; then
    echo "plain Secret manifest: $f"
    bad=1
  fi
done < <(git diff --cached --name-only -z --diff-filter=AM -- '*.yaml' '*.yml')
if [ "$bad" -ne 0 ]; then
  echo "Commit plain Secrets as SealedSecret instead (see docs/runbook.md)."
  exit 1
fi
