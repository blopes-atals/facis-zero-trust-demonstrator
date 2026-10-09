#!/usr/bin/env bash
# Provision the zone on the disposable kind cluster named by EVAL_KIND_CONTEXT (opt-in: EVAL_KIND=1).
# Without the opt-in it does nothing; the cluster checks then report UNVERIFIABLE.
root=$(cd "$(dirname "$0")/.." && pwd)
marker="$root/evals/.zone-installed-by-setup"
[ "${EVAL_KIND:-}" = 1 ] && [ -n "${EVAL_KIND_CONTEXT:-}" ] || { echo "setup: EVAL_KIND not set, no cluster provisioning"; exit 0; }
case $EVAL_KIND_CONTEXT in kind-*) ;; *) echo "setup: refusing non-kind context $EVAL_KIND_CONTEXT"; exit 0;; esac
kubectl --context "$EVAL_KIND_CONTEXT" get nodes >/dev/null 2>&1 || { echo "setup: $EVAL_KIND_CONTEXT unreachable"; exit 0; }
if helm --kube-context "$EVAL_KIND_CONTEXT" status zone-policy -n istio-system >/dev/null 2>&1; then
  echo "setup: zone already installed on $EVAL_KIND_CONTEXT"; exit 0; fi
echo "setup: installing the zone on $EVAL_KIND_CONTEXT"
log="$root/evals/.setup-install.log"
if ( cd "$root" && env -u CI KUBE_CONTEXT="$EVAL_KIND_CONTEXT" bash scripts/install-zone/install.sh install ) >"$log" 2>&1; then
  touch "$marker"; tail -1 "$log"
else
  touch "$marker"; tail -20 "$log"; echo "setup: zone install failed; cluster checks will report what they see"
fi
exit 0
