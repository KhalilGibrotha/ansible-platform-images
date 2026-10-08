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
say "2. Your permissions in $ns"
# Every verb each step of the loop uses. `oc apply` needs get and patch as
# well as create, from the second run on; a user with create alone passes a
# create-only check and then fails before the build starts.
#
# Subresources go in --subresource. `oc auth can-i create builds/docker`
# reads `docker` as the NAME of a build, so it answers yes for anyone who
# can create builds - including someone the docker grant was taken from.
check_can() {  # "verbs" resource subresource label role-to-ask
  local verbs="$1" resource="$2" sub="$3" label="$4" role="$5" denied="" extra=()
  [ -n "$sub" ] && extra=(--subresource="$sub")
  for verb in $verbs; do
    [ "$(oc auth can-i "$verb" "$resource" ${extra[@]+"${extra[@]}"} -n "$ns" 2>/dev/null)" = "yes" ] || denied="$denied $verb"
  done
  if [ -z "$denied" ]; then
    ok "$label"
  else
    bad "$label (denied:$denied)"
    ask "$role"
  fi
}
check_can "get create patch"   buildconfigs    ""                 "manage BuildConfigs (oc apply, build arguments)" "the 'edit' role in $ns"
check_can "create"             buildconfigs    instantiatebinary  "start a build from an uploaded directory"        "the 'edit' role in $ns"
check_can "get"                builds          log                "follow a build's log"                            "the 'edit' role in $ns"
check_can "get create patch"   imagestreams    ""                 "manage ImageStreams (oc apply)"                  "the 'edit' role in $ns"
check_can "get create update"  imagestreamtags ""                 "tag images by digest (build, promote)"           "the 'edit' role in $ns"

# The docker build strategy is a cluster-level grant, bound to every
# authenticated user by default and commonly removed by hardening. Its
# absence fails a build with 'build strategy Docker is not allowed', after
# everything above passed.
check_can "create" builds docker "use the Docker build strategy (cluster-level grant)" \
  "the OpenShift platform team for the 'system:build-strategy-docker' cluster role, bound to you or to the namespace"

if [ "$(oc auth can-i create secrets -n "$ns" 2>/dev/null)" = "yes" ]; then
  info "you can create secrets: needed later for a Quay push secret or an enterprise base pull secret"
else
  info "you cannot create secrets: not needed now; needed later for Quay or the enterprise base"
fi

say ""
say "3. The account that pushes"
# The build pod pushes its output as the namespace's builder service
# account, not as you. OpenShift creates that account in every namespace
# when the Build capability is enabled and binds it to system:image-builder
# through the system:image-builders role binding.
if oc get sa builder -n "$ns" >/dev/null 2>&1; then
  subjects="$(oc get rolebinding system:image-builders -n "$ns" -o jsonpath='{.subjects[*].name}' 2>/dev/null || true)"
  if [ -z "$subjects" ]; then
    ok "builder service account exists; its default push binding is not readable by you, which is normal"
  elif printf '%s\n' "$subjects" | tr ' ' '\n' | grep -qx builder; then
    ok "builder service account exists and system:image-builders binds it, so builds can push"
  else
    bad "system:image-builders does not bind the builder service account; builds cannot push"
    ask "a namespace admin to restore it: oc policy add-role-to-user system:image-builder -z builder -n $ns"
  fi
else
  bad "no builder service account in $ns"
  ask "the OpenShift platform team: the Build capability creates it in every namespace"
fi

say ""
say "4. Registry"
# `oc registry info` finds the registry through an ImageStream in this
# namespace or in `openshift`. Before the first build there may be none in
# either - sample streams are often removed - so a failure here is not proof
# the registry is missing, and is reported as information only.
if reg="$(oc registry info 2>/dev/null)"; then
  ok "integrated registry: $reg"
  if oc registry info --public >/dev/null 2>&1; then
    info "it has a public route; images can also be pulled from outside the cluster"
  else
    info "no public route; the in-cluster address above is the one devfiles pin"
  fi
else
  info "could not look up the integrated registry; normal before the first build,"
  info "when no ImageStream exists to ask. If the build then fails to push, ask the"
  info "OpenShift platform team to confirm the image registry operator is managed."
fi

say ""
say "5. Room to build"
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
