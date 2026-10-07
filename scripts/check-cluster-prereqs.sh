#!/usr/bin/env bash
# Say, before the first build, exactly what the in-cluster image loop needs
# and which of it this user has in this namespace - so a missing permission
# is a named request rather than a failed build with a 403 somewhere in it.
#
# Read-only. Safe to run anywhere oc is logged in.
set -uo pipefail

ns="${DEVWORKSPACE_NAMESPACE:-$(oc project -q 2>/dev/null || true)}"
missing=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok       %s\n' "$*"; }
bad()  { printf '  MISSING  %s\n' "$*"; missing=$((missing + 1)); }
ask()  { printf '           ask for: %s\n' "$*"; }
info() { printf '  info     %s\n' "$*"; }

if ! command -v oc >/dev/null 2>&1; then
  say "oc is not on PATH; run this from a Dev Spaces workspace or install oc."
  exit 2
fi
if ! oc whoami >/dev/null 2>&1; then
  say "oc is not logged in. In a workspace that means the token did not mount;"
  say "restart the workspace. Elsewhere, 'oc login' first."
  exit 2
fi
if [ -z "$ns" ]; then
  say "no namespace: set DEVWORKSPACE_NAMESPACE or 'oc project <ns>'"
  exit 2
fi

say "user:      $(oc whoami)"
say "namespace: $ns"
say ""

say "1. Build API"
if oc api-resources --api-group=build.openshift.io 2>/dev/null | grep -q '^buildconfigs'; then
  ok "BuildConfig (build.openshift.io) is served; the MVP uses this"
else
  bad "BuildConfig API is not served on this cluster"
  ask "the OpenShift platform team to confirm the Build capability is enabled"
fi
if oc api-resources --api-group=shipwright.io 2>/dev/null | grep -q '^builds'; then
  info "Shipwright (Builds for OpenShift) is also installed - the later form"
else
  info "Shipwright is not installed; not needed for the MVP"
fi

say ""
say "2. Permissions in $ns"
check_can() {  # verb resource label role-to-ask
  if [ "$(oc auth can-i "$1" "$2" -n "$ns" 2>/dev/null)" = "yes" ]; then
    ok "$3"
  else
    bad "$3"
    ask "$4"
  fi
}
check_can create buildconfigs        "create BuildConfigs"                    "the 'edit' role in $ns"
check_can create builds              "start builds"                           "the 'edit' role in $ns"
check_can create imagestreams        "create ImageStreams"                    "the 'edit' role in $ns"
check_can update imagestreams/layers "push to the integrated registry"        "the 'system:image-builder' role in $ns"
check_can create imagestreamtags     "tag images by digest (promotion)"       "the 'edit' role in $ns"
check_can create secrets             "create a push secret (Quay, later)"     "the 'edit' role in $ns"

# The docker build strategy is a cluster-level grant, on by default and
# commonly removed by hardening. Its absence fails a build with
# 'build strategy Docker is not allowed', after everything above passed.
if [ "$(oc auth can-i create builds/docker -n "$ns" 2>/dev/null)" = "yes" ]; then
  ok "use the Docker build strategy"
else
  bad "use the Docker build strategy (cluster-level grant)"
  ask "the OpenShift platform team for the 'system:build-strategy-docker' cluster role, bound to you or to the namespace"
fi

say ""
say "3. Registry"
if reg="$(oc registry info 2>/dev/null)"; then
  ok "integrated registry: $reg"
  if oc registry info --public >/dev/null 2>&1; then
    info "it has a public route; images can also be pulled from outside the cluster"
  else
    info "no public route; the in-cluster address above is the one devfiles pin"
  fi
else
  bad "integrated registry is not reachable or not enabled"
  ask "the OpenShift platform team to confirm the image registry operator is managed"
fi

say ""
say "4. Room to build"
if oc get resourcequota -n "$ns" >/dev/null 2>&1; then
  q="$(oc get resourcequota -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}: {.status.used.limits\.memory}/{.status.hard.limits\.memory} memory{"\n"}{end}' 2>/dev/null)"
  if [ -n "$q" ]; then
    info "quota present; a build pod asks for 1Gi and may use up to 4Gi:"
    printf '%s\n' "$q" | sed 's/^/             /'
  else
    ok "no memory quota on the namespace"
  fi
fi
if oc get limitrange -n "$ns" -o name 2>/dev/null | grep -q .; then
  info "a LimitRange exists; if a build fails at admission, its max memory is the cause"
fi

say ""
if [ "$missing" -eq 0 ]; then
  say "everything the MVP needs is in place; next: scripts/build-in-cluster.sh network"
else
  say "$missing item(s) missing; the 'ask for' lines are the request, nothing broader"
  exit 1
fi
