#!/usr/bin/env bash
set -euo pipefail

# Usage: REGISTRY=ghcr.io/<owner> ./scripts/pin-image-digests.sh <tag> <service> [service...]
#
# For each service, asks the REGISTRY (not the local Docker cache) which digest
# <tag> currently points to, then rewrites the image: line in that service's
# OWN manifest to  <registry>/<service>@sha256:<digest>.
#
# The manifest is chosen by convention, never discovered:
#   <MANIFEST_DIR>/<MANIFEST_PREFIX><service>.yaml
#   default: k8s/argocd/argocd-<service>.yaml   (override with the env vars)
#
# It does not scan the directory. It fails unless that file exists and
# contains exactly ONE image: line for the service's repo, so a renamed file
# or an unexpected second reference breaks loudly instead of being guessed at.
#
# Why a digest: a tag like :dev-latest is a moving pointer, so git never
# records which bytes actually run. A digest names exact content, so a change
# of image becomes a change in git, which is what makes Argo CD roll it out,
# and `git revert` roll it back.
#
# Bootstrap (once):  REGISTRY=ghcr.io/vkctl ./scripts/pin-image-digests.sh dev-latest vote worker result
# From CI:           build-and-push.sh calls this right after each push (PIN_DIGESTS=true)

if [[ $# -lt 2 ]]; then
  echo "usage: REGISTRY=ghcr.io/<owner> $0 <tag> <service> [service...]" >&2
  exit 2
fi
: "${REGISTRY:?set REGISTRY, e.g. REGISTRY=ghcr.io/vkctl}"

TAG="$1"
shift

cd "$(git rev-parse --show-toplevel)"
MANIFEST_DIR="${MANIFEST_DIR:-k8s/argocd}"
MANIFEST_DIR="${MANIFEST_DIR%/}"
MANIFEST_PREFIX="${MANIFEST_PREFIX-argocd-}"   # "-" not ":-", so an empty prefix is allowed

for svc in "$@"; do
  repo="${REGISTRY}/${svc}"
  ref="${repo}:${TAG}"
  file="${MANIFEST_DIR}/${MANIFEST_PREFIX}${svc}.yaml"

  # Cheap local check first, before any network call.
  if [[ ! -f "$file" ]]; then
    echo "error: expected manifest $file for service '$svc' does not exist" >&2
    exit 1
  fi

  # Capture the output first instead of piping straight into awk: with
  # pipefail, awk exiting early can SIGPIPE the writer and fail the script.
  inspect_out="$(docker buildx imagetools inspect "$ref")"
  digest="$(awk '/^Digest:/ {print $2; exit}' <<<"$inspect_out")"

  if [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "error: could not resolve a digest for $ref (got '${digest}')" >&2
    exit 1
  fi

  # Matches `image: <repo>`, `image: <repo>:tag`, or `image: <repo>@sha256:...`,
  # optionally followed by a comment, and also `- image: ...` list items.
  # Anchored so `<repo>-extra` is NOT matched.
  repo_re="${repo//./\\.}"
  line_re="^([[:space:]]*(-[[:space:]]+)?image:[[:space:]]+)${repo_re}([:@][^[:space:]#]*)?[[:space:]]*(#.*)?\$"

  matches="$(grep -cE "$line_re" "$file" || true)"
  if [[ "$matches" != "1" ]]; then
    echo "error: expected exactly one 'image: $repo' line in $file, found $matches" >&2
    exit 1
  fi

  new="${repo}@${digest}"
  sed -i -E "s|${line_re}|\\1${new}  # pinned from ${TAG}|" "$file"
  grep -qF "$new" "$file" || { echo "error: rewrite of $file did not take effect" >&2; exit 1; }
  echo "==> $file: $svc -> $digest (from :$TAG)"

  # Not an error, but a stale copy elsewhere in the directory shouldn't go unnoticed.
  others="$(grep -rlE "$line_re" "$MANIFEST_DIR" --include='*.yaml' --include='*.yml' | grep -vxF "$file" || true)"
  if [[ -n "$others" ]]; then
    echo "warning: $repo is also referenced in files this script did not modify:" >&2
    sed 's/^/  /' <<<"$others" >&2
  fi
done
