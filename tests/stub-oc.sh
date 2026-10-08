#!/usr/bin/env bash
# A stand-in for oc that records every call and answers from a state
# directory, so the in-cluster scripts' own logic can be exercised with no
# cluster: in CI on a hosted runner, and on a laptop. It answers only what
# those scripts ask; anything else exits 99 so a new oc call in a script
# shows up as a test failure rather than a silent pass.
#
#   STUB_STATE/log               every invocation, one line each, -n <ns> removed
#   STUB_STATE/istag/<name:tag>  present = tag exists; content = digest
#   STUB_STATE/can-i             "yes" or "no", the answer to every can-i
#   STUB_STATE/fail-build        present = start-build exits 1
#   STUB_STATE/no-build-tag      present = start-build succeeds but writes no image
#   STUB_STATE/no-builder        present = the builder service account is absent
#   STUB_STATE/binding-subjects  subjects of system:image-builders (default "builder";
#                                an empty file = the binding is not readable)
#   STUB_STATE/shipwright        present = the Shipwright API is served
set -u
state="${STUB_STATE:?}"

# Drop -n <ns> wherever it appears, then log the call once, as normalised.
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -n) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
printf '%s\n' "oc $*" >> "$state/log"

digest="sha256:$(printf 'd%.0s' {1..64})"

case "$1" in
  whoami) echo "stub-user" ;;
  project) echo "stub-ns" ;;
  registry)
    case "${2:-}" in
      info) [ "${3:-}" = "--public" ] && exit 1; echo "image-registry.openshift-image-registry.svc:5000" ;;
    esac ;;
  api-resources)
    group=""; for a in "$@"; do case "$a" in --api-group=*) group="${a#--api-group=}";; esac; done
    case "$group" in
      build.openshift.io) echo "buildconfigs   bc   build.openshift.io/v1   true   BuildConfig" ;;
      shipwright.io) [ -f "$state/shipwright" ] && echo "builds   shipwright.io/v1beta1   true   Build" ;;
    esac ;;
  auth) cat "$state/can-i" ;;
  apply) : ;;
  set)
    # oc set build-secret --pull bc/<name> <secret>
    [ "${2:-}" = "build-secret" ] || { echo "stub oc: unhandled: $*" >&2; exit 99; } ;;
  start-build)
    if [ -f "$state/fail-build" ]; then echo "error: build failed (stub)" >&2; exit 1; fi
    echo "build.build.openshift.io/stub-1 started"
    # the build writes the moving tag, unless told not to
    if [ ! -f "$state/no-build-tag" ]; then
      mkdir -p "$state/istag"; echo "$digest" > "$state/istag/${2#bc/}:build"
    fi ;;
  get)
    case "$2" in
      istag/*) f="$state/istag/${2#istag/}"; if [ -f "$f" ]; then cat "$f"; else echo "Error from server (NotFound): $2 not found" >&2; exit 1; fi ;;
      sa) [ -f "$state/no-builder" ] && exit 1; echo "builder" ;;
      rolebinding)
        if [ -f "$state/binding-subjects" ]; then
          [ -s "$state/binding-subjects" ] || { echo "Error from server (Forbidden)" >&2; exit 1; }
          cat "$state/binding-subjects"
        else
          echo "builder"
        fi ;;
      resourcequota) exit 1 ;;
      limitrange) : ;;
      *) echo "stub oc: unhandled: $*" >&2; exit 99 ;;
    esac ;;
  tag)
    # oc tag <is>@<digest> <is>:<tag>
    src="$2"; dst="$3"; mkdir -p "$state/istag"; echo "${src#*@}" > "$state/istag/$dst" ;;
  *) echo "stub oc: unhandled: $*" >&2; exit 99 ;;
esac
