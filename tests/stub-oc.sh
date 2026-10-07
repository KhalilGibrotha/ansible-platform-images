#!/usr/bin/env bash
# A stand-in for oc that records every call and answers from a state
# directory, so the in-cluster scripts' own logic can be exercised with no
# cluster: in CI on a hosted runner, and on a laptop. It answers only what
# those scripts ask; anything else exits 99 so a new oc call in a script
# shows up as a test failure rather than a silent pass.
#   STUB_STATE/log            every invocation, one per line
#   STUB_STATE/istag/<name>   file present = tag exists; content = digest
#   STUB_STATE/can-i          "yes" or "no" for every can-i
#   STUB_STATE/fail-build     present = start-build exits 1
#   STUB_STATE/apiresources   lines returned for api-resources
set -u
state="${STUB_STATE:?}"
printf '%s\n' "oc $*" >> "$state/log"

# strip -n <ns> wherever it appears
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -n) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]}"
printf '%s
' "oc $*" >> "$state/log"

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
  start-build)
    if [ -f "$state/fail-build" ]; then echo "error: build failed (stub)" >&2; exit 1; fi
    echo "build.build.openshift.io/stub-1 started"
    # the build "writes" the moving tag
    mkdir -p "$state/istag"; echo "sha256:$(printf 'd%.0s' {1..64})" > "$state/istag/${2#bc/}:build" ;;
  get)
    case "$2" in
      istag/*) f="$state/istag/${2#istag/}"; if [ -f "$f" ]; then cat "$f"; else echo "Error from server (NotFound): $2 not found" >&2; exit 1; fi ;;
      resourcequota) exit 1 ;;
      limitrange) : ;;
      *) : ;;
    esac ;;
  tag)
    # oc tag <is>@<digest> <is>:<tag>
    src="$2"; dst="$3"; mkdir -p "$state/istag"; echo "${src#*@}" > "$state/istag/$dst" ;;
  *) echo "stub oc: unhandled: $*" >&2; exit 99 ;;
esac
