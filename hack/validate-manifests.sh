#!/usr/bin/env bash
set -euo pipefail
bad=0

while IFS= read -r d; do
  if ! out=$(kubectl kustomize "$d" 2>&1); then
    echo "kustomize build failed: $d"
    echo "$out" | tail -5
    bad=1
  fi
done < <(find apps infra -name kustomization.yaml -exec dirname {} \; | sort)

while IFS= read -r f; do
  if ! out=$(kubectl apply --dry-run=client -f "$f" 2>&1 >/dev/null); then
    echo "invalid manifest: $f"
    echo "$out" | tail -5
    bad=1
  fi
done < <(find argocd -name '*.yaml' | sort)

if [ "$bad" -ne 0 ]; then
  echo "Fix the manifests above before committing."
  exit 1
fi
