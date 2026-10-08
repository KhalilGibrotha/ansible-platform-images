#!/usr/bin/env bash
# Exercise the in-cluster scripts against the stub oc: happy paths and
# every refusal they claim to make. Runs anywhere with bash and git; no
# cluster, no oc. What it cannot check is the real oc's behaviour, which
# the flags in the scripts were verified against separately.
#
#   bash tests/test-in-cluster-scripts.sh
set -u
repo="$(git rev-parse --show-toplevel)"
bin="$(mktemp -d)"; cp "$repo/tests/stub-oc.sh" "$bin/oc"; chmod +x "$bin/oc"
export PATH="$bin:$PATH"
export DEVWORKSPACE_NAMESPACE=stub-ns
pass=0; fail=0
t() { if "$@"; then pass=$((pass+1)); echo "  PASS"; else fail=$((fail+1)); echo "  FAIL: $*"; fi; }
tn() { if ! "$@"; then pass=$((pass+1)); echo "  PASS"; else fail=$((fail+1)); echo "  FAIL (expected no match): $*"; fi; }
fresh() { STUB_STATE="$(mktemp -d)"; export STUB_STATE; echo yes > "$STUB_STATE/can-i"; touch "$STUB_STATE/log"; }
calls() { grep -c "$1" "$STUB_STATE/log"; }
cd "$repo" || exit 1
if [ -n "$(git status --porcelain --untracked-files=all --ignored=matching -- devspaces)" ]; then
  echo "devspaces/ is not clean before the tests; aborting"; exit 1
fi
digest_re="sha256:d{64}"

echo "1. build network, clean tree: tags sha- by digest and prints the pin line"
fresh; out="$(bash scripts/build-in-cluster.sh network 2>&1)"; rc=$?
echo "$out" | grep -E "^built:|^  image:" | sed 's/^/     /'
t [ "$rc" -eq 0 ]
t grep -q "oc start-build bc/ansible-devspaces-network --from-dir=devspaces --follow --wait" "$STUB_STATE/log"
t grep -qE "oc tag ansible-devspaces-network@$digest_re ansible-devspaces-network:sha-[0-9a-f]{12}$" "$STUB_STATE/log"
t grep -qE "image: image-registry.openshift-image-registry.svc:5000/stub-ns/ansible-devspaces-network:sha-[0-9a-f]{12}@$digest_re" <<<"$out"
echo "   ... each oc call is logged once"
t [ "$(calls "oc start-build")" -eq 1 ]

echo "2. the same commit again: no rebuild, the existing tag is reported, nothing moves"
out="$(bash scripts/build-in-cluster.sh network 2>&1)"; rc=$?
t [ "$rc" -eq 0 ]
t grep -q "already exists; a commit is built once" <<<"$out"
t [ "$(calls "oc start-build")" -eq 1 ]
t [ "$(calls "oc tag")" -eq 1 ]

echo "3. build full with DEVSPACES_BASE: passes the base; with a pull secret, sets it on the BuildConfig"
fresh; DEVSPACES_BASE="reg.example/ns/base:1@sha256:abc" bash scripts/build-in-cluster.sh full >/dev/null 2>&1; rc=$?
t [ "$rc" -eq 0 ]
t grep -q -- "--build-arg DEVSPACES_BASE=reg.example/ns/base:1@sha256:abc" "$STUB_STATE/log"
tn grep -q "oc set build-secret" "$STUB_STATE/log"
fresh; DEVSPACES_BASE="reg.example/ns/base:1@sha256:abc" DEVSPACES_BASE_PULL_SECRET=base-pull \
  bash scripts/build-in-cluster.sh full >/dev/null 2>&1; rc=$?
t [ "$rc" -eq 0 ]
t grep -q "oc set build-secret --pull bc/ansible-devspaces base-pull" "$STUB_STATE/log"

echo "4. build network with DEVSPACES_BASE and a pull secret set: both ignored (public image never takes them)"
fresh; DEVSPACES_BASE="reg.example/ns/base:1" DEVSPACES_BASE_PULL_SECRET=base-pull \
  bash scripts/build-in-cluster.sh network >/dev/null 2>&1
tn grep -q -- "--build-arg DEVSPACES_BASE" "$STUB_STATE/log"
tn grep -q "oc set build-secret" "$STUB_STATE/log"

echo "5. modified devspaces/ file: refuses, and nothing is applied or built"
fresh; echo "# scratch" >> devspaces/requirements/network.txt
out="$(bash scripts/build-in-cluster.sh network 2>&1)"; rc=$?
git checkout -q -- devspaces/requirements/network.txt
t [ "$rc" -eq 1 ]
t grep -q "differs from commit" <<<"$out"
t [ "$(calls "oc apply")" -eq 0 ]
t [ "$(calls "oc start-build")" -eq 0 ]

echo "6. untracked devspaces/ file (uploaded too): refuses"
fresh; echo "scratch" > devspaces/requirements/untracked-scratch.txt
out="$(bash scripts/build-in-cluster.sh network 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t grep -q "untracked-scratch.txt" <<<"$out"
t [ "$(calls "oc start-build")" -eq 0 ]
echo "   ... BUILD_DIRTY=1 builds it as -dirty, and a second dirty build may overwrite that tag"
fresh; out="$(BUILD_DIRTY=1 bash scripts/build-in-cluster.sh network 2>&1)"; rc=$?
t [ "$rc" -eq 0 ]
t grep -qE "ansible-devspaces-network:sha-[0-9a-f]{12}-dirty$" "$STUB_STATE/log"
t grep -q "This is a scratch build" <<<"$out"
BUILD_DIRTY=1 bash scripts/build-in-cluster.sh network >/dev/null 2>&1; rc=$?
t [ "$rc" -eq 0 ]
t [ "$(calls "oc start-build")" -eq 2 ]
rm -f devspaces/requirements/untracked-scratch.txt

echo "7. failed build: non-zero exit and no tag written"
fresh; touch "$STUB_STATE/fail-build"; bash scripts/build-in-cluster.sh network >/dev/null 2>&1; rc=$?
t [ "$rc" -ne 0 ]
t [ "$(calls "oc tag")" -eq 0 ]

echo "8. build reports success but writes no image: says so, no tag"
fresh; touch "$STUB_STATE/no-build-tag"; out="$(bash scripts/build-in-cluster.sh network 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t grep -q "has no image" <<<"$out"
t [ "$(calls "oc tag")" -eq 0 ]

echo "9. promote: copies the digest to a version, refuses to move it, rejects bad input"
fresh; bash scripts/build-in-cluster.sh network >/dev/null 2>&1
shatag="$(grep -oE "sha-[0-9a-f]{12}$" "$STUB_STATE/log" | head -1)"
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

echo "10. prereq check: all yes passes"
fresh; out="$(bash scripts/check-cluster-prereqs.sh 2>&1)"; rc=$?
t [ "$rc" -eq 0 ]
t grep -q "everything the MVP needs is in place" <<<"$out"
t grep -q "system:image-builders binds it" <<<"$out"
for r in buildconfigs buildconfigs/instantiatebinary builds/log imagestreams imagestreamtags builds/docker; do
  t grep -q "oc auth can-i [a-z]* $r$" "$STUB_STATE/log"
done
t grep -q "oc auth can-i patch buildconfigs$" "$STUB_STATE/log"

echo "11. prereq check: all no names six permissions, the docker grant among them, and exits 1"
fresh; echo no > "$STUB_STATE/can-i"; out="$(bash scripts/check-cluster-prereqs.sh 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t [ "$(grep -c MISSING <<<"$out")" -eq 6 ]
t grep -q "system:build-strategy-docker" <<<"$out"
t grep -q "(denied: get create patch)" <<<"$out"
echo "$out" | grep -E "MISSING|ask for" | head -4 | sed 's/^/     /'

echo "12. prereq check: the builder account decides whether builds can push"
fresh; touch "$STUB_STATE/no-builder"; out="$(bash scripts/check-cluster-prereqs.sh 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t grep -q "no builder service account" <<<"$out"
fresh; echo "default deployer" > "$STUB_STATE/binding-subjects"; out="$(bash scripts/check-cluster-prereqs.sh 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t grep -q "does not bind the builder service account" <<<"$out"
fresh; : > "$STUB_STATE/binding-subjects"; out="$(bash scripts/check-cluster-prereqs.sh 2>&1)"; rc=$?
t [ "$rc" -eq 0 ]
t grep -q "not readable by you, which is normal" <<<"$out"

echo ""
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
