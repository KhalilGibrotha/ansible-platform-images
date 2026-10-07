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
fresh() { STUB_STATE="$(mktemp -d)"; export STUB_STATE; echo yes > "$STUB_STATE/can-i"; }
cd "$repo" || exit 1
git diff --quiet -- devspaces || { echo "devspaces/ is dirty before the tests; aborting"; exit 1; }

echo "1. build network, clean tree: tags sha- by digest and prints the pin line"
fresh; out="$(bash scripts/build-in-cluster.sh network 2>&1)"; rc=$?
echo "$out" | grep -E "^built:|^  image:" | sed 's/^/     /'
t [ "$rc" -eq 0 ]
t grep -q "oc start-build bc/ansible-devspaces-network --from-dir=devspaces --follow --wait" "$STUB_STATE/log"
t grep -qE "oc tag ansible-devspaces-network@sha256:d{64} ansible-devspaces-network:sha-[0-9a-f]{12}$" "$STUB_STATE/log"
t grep -qE "image: image-registry.openshift-image-registry.svc:5000/stub-ns/ansible-devspaces-network:sha-[0-9a-f]{12}@sha256:d{64}" <<<"$out"

echo "2. build full with DEVSPACES_BASE set: passes the base as a build arg"
fresh; DEVSPACES_BASE="reg.example/ns/base:1@sha256:abc" bash scripts/build-in-cluster.sh full >/dev/null 2>&1; rc=$?
t [ "$rc" -eq 0 ]
t grep -q -- "--build-arg DEVSPACES_BASE=reg.example/ns/base:1@sha256:abc" "$STUB_STATE/log"

echo "3. build network with DEVSPACES_BASE set: ignored (public image never takes it)"
fresh; DEVSPACES_BASE="reg.example/ns/base:1" bash scripts/build-in-cluster.sh network >/dev/null 2>&1
tn grep -q -- "--build-arg DEVSPACES_BASE" "$STUB_STATE/log"

echo "4. dirty devspaces/ tree: refuses, and nothing is applied or built"
fresh; echo "# scratch" >> devspaces/requirements/network.txt
out="$(bash scripts/build-in-cluster.sh network 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t grep -q "uncommitted changes" <<<"$out"
tn grep -q "start-build" "$STUB_STATE/log"
echo "   ... and BUILD_DIRTY=1 builds with a -dirty suffix"
fresh; out="$(BUILD_DIRTY=1 bash scripts/build-in-cluster.sh network 2>&1)"; rc=$?
t [ "$rc" -eq 0 ]
t grep -qE "ansible-devspaces-network:sha-[0-9a-f]{12}-dirty$" "$STUB_STATE/log"
git checkout -q -- devspaces/requirements/network.txt

echo "5. failed build: non-zero exit and no tag written"
fresh; touch "$STUB_STATE/fail-build"; bash scripts/build-in-cluster.sh network >/dev/null 2>&1; rc=$?
t [ "$rc" -ne 0 ]
tn grep -q "oc tag" "$STUB_STATE/log"

echo "6. promote: copies the digest to a version, refuses to move it, rejects bad input"
fresh; bash scripts/build-in-cluster.sh network >/dev/null 2>&1
shatag="$(grep -oE "sha-[0-9a-f]{12}$" "$STUB_STATE/log" | head -1)"
out="$(bash scripts/promote-image.sh ansible-devspaces-network "$shatag" v0.1.0 2>&1)"; rc=$?
t [ "$rc" -eq 0 ]
t grep -qE "oc tag ansible-devspaces-network@sha256:d{64} ansible-devspaces-network:v0.1.0$" "$STUB_STATE/log"
t grep -q "digest:   sha256:d" <<<"$out"
out="$(bash scripts/promote-image.sh ansible-devspaces-network "$shatag" v0.1.0 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t grep -q "a version never moves" <<<"$out"
bash scripts/promote-image.sh ansible-devspaces-network "$shatag" 0.1.0 >/dev/null 2>&1; t [ $? -eq 2 ]
bash scripts/promote-image.sh ansible-devspaces-network sha-abc-dirty v0.2.0 >/dev/null 2>&1; t [ $? -eq 1 ]
bash scripts/promote-image.sh ansible-devspaces-network sha-nosuch v0.2.0 >/dev/null 2>&1; t [ $? -eq 1 ]

echo "7. prereq check: all yes passes; all no names every item and exits 1"
fresh; out="$(bash scripts/check-cluster-prereqs.sh 2>&1)"; rc=$?
t [ "$rc" -eq 0 ]
t grep -q "everything the MVP needs is in place" <<<"$out"
fresh; echo no > "$STUB_STATE/can-i"; out="$(bash scripts/check-cluster-prereqs.sh 2>&1)"; rc=$?
t [ "$rc" -eq 1 ]
t [ "$(grep -c MISSING <<<"$out")" -eq 7 ]
t grep -q "system:build-strategy-docker" <<<"$out"
echo "$out" | grep -E "MISSING|ask for" | head -4 | sed 's/^/     /'

echo ""
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
