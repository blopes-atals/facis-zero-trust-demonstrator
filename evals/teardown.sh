#!/usr/bin/env bash
# Undoes evals/setup.sh: removes the stand-in pods and uninstalls the zone, leaving the kind cluster
# as setup found it (Cilium only). Does nothing when setup did not touch the cluster.
set -u
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
. "$REPO/evals/lib.sh"
S=$(sed -n 's/^ZTD_STATE=//p' "${EVAL_ENV_FILE:-/dev/null}" 2>/dev/null | tail -1)
[ -n "$S" ] && [ -e "$S/touched" ] || exit 0
[ "${ZTD_EVAL_KEEP:-0}" = 1 ] && { echo "teardown: ZTD_EVAL_KEEP=1, zone left installed, state in $S"; exit 0; }
export KUBE_CONTEXT=$CTX
k delete -f "$REPO/evals/fixtures/stand-ins.yaml" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1
"$INSTALL" uninstall
rc=$?
rm -rf "$S"
exit $rc
