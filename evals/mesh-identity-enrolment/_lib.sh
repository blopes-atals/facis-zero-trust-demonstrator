# Shared helpers for the install-zone checks (sourced, not a check).
INSTALLER="$EVAL_ROOT/scripts/install-zone/install.sh"
KIND_ZONE="$EVAL_ROOT/deployment/helm/ztd/ci/values.yaml"
SEVEN="ztd spire-crds spire istio-base istiod istio-cni zone-policy"

# Shims for helm and kubectl that record every call and do nothing (only `helm version` is real),
# so a check can prove nothing was rendered, installed or contacted.
make_shims() {
  mkdir -p "$EVAL_TMP/bin"
  : >"$EVAL_TMP/calls.log"
  local real_helm; real_helm=$(command -v helm || true)
  cat >"$EVAL_TMP/bin/helm" <<SH
#!/usr/bin/env bash
echo "helm \$*" >>"$EVAL_TMP/calls.log"
if [ "\${1:-}" = version ] && [ -n "$real_helm" ]; then exec "$real_helm" "\$@"; fi
exit 1
SH
  cat >"$EVAL_TMP/bin/kubectl" <<SH
#!/usr/bin/env bash
echo "kubectl \$*" >>"$EVAL_TMP/calls.log"
exit 1
SH
  chmod +x "$EVAL_TMP/bin/helm" "$EVAL_TMP/bin/kubectl"
  : >"$EVAL_TMP/kubeconfig"
}

# derive_zone <out> <python expression on dict z>: a copy of the kind zone file with one change.
derive_zone() {
  python3 - "$KIND_ZONE" "$1" "$2" <<'PY'
import sys, yaml
src, out, expr = sys.argv[1:4]
z = yaml.safe_load(open(src)) or {}
z.setdefault("mesh", {})
exec(expr)
yaml.safe_dump(z, open(out, "w"), sort_keys=False)
PY
}

# Run the installer with the shims, an empty render dir and an empty chart cache.
run_shimmed() { # run_shimmed <zone file> <args...>  -> sets rc, out, err
  local zone=$1; shift
  rm -rf "$EVAL_TMP/render" "$EVAL_TMP/cache"; mkdir -p "$EVAL_TMP/render" "$EVAL_TMP/cache"
  : >"$EVAL_TMP/calls.log"
  ( cd "$EVAL_ROOT" && env -u CI PATH="$EVAL_TMP/bin:$PATH" KUBECONFIG="$EVAL_TMP/kubeconfig" \
      KUBE_CONTEXT=eval-no-such-context ZONE_VALUES="$zone" RENDER_DIR="$EVAL_TMP/render" \
      INSTALL_ZONE_CACHE="$EVAL_TMP/cache" timeout 60 bash "$INSTALLER" "$@" \
      >"$EVAL_TMP/out" 2>"$EVAL_TMP/err" </dev/null )
  rc=$?
  out=$(cat "$EVAL_TMP/out"); err=$(cat "$EVAL_TMP/err")
}

# A writable copy of the operator's chart cache, or an empty cache (the installer then fetches).
cache_copy() {
  mkdir -p "$EVAL_TMP/cache"
  if [ -d "$HOME/.cache/ztd-install-zone" ]; then cp -r "$HOME/.cache/ztd-install-zone/." "$EVAL_TMP/cache/"; fi
}

# Cluster scenarios mutate a kind cluster: they run only when the operator opts in with
# EVAL_KIND=1 and names the disposable cluster's context in EVAL_KIND_CONTEXT (no default: the
# installer's own default, kind-ztd, may hold other work). Every helm/kubectl call of the check and
# of the installer then goes through a kubeconfig that holds only that context.
need_kind() {
  if [ "${EVAL_KIND:-}" != 1 ]; then
    echo "UNVERIFIABLE: needs a disposable kind cluster with Cilium chained (scripts/dev/kind-cilium-up.sh), EVAL_KIND=1 and EVAL_KIND_CONTEXT=<its context>; not opted in"; exit 77; fi
  [ -n "${EVAL_KIND_CONTEXT:-}" ] || { echo "UNVERIFIABLE: EVAL_KIND=1 but EVAL_KIND_CONTEXT is not set; refusing to guess a context"; exit 77; }
  command -v kubectl >/dev/null && command -v helm >/dev/null || { echo "UNVERIFIABLE: kubectl or helm missing"; exit 77; }
  CTX=$EVAL_KIND_CONTEXT
  kubectl config view --minify --flatten --context "$CTX" >"$EVAL_TMP/kind.kubeconfig" 2>/dev/null \
    || { echo "UNVERIFIABLE: context $CTX not found in the kubeconfig"; exit 77; }
  export KUBECONFIG="$EVAL_TMP/kind.kubeconfig"
  kubectl --context "$CTX" get nodes >/dev/null 2>&1 || { echo "UNVERIFIABLE: kind cluster $CTX is not reachable"; exit 77; }
  kubectl --context "$CTX" -n kube-system get ds cilium >/dev/null 2>&1 \
    || { echo "UNVERIFIABLE: no Cilium DaemonSet in kube-system of $CTX (the scenario needs Cilium chained)"; exit 77; }
}
# ensure_empty: bring the cluster to "no release of the zone installed" with the installer's uninstall.
ensure_empty() {
  [ -z "$(releases_installed)" ] && return 0
  echo "precondition: releases present ($(releases_installed | tr '\n' ' ')); uninstalling them first"
  install_zone uninstall
  [ "$rc" -eq 0 ] && [ -z "$(releases_installed)" ] \
    || { tail -n 20 "$EVAL_TMP/inst.out" "$EVAL_TMP/inst.err"; echo "UNVERIFIABLE: could not empty the cluster (uninstall exit $rc)"; exit 77; }
}
install_zone() { # install_zone <cmd> [env...] -> rc, output in $EVAL_TMP/inst.{out,err}
  local cmd=$1; shift
  ( cd "$EVAL_ROOT" && env -u CI KUBE_CONTEXT="$CTX" "$@" bash "$INSTALLER" "$cmd" \
      >"$EVAL_TMP/inst.out" 2>"$EVAL_TMP/inst.err" </dev/null ); rc=$?
}
releases_installed() { helm --kube-context "$CTX" list -A -q 2>/dev/null | grep -xE "$(tr ' ' '|' <<<"$SEVEN")"; }
not_ready_pods() { # pods (not Succeeded) in spire-system, istio-system and the plane namespaces that are not Ready
  kubectl --context "$CTX" get pods -A -o json | python3 -c '
import json, sys
skip = {"kube-system", "local-path-storage", "kube-public", "kube-node-lease", "cilium-secrets"}
for p in json.load(sys.stdin)["items"]:
    ns = p["metadata"]["namespace"]
    if ns in skip or p["status"].get("phase") == "Succeeded": continue
    ready = any(c["type"] == "Ready" and c["status"] == "True" for c in p["status"].get("conditions", []))
    if not ready: print(ns + "/" + p["metadata"]["name"])
'
}
