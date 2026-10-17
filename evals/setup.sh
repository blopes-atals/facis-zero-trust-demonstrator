#!/usr/bin/env bash
# Provision kind-ztd (never a participant cluster) for the L2 checks, from an empty cluster:
#   1. uninstall the zone, if any (clean slate);
#   2. install the kind zone twice with scripts/install-zone/install.sh, recording exit codes, logs
#      and a hash of every release's manifest after each run;
#   3. run scripts/verify-mesh-identity/verify.sh (it uninstalls the zone, installs it twice and
#      proves the mesh identity; evidence goes to a directory outside the repository);
#   4. install the zone once more and leave it, for the checks that read or perturb the live store.
# Failures are recorded, not fatal: the checks then FAIL with the log as evidence. Slow (about 20
# minutes): the L2 checks need a real mesh.
set -u
[ -n "${EVAL_ENV_FILE:-}" ] || exit 0
export KUBE_CONTEXT=kind-ztd
kubectl --context kind-ztd get nodes >/dev/null 2>&1 || { echo "setup: kind-ztd not reachable; L2 checks will be UNVERIFIABLE"; exit 0; }
W=$(mktemp -d "${TMPDIR:-/tmp}/ztd-eval-setup.XXXXXX")
export INSTALL_ZONE_CACHE=$W/cache; mkdir -p "$INSTALL_ZONE_CACHE"
[ -d "$HOME/.cache/ztd-install-zone" ] && cp -rs "$HOME/.cache/ztd-install-zone"/. "$INSTALL_ZONE_CACHE"/ 2>/dev/null
INSTALL=$EVAL_ROOT/scripts/install-zone/install.sh
echo "SETUP_DIR=$W" >> "$EVAL_ENV_FILE"

"$INSTALL" uninstall >"$W/uninstall0.log" 2>&1
kubectl --context kind-ztd delete ns ztd-system --ignore-not-found --wait=true >/dev/null 2>&1

snap() { for r in ztd:ztd-system spire-crds:spire-system spire:spire-system istio-base:istio-system istiod:istio-system istio-cni:istio-system zone-policy:istio-system ztd-openbao:ztd-mgmt; do
  helm --kube-context kind-ztd get manifest "${r%%:*}" -n "${r##*:}" 2>/dev/null | sha256sum | cut -c1-16 | sed "s/^/${r%%:*} /"; done; }
t0=$(date +%s)
"$INSTALL" install >"$W/install1.log" 2>&1; echo $? >"$W/install1.rc"
t1=$(date +%s)
snap >"$W/manifests1.txt"
"$INSTALL" install >"$W/install2.log" 2>&1; echo $? >"$W/install2.rc"
snap >"$W/manifests2.txt"
echo "setup: first install $((t1-t0))s rc=$(cat "$W/install1.rc"), second rc=$(cat "$W/install2.rc")"

mkdir -p "$W/evidence"
ZTD_EVIDENCE_DIR=$W/evidence "$EVAL_ROOT/scripts/verify-mesh-identity/verify.sh" >"$W/verify.log" 2>&1; echo $? >"$W/verify.rc"
echo "setup: verify-mesh-identity rc=$(cat "$W/verify.rc")"

"$INSTALL" install >"$W/install3.log" 2>&1; echo "setup: final install rc=$?"
