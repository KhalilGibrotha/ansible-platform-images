#!/usr/bin/env bash
# Build one authoring image inside the cluster, from this working tree, and
# tag the result by digest.
#
#   scripts/build-in-cluster.sh network      the network image
#   scripts/build-in-cluster.sh full         the enterprise image
#
# Binary build: the devspaces/ directory is uploaded to a build pod in the
# current namespace, the pod builds the Containerfile and pushes to the
# ImageStream, and this script then writes the sha-<commit> tag from the
# digest. The `build` tag moves on every run; a sha- tag is written once.
#
# Images built here stay inside the organisation. OpenShift stamps the
# build namespace into every image it builds, and a pip index set below is
# recorded in the image history. The public network image is the one CI
# builds on a hosted runner.
#
# Environment, all optional:
#   DEVSPACES_BASE              (full only) the base image, normally the
#                               organisation's mirror of the supported image,
#                               by digest
#   DEVSPACES_BASE_PULL_SECRET  (full only) a secret in this namespace that
#                               can pull that base
#   PIP_INDEX_URL               a PyPI proxy for the build pod, where the
#                               cluster has no route to pypi.org
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
# Exactly twelve characters: --short=12 grows the prefix when it is
# ambiguous, and promote-image.sh accepts only twelve.
sha="$(git rev-parse HEAD | cut -c1-12)"

pin_line() {  # tag digest
  echo ""
  echo "Pin it in a devfile in this namespace (tag for humans, digest for the cluster):"
  echo ""
  echo "  image: $reg/$ns/$name:$1@$2"
}

# Digest for a tag, or nothing when the tag does not exist. Any other
# error - Forbidden, a timeout - stops the script: treating it as "absent"
# would let a tag that exists be written over.
istag_digest() {  # tag
  oc get -n "$ns" "istag/$name:$1" --ignore-not-found -o jsonpath='{.image.metadata.name}'
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

# Build arguments go on the BuildConfig itself. `oc start-build --build-arg`
# is ignored for a binary build: oc warns and builds without it. They are
# rewritten in full on every run, so a base set for one build cannot linger
# into the next.
expected_base="$(sed -n 's/^ARG DEVSPACES_BASE=//p' devspaces/Containerfile)"
build_args=(REQUIREMENTS "$variant")
if [ "$variant" = full ] && [ -n "${DEVSPACES_BASE:-}" ]; then
  build_args+=(DEVSPACES_BASE "$DEVSPACES_BASE")
  expected_base="$DEVSPACES_BASE"
  echo "build: enterprise base $DEVSPACES_BASE"
fi
if [ -n "${PIP_INDEX_URL:-}" ]; then
  build_args+=(PIP_INDEX_URL "$PIP_INDEX_URL")
  echo "build: pip index $PIP_INDEX_URL"
fi
patch="$(python3 -c '
import json, sys
a = sys.argv[1:]
args = [{"name": a[i], "value": a[i + 1]} for i in range(0, len(a), 2)]
print(json.dumps([{"op": "replace", "path": "/spec/strategy/dockerStrategy/buildArgs", "value": args}]))
' "${build_args[@]}")"
oc patch -n "$ns" "bc/$name" --type=json -p "$patch" >/dev/null

if [ "$variant" = full ]; then
  if [ -n "${DEVSPACES_BASE_PULL_SECRET:-}" ]; then
    oc set build-secret --pull -n "$ns" "bc/$name" "$DEVSPACES_BASE_PULL_SECRET" >/dev/null
    echo "build: pulling the base with secret $DEVSPACES_BASE_PULL_SECRET"
  else
    oc set build-secret --pull --remove -n "$ns" "bc/$name" >/dev/null
    if [ -n "${DEVSPACES_BASE:-}" ]; then
      echo "build: no DEVSPACES_BASE_PULL_SECRET; the build pod pulls the base with the builder" >&2
      echo "build: service account's own credentials, which reach this cluster's registry only." >&2
    fi
  fi
fi

# --follow streams the build log; --wait makes a failed build a non-zero
# exit here, so a wrong Containerfile stops the script before it tags.
oc start-build -n "$ns" "bc/$name" --from-dir=devspaces --follow --wait

digest="$(istag_digest build)"
if [ -z "$digest" ]; then
  echo "build: the build reported success but $name:build has no image; check 'oc get builds -n $ns'" >&2
  exit 1
fi

# Prove the base that was asked for is the base that was used, from the
# label the Containerfile writes. An enterprise build that quietly fell back
# to the community base must not get a sha- tag.
actual_base="$(oc get -n "$ns" "istag/$name:build" -o jsonpath='{.image.dockerImageMetadata.Config.Labels.org\.opencontainers\.image\.base\.name}')"
if [ -z "$actual_base" ]; then
  echo "build: could not read the image's base label; the base was not verified" >&2
elif [ "$actual_base" != "$expected_base" ]; then
  echo "build: the image was built from $actual_base, not $expected_base." >&2
  echo "build: it stays at $name:build only and gets no sha- tag." >&2
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
echo "base:   ${actual_base:-unverified}"
echo "digest: $digest"
pin_line "$tag" "$digest"
echo ""
if [[ "$tag" == *-dirty ]]; then
  echo "This is a scratch build. Commit, rebuild, and promote the clean one."
else
  echo "Promote it when it has earned a version: scripts/promote-image.sh $name $tag vX.Y.Z"
fi
