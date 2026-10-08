#!/usr/bin/env bash
# Exercise the in-cluster scripts against the stub oc: happy paths and
# every refusal they claim to make. Runs anywhere with bash, git, and
# python3; no cluster, no oc. The stub is strict where real oc is lenient
# in ways that once hid bugs - see the notes at the top of stub-oc.sh.
#
#   bash tests/test-in-cluster-scripts.sh
set -u
repo="$(git rev-parse --show-toplevel)"
bin="$(mktemp -d)"; cp "$repo/tests/stub-oc.sh" "$bin/oc"; chmod +x "$bin/oc"
export PATH="$bin:$PATH"
export DEVWORKSPACE_NAMESPACE=stub-ns
STUB_DEFAULT_BASE="$(sed -n 's/^ARG DEVSPACES_BASE=//p' "$repo/devspaces/Containerfile")"
export STUB_DEFAULT_BASE
pass=0; fail=0
t() { if "$@"; then pass=$((pass+1)); echo "  PASS"; else fail=$((fail+1)); echo "  FAIL: $*"; fi; }
tn() { if ! "$@"; then pass=$((pass+1)); echo "  PASS"; else fail=$((fail+1)); echo "  FAIL (expected no match): $*"; fi; }
fresh() { STUB_STATE="$(mktemp -d)"; export STUB_STATE; echo yes > "$STUB_STATE/can-i"; touch "$STUB_STATE/log"; }
calls() { grep -c -- "$1" "$STUB_STATE/log"; }
args_of() { python3 -c 'import json,sys; print(" ".join(a["name"]+"="+a["value"] for a in json.load(open(sys.argv[1]))[0]["value"]))' "$STUB_STATE/bc/$1"; }
cd "$repo" || exit 1
if [ -n "$(git status --porcelain --untracked-files=all --ignored=matching -- devspaces)" ]; then
  echo "devspaces/ is not clean before the tests; aborting"; exit 1
fi
digest_re="sha256:d{64}"
sha12="$(git rev-parse HEAD | cut -c1-12)"

echo "1. build network, clean tree: tags sha- by digest and prints the pin line"
fresh; out="$(bash scripts/build-in-cluster.sh network 2>&1)"; rc=$?
echo "$out" | grep -E "^built:|^base:|^  image:" | sed 's/^/     /'
t [ "$rc" -eq 0 ]
t grep -q "oc start-build bc/ansible-devspaces-network --from-dir=devspaces --follow --wait$" "$STUB_STATE/log"
t grep -qE "oc tag ansible-devspaces-network@$digest_re ansible-devspaces-network:sha-$sha12$" "$STUB_STATE/log"
t grep -qE "image: image-registry.openshift-image-registry.svc:5000/stub-ns/ansible-devspaces-network:sha-$sha12@$digest_re" <<<"$out"
echo "   ... build arguments go on the BuildConfig, never on start-build, and each call is logged once"
t [ "$(args_of ansible-devspaces-network)" = "REQUIREMENTS=network" ]
t [ "$(calls "--build-arg")" -eq 0 ]
t [ "$(calls "oc start-build")" -eq 1 ]
t grep -q "^base:   $STUB_DEFAULT_BASE$" <<<"$out"

echo "2. the same commit again: no rebuild, the existing tag is reported, nothing moves"
out="$(bash scripts/build-in-cluster.sh network 2>&1)"; rc=$?
t [ "$rc" -eq 0 ]
t grep -q "already exists; a commit is built once" <<<"$out"
t [ "$(calls "oc start-build")" -eq 1 ]
t [ "$(calls "oc tag")" -eq 1 ]

echo "3. build full with DEVSPACES_BASE: the base reaches the image; the pull secret is set or cleared"
fresh; DEVSPACES_BASE="reg.example/ns/base:1@sha256:abc" bash scripts/build-in-cluster.sh full >/dev/null 2>&1; rc=$?
t [ "$rc" -eq 0 ]
t [ "$(args_of ansible-devspaces)" = "REQUIREMENTS=full DEVSPACES_BASE=reg.example/ns/base:1@sha256:abc" ]
t [ "$(cat "$STUB_STATE/label/ansible-devspaces:build")" = "reg.example/ns/base:1@sha256:abc" ]
t grep -q "oc set build-secret --pull --remove bc/ansible-devspaces$" "$STUB_STATE/log"
fresh; DEVSPACES_BASE="reg.example/ns/base:1@sha256:abc" DEVSPACES_BASE_PULL_SECRET=base-pull \
  bash scripts/build-in-cluster.sh full >/dev/null 2>&1; rc=$?
t [ "$rc" -eq 0 ]
t grep -q "oc set build-secret --pull bc/ansible-devspaces base-pull$" "$STUB_STATE/log"
echo "   ... with neither set, the community base, and any old pull secret cleared"
fresh; bash scripts/build-in-cluster.sh full >/dev/null 2>&1; rc=$?
t [ "$rc" -eq 0 ]
t [ "$(args_of ansible-devspaces)" = "REQUIREMENTS=full" ]
t grep -q "oc set build-secret --pull --remove" "$STUB_STATE/log"

echo "4. network build with an enterprise base and pull secret set: both ignored"
fresh; DEVSPACES_BASE="reg.example/ns/base:1" DEVSPACES_BASE_PULL_SECRET=base-pull \
  bash scripts/build-in-cluster.sh network >/dev/null 2>&1
t [ "$(args_of ansible-devspaces-network)" = "REQUIREMENTS=network" ]
tn grep -q "oc set build-secret" "$STUB_STATE/log"

echo "5. PIP_INDEX_URL reaches the BuildConfig for either variant"
fresh; PIP_INDEX_URL="https://pypi.example/simple" bash scripts/build-in-cluster.sh network >/dev/null 2>&1
t [ "$(args_of ansible-devspaces-network)" = "REQUIREMENTS=network PIP_INDEX_URL=https://pypi.example/simple" ]

echo "6. the image came out on a different base: no tag, and the script says why"
fresh; echo "some.other/base:1" > "$STUB_STATE/base-label"
out="$(DEVSPACES_BASE="reg.example/ns/base:1" bash scripts/build-in-cluster.sh full 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t grep -q "was built from some.other/base:1, not reg.example/ns/base:1" <<<"$out"
t [ "$(calls "oc tag")" -eq 0 ]

echo "7. modified devspaces/ file: refuses, and nothing is applied or built"
fresh; echo "# scratch" >> devspaces/requirements/network.txt
out="$(bash scripts/build-in-cluster.sh network 2>&1)"; rc=$?
git checkout -q -- devspaces/requirements/network.txt
t [ "$rc" -eq 1 ]
t grep -q "differs from commit" <<<"$out"
t [ "$(calls "oc apply")" -eq 0 ]
t [ "$(calls "oc start-build")" -eq 0 ]

echo "8. untracked devspaces/ file (uploaded too): refuses"
fresh; echo "scratch" > devspaces/requirements/untracked-scratch.txt
out="$(bash scripts/build-in-cluster.sh network 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t grep -q "untracked-scratch.txt" <<<"$out"
t [ "$(calls "oc start-build")" -eq 0 ]
echo "   ... BUILD_DIRTY=1 builds it as -dirty, and a second dirty build may overwrite that tag"
fresh; out="$(BUILD_DIRTY=1 bash scripts/build-in-cluster.sh network 2>&1)"; rc=$?
t [ "$rc" -eq 0 ]
t grep -qE "ansible-devspaces-network:sha-$sha12-dirty$" "$STUB_STATE/log"
t grep -q "This is a scratch build" <<<"$out"
BUILD_DIRTY=1 bash scripts/build-in-cluster.sh network >/dev/null 2>&1; rc=$?
t [ "$rc" -eq 0 ]
t [ "$(calls "oc start-build")" -eq 2 ]
rm -f devspaces/requirements/untracked-scratch.txt

echo "9. failed build: non-zero exit and no tag written"
fresh; touch "$STUB_STATE/fail-build"; bash scripts/build-in-cluster.sh network >/dev/null 2>&1; rc=$?
t [ "$rc" -ne 0 ]
t [ "$(calls "oc tag")" -eq 0 ]

echo "10. build reports success but writes no image: says so, no tag"
fresh; touch "$STUB_STATE/no-build-tag"; out="$(bash scripts/build-in-cluster.sh network 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t grep -q "has no image" <<<"$out"
t [ "$(calls "oc tag")" -eq 0 ]

echo "11. an istag lookup that is Forbidden stops the script; it is not read as absent"
fresh; touch "$STUB_STATE/forbidden"; bash scripts/build-in-cluster.sh network >/dev/null 2>&1; rc=$?
t [ "$rc" -ne 0 ]
t [ "$(calls "oc start-build")" -eq 0 ]
t [ "$(calls "oc tag")" -eq 0 ]

echo "12. promote: copies the digest to a version, refuses to move it, rejects bad input"
fresh; bash scripts/build-in-cluster.sh network >/dev/null 2>&1
shatag="sha-$sha12"
out="$(bash scripts/promote-image.sh ansible-devspaces-network "$shatag" v0.1.0 2>&1)"; rc=$?
t [ "$rc" -eq 0 ]
t grep -qE "oc tag ansible-devspaces-network@$digest_re ansible-devspaces-network:v0.1.0$" "$STUB_STATE/log"
t grep -q "digest:   sha256:d" <<<"$out"
out="$(bash scripts/promote-image.sh ansible-devspaces-network "$shatag" v0.1.0 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t grep -q "a version never moves" <<<"$out"
bash scripts/promote-image.sh ansible-devspaces-network "$shatag" 0.1.0 >/dev/null 2>&1; t [ $? -eq 2 ]
echo "   ... the moving build tag and dirty builds cannot be promoted"
out="$(bash scripts/promote-image.sh ansible-devspaces-network build v0.2.0 2>&1)"; rc=$?
t [ "$rc" -eq 2 ]
t grep -q "only a sha-<commit> tag" <<<"$out"
bash scripts/promote-image.sh ansible-devspaces-network "$shatag-dirty" v0.2.0 >/dev/null 2>&1; t [ $? -eq 2 ]
echo "   ... a missing sha- tag gets the tailored message, not a bare exit"
out="$(bash scripts/promote-image.sh ansible-devspaces-network sha-000000000000 v0.2.0 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t grep -q "not found in stub-ns; build it first" <<<"$out"
echo "   ... a Forbidden lookup stops promotion rather than writing over a version"
touch "$STUB_STATE/forbidden"
bash scripts/promote-image.sh ansible-devspaces-network "$shatag" v0.3.0 >/dev/null 2>&1; rc=$?
t [ "$rc" -ne 0 ]
t [ "$(calls "ansible-devspaces-network:v0.3.0")" -eq 1 ]
tn grep -q "oc tag .*:v0.3.0" "$STUB_STATE/log"

echo "13. prereq check: all yes passes, using --subresource for every subresource"
fresh; out="$(bash scripts/check-cluster-prereqs.sh 2>&1)"; rc=$?
t [ "$rc" -eq 0 ]
t grep -q "everything the MVP needs is in place" <<<"$out"
t grep -q "system:image-builders binds it" <<<"$out"
t grep -q "oc auth can-i create builds --subresource=docker$" "$STUB_STATE/log"
t grep -q "oc auth can-i create buildconfigs --subresource=instantiatebinary$" "$STUB_STATE/log"
t grep -q "oc auth can-i get builds --subresource=log$" "$STUB_STATE/log"
t grep -q "oc auth can-i patch buildconfigs$" "$STUB_STATE/log"
t grep -q "oc auth can-i update imagestreamtags$" "$STUB_STATE/log"

echo "14. prereq check: only the docker grant removed - exactly that one is MISSING"
fresh; mkdir -p "$STUB_STATE/can-i.d"; echo no > "$STUB_STATE/can-i.d/create_builds_docker"
out="$(bash scripts/check-cluster-prereqs.sh 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t [ "$(grep -c MISSING <<<"$out")" -eq 1 ]
t grep -q "MISSING  use the Docker build strategy" <<<"$out"
t grep -q "system:build-strategy-docker" <<<"$out"

echo "15. prereq check: all no names six permissions and exits 1"
fresh; echo no > "$STUB_STATE/can-i"; out="$(bash scripts/check-cluster-prereqs.sh 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t [ "$(grep -c MISSING <<<"$out")" -eq 6 ]
t grep -q "(denied: get create patch)" <<<"$out"
echo "$out" | grep -E "MISSING|ask for" | head -4 | sed 's/^/     /'

echo "16. prereq check: the builder account decides whether builds can push"
fresh; touch "$STUB_STATE/no-builder"; out="$(bash scripts/check-cluster-prereqs.sh 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t grep -q "no builder service account" <<<"$out"
fresh; echo "default deployer" > "$STUB_STATE/binding-subjects"; out="$(bash scripts/check-cluster-prereqs.sh 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t grep -q "does not bind the builder service account" <<<"$out"
fresh; : > "$STUB_STATE/binding-subjects"; out="$(bash scripts/check-cluster-prereqs.sh 2>&1)"; rc=$?
t [ "$rc" -eq 0 ]
t grep -q "not readable by you, which is normal" <<<"$out"

echo "17. prereq check: no ImageStreams to find the registry by is information, not MISSING"
fresh; touch "$STUB_STATE/no-registry-info"; out="$(bash scripts/check-cluster-prereqs.sh 2>&1)"; rc=$?
t [ "$rc" -eq 0 ]
t grep -q "normal before the first build" <<<"$out"

echo ""
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
