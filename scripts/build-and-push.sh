#!/usr/bin/env bash
set -euo pipefail

# Usage: ./build-and-push.sh [--force|-f] [tag] [base_ref]
# --force / -f : skip change detection, build & push every service
#                (use this the first time you run it, or after any manual
#                 registry cleanup, when there's no meaningful diff to make)
FORCE=false
if [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]]; then
  FORCE=true
  shift
fi

REGISTRY="ghcr.io/vkctl"   # must match IMAGE_OWNER in release.yml
SERVICES=("vote" "worker" "result")

# When true (CI sets this), after pushing a service's image, rewrite that
# service's manifest in k8s/argocd/ to the image's immutable digest.
# Off by default so a local run never edits your working tree.
PIN_DIGESTS="${PIN_DIGESTS:-false}"
TAG="${1:-$(git rev-parse --short HEAD)}"
BASE_REF="${2:-HEAD~1}"   # what to diff against — override in CI to e.g. github.event.before

# GitHub sends an all-zeros SHA for "before" on a branch's first-ever push —
# there's nothing to diff against, so treat it the same as --force.
if [[ "$BASE_REF" =~ ^0+$ ]]; then
  echo "==> No previous commit to diff against (first push) — building everything"
  FORCE=true
fi

for svc in "${SERVICES[@]}"; do
  if [[ "$FORCE" == false ]] && git diff --quiet "$BASE_REF" HEAD -- "app/$svc" 2>/dev/null; then
    echo "==> Skipping $svc (no changes under app/$svc since $BASE_REF)"
    continue
  fi

  echo "==> Building $svc:$TAG"
  docker build -t "$REGISTRY/$svc:$TAG" "./app/$svc"

  echo "==> Tagging $svc as dev-latest"
  docker tag "$REGISTRY/$svc:$TAG" "$REGISTRY/$svc:dev-latest"

  echo "==> Pushing $svc:$TAG and $svc:dev-latest"
  docker push "$REGISTRY/$svc:$TAG"
  docker push "$REGISTRY/$svc:dev-latest"

  # Resolve from the immutable :$TAG just pushed (not :dev-latest, which a
  # concurrent run could move). Skipped services never reach this line, so
  # their manifests keep whatever digest they already had.
  if [[ "$PIN_DIGESTS" == "true" ]]; then
    echo "==> Pinning $svc manifest to the digest of $svc:$TAG"
    REGISTRY="$REGISTRY" bash "$(dirname "$0")/pin-image-digests.sh" "$TAG" "$svc"
  fi
done

echo "Done. Built and pushed tag: $TAG for: ${SERVICES[*]}"
