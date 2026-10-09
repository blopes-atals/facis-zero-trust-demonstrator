#!/usr/bin/env bash
# Uninstall the zone only if setup installed it (and EVAL_KEEP_ZONE is not 1).
root=$(cd "$(dirname "$0")/.." && pwd)
marker="$root/evals/.zone-installed-by-setup"
[ -f "$marker" ] || exit 0
[ "${EVAL_KEEP_ZONE:-}" = 1 ] && { echo "teardown: EVAL_KEEP_ZONE=1, zone left installed"; exit 0; }
echo "teardown: uninstalling the zone setup installed on $EVAL_KIND_CONTEXT"
( cd "$root" && env -u CI KUBE_CONTEXT="$EVAL_KIND_CONTEXT" bash scripts/install-zone/install.sh uninstall ) >"$root/evals/.teardown.log" 2>&1
rm -f "$marker"
exit 0
