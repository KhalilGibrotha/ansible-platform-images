#!/usr/bin/env bash
# Promote a built image to a version: copy its digest to a vX.Y.Z tag.
#
#   scripts/promote-image.sh ansible-devspaces-network sha-ab0edbba1f94 v0.1.0
#
# Nothing is rebuilt. The version tag points at the same digest the sha-
# tag does, so what was tested is what ships. Only a sha-<commit> tag can be
# promoted: the moving `build` tag and scratch `-dirty` builds name nothing
# anyone can trace back to a commit. A version tag is written once; this
# script refuses to move one that exists, because a tag that can move is a
# tag nobody can trust, and the next change is the next version.
set -euo pipefail

name="${1:-}"; from="${2:-}"; version="${3:-}"
if [ -z "$name" ] || [ -z "$from" ] || [ -z "$version" ]; then
  echo "usage: $0 <image> <sha-tag> <vX.Y.Z>" >&2; exit 2
fi
if ! [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "promote: version must look like v1.2.3, got '$version'" >&2; exit 2
fi
if ! [[ "$from" =~ ^sha-[0-9a-f]{12}$ ]]; then
  echo "promote: only a sha-<commit> tag from a clean build can be promoted, got '$from'" >&2
  echo "promote: 'build' moves on every run and '-dirty' builds name no commit." >&2
  exit 2
fi

ns="${DEVWORKSPACE_NAMESPACE:-$(oc project -q)}"

# Digest for a tag, or nothing when the tag does not exist. Any other
# error - Forbidden, a timeout - stops the script: treating it as "absent"
# would let a version that exists be written over.
istag_digest() {  # tag
  oc get -n "$ns" "istag/$name:$1" --ignore-not-found -o jsonpath='{.image.metadata.name}'
}

existing="$(istag_digest "$version")"
if [ -n "$existing" ]; then
  echo "promote: $name:$version already exists at $existing and a version never moves." >&2
  echo "promote: cut the next version instead." >&2
  exit 1
fi

digest="$(istag_digest "$from")"
if [ -z "$digest" ]; then
  echo "promote: $name:$from not found in $ns; build it first" >&2
  exit 1
fi

oc tag -n "$ns" "$name@$digest" "$name:$version" >/dev/null

reg="image-registry.openshift-image-registry.svc:5000"
echo "promoted: $name:$from -> $name:$version"
echo "digest:   $digest (unchanged)"
echo ""
echo "  image: $reg/$ns/$name:$version@$digest"
