#!/usr/bin/env bash
# Provisions the live zone for the L2 checks on the local kind cluster (context kind-ztd, Cilium
# only). Records what each lifecycle operation did into a state directory the checks read:
#   1. install #1 from the empty cluster       install1.{rc,log}, m1/<release>.yaml, pods1-<ns>.json
#   2. install #2 (idempotency)                 install2.{rc,log}, m2/<release>.yaml
#   3. uninstall in reverse order               uninstall.{rc,log}, crds-after-uninstall.txt
#   4. install with a 1 s step timeout          failstep.{rc,log}, helm-after-failstep.txt (then cleaned)
#   5. install #3 for the probes, stand-in pods install3.{rc,log}
#   6. zone-policy upgrade whose declared registration is never reconciled, then rollback
#                                               missing.{rc,log}, missing-status.json
# Never fails the run on a product failure: it records it, and the checks judge.
set -u
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
. "$REPO/evals/lib.sh"
emit() { printf '%s\n' "$1" >> "$EVAL_ENV_FILE"; }
skip() { emit ZTD_LIVE=0; emit "ZTD_LIVE_REASON=$1"; echo "setup: live checks disabled: $1"; exit 0; }

[ "${ZTD_EVAL_LIVE:-1}" = 0 ] && skip "ZTD_EVAL_LIVE=0"
timeout 20 kubectl --context "$CTX" get nodes >/dev/null 2>&1 || skip "context $CTX unreachable"
others=$(h list -A -q 2>/dev/null | grep -vx cilium)
[ -n "$others" ] && skip "cluster not empty: helm releases $(echo $others)"
for ns in "$SPIRE_NS" "$ISTIO_NS" "$DATA" "$MGMT"; do
  k get ns "$ns" >/dev/null 2>&1 && skip "cluster not empty: namespace $ns exists"
done

S=$(mktemp -d "${TMPDIR:-/tmp}/ztd-eval.XXXXXX")
emit "ZTD_STATE=$S"
export KUBE_CONTEXT=$CTX
unset ZONE_VALUES STEP_TIMEOUT
RELEASES="ztd:ztd-system spire-crds:$SPIRE_NS spire:$SPIRE_NS istio-base:$ISTIO_NS istiod:$ISTIO_NS istio-cni:$ISTIO_NS zone-policy:$ISTIO_NS"
log() { echo "setup: $(date -u +%H:%M:%S) $*"; }
save_manifests() { mkdir -p "$S/$1"; for r in $RELEASES; do h -n "${r#*:}" get manifest "${r%%:*}" > "$S/$1/${r%%:*}.yaml" 2>&1; done; }
save_pods() { for ns in "$SPIRE_NS" "$ISTIO_NS" "$DATA" "$MGMT"; do k -n "$ns" get pods -o json > "$S/$1-$ns.json" 2>&1; done; }
wait_gone() { # wait_gone <seconds>: until no zone namespace is left
  local end=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    local left=0
    for ns in "$SPIRE_NS" "$ISTIO_NS" "$DATA" "$MGMT"; do k get ns "$ns" >/dev/null 2>&1 && left=1; done
    [ $left -eq 0 ] && return 0; sleep 3
  done; return 1
}

k get crd -o name > "$S/crds-before.txt" 2>&1
touch "$S/touched"

log "install #1"
"$INSTALL" install > "$S/install1.log" 2>&1; echo $? > "$S/install1.rc"
save_manifests m1; save_pods pods1; h list -A > "$S/helm1.txt" 2>&1

log "install #2"
"$INSTALL" install > "$S/install2.log" 2>&1; echo $? > "$S/install2.rc"
save_manifests m2; save_pods pods2

log "uninstall"
"$INSTALL" uninstall > "$S/uninstall.log" 2>&1; echo $? > "$S/uninstall.rc"
wait_gone 300; echo $? > "$S/uninstall-nsgone.rc"
k get crd -o name > "$S/crds-after-uninstall.txt" 2>&1
h list -A > "$S/helm-after-uninstall.txt" 2>&1

log "install with a 1 s step timeout"
STEP_TIMEOUT=1s "$INSTALL" install > "$S/failstep.log" 2>&1; echo $? > "$S/failstep.rc"
h list -A > "$S/helm-after-failstep.txt" 2>&1
"$INSTALL" uninstall > "$S/failstep-cleanup.log" 2>&1
wait_gone 300 || log "warning: namespaces left after the fail-step cleanup"

log "install #3"
"$INSTALL" install > "$S/install3.log" 2>&1; echo $? > "$S/install3.rc"
if [ "$(cat "$S/install3.rc")" != 0 ]; then
  emit ZTD_LIVE=0; emit "ZTD_LIVE_REASON=install #3 failed (see $S/install3.log)"; log "install #3 failed"; exit 0
fi
h -n "$ISTIO_NS" status zone-policy -o json > "$S/zp-status3.json" 2>&1
h -n "$ISTIO_NS" get hooks zone-policy > "$S/zp-hooks3.yaml" 2>&1
k -n "$ISTIO_NS" get jobs -o json > "$S/jobs3.json" 2>&1

log "stand-in pods"
k apply -f "$REPO/evals/fixtures/stand-ins.yaml" > "$S/standins.log" 2>&1
for p in "$DATA/ev-client" "$DATA/ev-peer" "$DATA/ev-crossplane" "$DATA/ev-probe" "$DATA/ev-nosidecar" "$MGMT/ev-verif"; do
  k -n "${p%/*}" wait --for=condition=Ready "pod/${p#*/}" --timeout=240s >> "$S/standins.log" 2>&1
done
# the unlabelled meshed pod is expected never to become Ready; wait for its proxy to run
for _ in $(seq 1 60); do
  st=$(k -n "$DATA" get pod ev-unlabelled -o jsonpath='{.status.initContainerStatuses[?(@.name=="istio-proxy")].state.running.startedAt}' 2>/dev/null)
  [ -n "$st" ] && break; sleep 3
done
sleep 20   # let the unlabelled proxy ask for its certificate, and the stats settle
k get pods -A -l ztd-eval=stand-in -o wide >> "$S/standins.log" 2>&1

log "zone-policy upgrade with a declared registration that is never reconciled"
h -n "$ISTIO_NS" get values zone-policy -o yaml > "$S/zp-values.yaml" 2>&1
rev=$(h -n "$ISTIO_NS" status zone-policy -o json | jq -r .version)
h -n "$ISTIO_NS" upgrade zone-policy "$REPO/deployment/helm/zone-policy" -f "$S/zp-values.yaml" \
  --set registration.name=ev-unreconciled --set spire.className=ev-no-such-class \
  --set checks.timeoutSeconds=30 --wait --wait-for-jobs --timeout 5m > "$S/missing.log" 2>&1
echo $? > "$S/missing.rc"
h -n "$ISTIO_NS" status zone-policy -o json > "$S/missing-status.json" 2>&1
k -n "$ISTIO_NS" get jobs -o wide > "$S/missing-jobs.txt" 2>&1
for j in $(k -n "$ISTIO_NS" get jobs -o name 2>/dev/null); do echo "== $j"; k -n "$ISTIO_NS" logs "$j" --tail=20 2>&1; done > "$S/missing-joblogs.txt"
h -n "$ISTIO_NS" rollback zone-policy "$rev" --wait --wait-for-jobs --timeout 6m > "$S/missing-rollback.log" 2>&1
echo $? > "$S/missing-rollback.rc"
# wait for the labelled pod's entry and SVID to come back
for _ in $(seq 1 60); do
  fetch_svid "$DATA" ev-client 2>/dev/null | grep -q "ns/$DATA/sa/ev-client" && break; sleep 5
done
emit ZTD_LIVE=1
log "done"
exit 0
