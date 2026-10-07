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
# digest. The `build` tag moves on every run; the sha- tag never does.
#
# DEVSPACES_BASE, when set and the variant is `full`, is passed through as
# the base image, so the enterprise build takes the mirrored supported
# image without any file carrying its hostname.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

variant="${1:-}"
case "$variant" in
  network) name=ansible-devspaces-network ;;
  full)    name=ansible-devspaces ;;
  *) echo "usage: $0 network|full" >&2; exit 2 ;;
esac

ns="${DEVWORKSPACE_NAMESPACE:-$(oc project -q)}"
sha="$(git rev-parse --short=12 HEAD)"
if ! git diff --quiet -- devspaces || ! git diff --cached --quiet -- devspaces; then
  echo "build: devspaces/ has uncommitted changes; the sha- tag would name a tree that is not this one" >&2
  echo "build: commit them, or build anyway with BUILD_DIRTY=1 (tag gets a -dirty suffix)" >&2
  [ "${BUILD_DIRTY:-}" = "1" ] || exit 1
  sha="$sha-dirty"
fi

echo "build: $name in $ns from commit $sha"
oc apply -n "$ns" -f openshift/ >/dev/null

args=()
if [ "$variant" = full ] && [ -n "${DEVSPACES_BASE:-}" ]; then
  echo "build: enterprise base $DEVSPACES_BASE"
  args+=(--build-arg "DEVSPACES_BASE=$DEVSPACES_BASE")
fi

# --follow streams the build log; --wait makes a failed build a non-zero
# exit here, so a wrong Containerfile stops the script before it tags.
oc start-build -n "$ns" "bc/$name" --from-dir=devspaces ${args[@]+"${args[@]}"} --follow --wait

digest="$(oc get -n "$ns" "istag/$name:build" -o jsonpath='{.image.metadata.name}')"
if [ -z "$digest" ]; then
  echo "build: the build reported success but $name:build has no image; check 'oc get builds -n $ns'" >&2
  exit 1
fi

# Tag by digest, never by the moving tag, so sha-<commit> names this exact
# image even after the next build overwrites `build`.
oc tag -n "$ns" "$name@$digest" "$name:sha-$sha" >/dev/null

reg="image-registry.openshift-image-registry.svc:5000"
echo ""
echo "built:  $name:sha-$sha"
echo "digest: $digest"
echo ""
echo "Pin it in a devfile in this namespace (tag for humans, digest for the cluster):"
echo ""
echo "  image: $reg/$ns/$name:sha-$sha@$digest"
echo ""
echo "Promote it when it has earned a version: scripts/promote-image.sh $name sha-$sha vX.Y.Z"
