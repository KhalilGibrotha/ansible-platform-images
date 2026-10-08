#!/usr/bin/env bash
# Build one authoring image inside the cluster, from this working tree, and
# tag the result by digest.
#
#   scripts/build-in-cluster.sh network      the public network image
#   scripts/build-in-cluster.sh full         the enterprise image
#
# Binary build: the devspaces/ directory is uploaded to a build pod in the
# current namespace, the pod builds the Containerfile and pushes to the
# ImageStream, and this script then writes the sha-<commit> tag from the
# digest. The `build` tag moves on every run; a sha- tag is written once.
#
# Environment, both optional and read only by the `full` variant:
#   DEVSPACES_BASE              the base image, normally the organisation's
#                               mirror of the supported image, by digest
#   DEVSPACES_BASE_PULL_SECRET  a secret in this namespace that can pull it;
#                               set on the BuildConfig as its pull secret
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

variant="${1:-}"
case "$variant" in
  network) name=ansible-devspaces-network ;;
  full)    name=ansible-devspaces ;;
  *) echo "usage: $0 network|full" >&2; exit 2 ;;
esac

ns="${DEVWORKSPACE_NAMESPACE:-$(oc project -q)}"
reg="image-registry.openshift-image-registry.svc:5000"
sha="$(git rev-parse --short=12 HEAD)"

pin_line() {  # tag digest
  echo ""
  echo "Pin it in a devfile in this namespace (tag for humans, digest for the cluster):"
  echo ""
  echo "  image: $reg/$ns/$name:$1@$2"
}

istag_digest() {  # tag -> digest on stdout, or nothing if the tag is absent
  oc get -n "$ns" "istag/$name:$1" -o jsonpath='{.image.metadata.name}' 2>/dev/null || true
}

# Everything under devspaces/ is uploaded - tracked, untracked, and ignored
# alike - so the tree only matches the commit when git reports nothing
# there at all. A sha- tag on anything else names a tree nobody can check out.
if [ -n "$(git status --porcelain --untracked-files=all --ignored=matching -- devspaces)" ]; then
  echo "build: devspaces/ differs from commit $sha (changed, untracked, or ignored files):" >&2
  git status --short --untracked-files=all --ignored=matching -- devspaces | sed 's/^/  /' >&2
  echo "build: commit or remove them, or build anyway with BUILD_DIRTY=1." >&2
  echo "build: a dirty build is tagged sha-<commit>-dirty, may be overwritten, and cannot be promoted." >&2
  [ "${BUILD_DIRTY:-}" = "1" ] || exit 1
  sha="$sha-dirty"
fi
tag="sha-$sha"

# A commit is built once. Rebuilding it would produce a new digest - layer
# timestamps alone see to that - and moving the tag to it would make every
# devfile pinned to the old one point at an image nobody tested.
if [[ "$tag" != *-dirty ]]; then
  existing="$(istag_digest "$tag")"
  if [ -n "$existing" ]; then
    echo "build: $name:$tag already exists; a commit is built once and its tag never moves."
    echo "digest: $existing"
    pin_line "$tag" "$existing"
    exit 0
  fi
fi

echo "build: $name in $ns from commit $sha"
oc apply -n "$ns" -f openshift/ >/dev/null

args=()
if [ "$variant" = full ] && [ -n "${DEVSPACES_BASE:-}" ]; then
  echo "build: enterprise base $DEVSPACES_BASE"
  args+=(--build-arg "DEVSPACES_BASE=$DEVSPACES_BASE")
  if [ -n "${DEVSPACES_BASE_PULL_SECRET:-}" ]; then
    oc set build-secret --pull -n "$ns" "bc/$name" "$DEVSPACES_BASE_PULL_SECRET" >/dev/null
    echo "build: pulling the base with secret $DEVSPACES_BASE_PULL_SECRET"
  else
    echo "build: no DEVSPACES_BASE_PULL_SECRET; the build pod pulls the base with the builder" >&2
    echo "build: service account's own credentials, which reach this cluster's registry only." >&2
  fi
fi

# --follow streams the build log; --wait makes a failed build a non-zero
# exit here, so a wrong Containerfile stops the script before it tags.
oc start-build -n "$ns" "bc/$name" --from-dir=devspaces ${args[@]+"${args[@]}"} --follow --wait

digest="$(istag_digest build)"
if [ -z "$digest" ]; then
  echo "build: the build reported success but $name:build has no image; check 'oc get builds -n $ns'" >&2
  exit 1
fi

# Checked again after the build: another build of the same commit may have
# finished first. The tag it wrote stands.
if [[ "$tag" != *-dirty ]]; then
  existing="$(istag_digest "$tag")"
  if [ -n "$existing" ] && [ "$existing" != "$digest" ]; then
    echo "build: $name:$tag was written by another build while this one ran ($existing)." >&2
    echo "build: it is left in place; this build's image stays at $name:build only." >&2
    exit 1
  fi
fi

# Tag by digest, never by the moving tag, so the sha- tag names this exact
# image even after the next build overwrites `build`.
oc tag -n "$ns" "$name@$digest" "$name:$tag" >/dev/null

echo ""
echo "built:  $name:$tag"
echo "digest: $digest"
pin_line "$tag" "$digest"
echo ""
if [[ "$tag" == *-dirty ]]; then
  echo "This is a scratch build. Commit, rebuild, and promote the clean one."
else
  echo "Promote it when it has earned a version: scripts/promote-image.sh $name $tag vX.Y.Z"
fi
