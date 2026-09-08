#!/usr/bin/env bash
set -euo pipefail

FORCE=false
if [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]]; then
  FORCE=true
  shift
fi

REGISTRY="ghcr.io/vkctl"
SERVICES=("vote" "worker" "result")
TAG="${1:-$(git rev-parse --short HEAD)}"
BASE_REF="${2:-HEAD~1}"

for svc in "${SERVICES[@]}"; do
  if [[ $FORCE == false ]] && git diff --quiet "$BASE_REF" HEAD -- "app/$svc" 2>/dev/null; then
    echo "==> skipping $svc (no changes under app/$svc since $BASE_REF)"
    continue
  fi

  echo "==> building $svc:$TAG"
  docker build -t "$REGISTRY/$svc:$TAG" "./app/$svc"

  echo "==> pushing $svc:$TAG"
  docker push "$REGISTRY/$svc:$TAG"
done

echo "Done."