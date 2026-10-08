#!/usr/bin/env bash
# A stand-in for oc that records every call and answers from a state
# directory, so the in-cluster scripts' own logic can be exercised with no
# cluster: in CI on a hosted runner, and on a laptop. It answers only what
# those scripts ask; anything else exits 99 so a new oc call in a script
# shows up as a test failure rather than a silent pass.
#
# Where real oc is lenient in a way that hid a bug, the stub is strict:
#   - can-i with `resource/name` exits 99: real oc reads the part after the
#     slash as a resource NAME, so `builds/docker` silently checks the wrong
#     thing. Subresources must come as --subresource=.
#   - start-build with --from-dir ignores --build-arg, exactly as real oc
#     does, so a base passed that way never reaches the image.
#
#   STUB_STATE/log                   every invocation, one line each, -n <ns> removed
#   STUB_STATE/istag/<name:tag>      present = tag exists; content = digest
#   STUB_STATE/label/<name:tag>      the image's base label
#   STUB_STATE/can-i                 default answer to every can-i, "yes" or "no"
#   STUB_STATE/can-i.d/<v>_<r>_<s>   answer for one verb, resource, subresource
#   STUB_STATE/bc/<name>             the build arguments last patched onto a BuildConfig
#   STUB_STATE/fail-build            present = start-build exits 1
#   STUB_STATE/no-build-tag          present = start-build succeeds but writes no image
#   STUB_STATE/base-label            present = the built image carries this base instead
#   STUB_STATE/forbidden             present = every istag lookup is Forbidden
#   STUB_STATE/no-registry-info      present = oc registry info finds no ImageStreams
#   STUB_STATE/no-builder            present = the builder service account is absent
#   STUB_STATE/binding-subjects      subjects of system:image-builders (default "builder";
#                                    an empty file = the binding is not readable)
#   STUB_STATE/shipwright            present = the Shipwright API is served
#   STUB_DEFAULT_BASE (env)          the base a build uses when none is patched in
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
has() { local x="$1"; shift; for a in "$@"; do [ "$a" = "$x" ] && return 0; done; return 1; }

case "$1" in
  whoami) echo "stub-user" ;;
  project) echo "stub-ns" ;;
  registry)
    case "${2:-}" in
      info)
        [ -f "$state/no-registry-info" ] && { echo "error: no image streams could be located to retrieve registry info" >&2; exit 1; }
        [ "${3:-}" = "--public" ] && exit 1
        echo "image-registry.openshift-image-registry.svc:5000" ;;
    esac ;;
  api-resources)
    group=""; for a in "$@"; do case "$a" in --api-group=*) group="${a#--api-group=}";; esac; done
    case "$group" in
      build.openshift.io) echo "buildconfigs   bc   build.openshift.io/v1   true   BuildConfig" ;;
      shipwright.io) [ -f "$state/shipwright" ] && echo "builds   shipwright.io/v1beta1   true   Build" ;;
    esac ;;
  auth)
    # oc auth can-i VERB RESOURCE [--subresource=X]
    verb="$3"; resource="$4"; sub=""
    for a in "$@"; do case "$a" in --subresource=*) sub="${a#--subresource=}";; esac; done
    case "$resource" in
      */*) echo "stub oc: can-i '$resource' reads '${resource#*/}' as a resource name; use --subresource" >&2; exit 99 ;;
    esac
    f="$state/can-i.d/${verb}_${resource}_${sub}"
    if [ -f "$f" ]; then cat "$f"; else cat "$state/can-i"; fi ;;
  apply) : ;;
  patch)
    # oc patch bc/<name> --type=json -p <json>: keep the build arguments
    bc="${2#bc/}"; json=""
    while [ $# -gt 0 ]; do [ "$1" = "-p" ] && json="$2"; shift; done
    mkdir -p "$state/bc"; printf '%s\n' "$json" > "$state/bc/$bc" ;;
  set)
    [ "${2:-}" = "build-secret" ] || { echo "stub oc: unhandled: $*" >&2; exit 99; } ;;
  start-build)
    bc="${2#bc/}"
    if printf '%s\n' "$@" | grep -q '^--from-dir=' && printf '%s\n' "$@" | grep -q '^--build-arg'; then
      echo "WARNING: Specifying build arguments with binary builds is not supported." >&2
    fi
    if [ -f "$state/fail-build" ]; then echo "error: build failed (stub)" >&2; exit 1; fi
    echo "build.build.openshift.io/stub-1 started"
    [ -f "$state/no-build-tag" ] && exit 0
    mkdir -p "$state/istag" "$state/label"
    echo "$digest" > "$state/istag/$bc:build"
    # The base the image really gets: what the BuildConfig's arguments say,
    # never a --build-arg on this command line.
    base="${STUB_DEFAULT_BASE:-}"
    if [ -f "$state/bc/$bc" ]; then
      patched="$(python3 -c '
import json, sys
for a in json.load(open(sys.argv[1]))[0]["value"]:
    if a["name"] == "DEVSPACES_BASE":
        print(a["value"])
' "$state/bc/$bc")"
      [ -n "$patched" ] && base="$patched"
    fi
    [ -f "$state/base-label" ] && base="$(cat "$state/base-label")"
    printf '%s\n' "$base" > "$state/label/$bc:build" ;;
  get)
    case "$2" in
      istag/*)
        [ -f "$state/forbidden" ] && { echo "Error from server (Forbidden): imagestreamtags is forbidden" >&2; exit 1; }
        key="${2#istag/}"
        if printf '%s\n' "$@" | grep -q 'Labels'; then
          [ -f "$state/label/$key" ] && cat "$state/label/$key"
          exit 0
        fi
        if [ -f "$state/istag/$key" ]; then
          cat "$state/istag/$key"
        elif has --ignore-not-found "$@"; then
          exit 0
        else
          echo "Error from server (NotFound): $2 not found" >&2; exit 1
        fi ;;
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
