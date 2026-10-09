# Shared helpers for the capture-rule admission checks (sourced, not a check).
#
# On a disposable kind cluster with the zone installed (EVAL_KIND=1, EVAL_KIND_CONTEXT, see _lib.sh)
# each check creates its pod by server dry-run in an injected plane namespace and reads the API
# server's answer. Without a cluster, the check renders zone-policy with helm template, shows the
# Deny-bound policy that would answer, and fails only when the render cannot carry the rule at all;
# otherwise it exits 77 (the API server's answer was not observed).
. "$EVAL_ROOT/evals/mesh-identity-enrolment/_lib.sh"
CHART="$EVAL_ROOT/deployment/helm/zone-policy"
PLANE_LABEL=ztd.facis.io/plane
IMG=registry.k8s.io/e2e-test-images/agnhost:2.53

kind_available() {
  [ "${EVAL_KIND:-}" = 1 ] && [ -n "${EVAL_KIND_CONTEXT:-}" ] || return 1
  ( need_kind ) >/dev/null 2>&1
}

# cluster_setup: sets CTX, KUBECONFIG, NS (an injected plane namespace), POLICIES (zone-policy VAP names).
cluster_setup() {
  need_kind
  NS=$(kubectl --context "$CTX" get ns -l "$PLANE_LABEL,istio-injection=enabled" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -n "$NS" ] || { echo "UNVERIFIABLE: no namespace labelled $PLANE_LABEL and istio-injection=enabled on $CTX (zone not installed)"; exit 77; }
  POLICIES=$(kubectl --context "$CTX" get validatingadmissionpolicies -l app.kubernetes.io/name=zone-policy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  [ -n "$POLICIES" ] || { echo "UNVERIFIABLE: no ValidatingAdmissionPolicy of the zone-policy release on $CTX"; exit 77; }
  echo "cluster $CTX, plane namespace $NS, zone-policy policies: $(echo $POLICIES)"
}

# dry_run <name> <kubectl run args...> -> rc, out (server dry-run in $NS)
dry_run() {
  local name=$1; shift
  out=$(kubectl --context "$CTX" -n "$NS" run "$name" --image="$IMG" --restart=Never "$@" --dry-run=server -o json 2>&1); rc=$?
}

# expect_refused <extra-regex or empty>: the dry-run was refused naming a zone-policy policy.
expect_refused() {
  echo "exit $rc"; echo "$out" | head -n 20
  [ "$rc" -ne 0 ] || { echo "FAIL: expected the API server to refuse the pod, it was admitted"; exit 1; }
  local p named=
  for p in $POLICIES; do grep -q "ValidatingAdmissionPolicy '$p'" <<<"$out" && named=$p; done
  [ -n "$named" ] || { echo "FAIL: refusal does not name an admission policy of zone-policy ($(echo $POLICIES))"; exit 1; }
  if [ -n "${1:-}" ]; then
    grep -qiE "$1" <<<"$out" || { echo "FAIL: refusal names policy $named but not the capture rule (/$1/)"; exit 1; }
  fi
  echo "PASS: refused naming ValidatingAdmissionPolicy '$named'"; exit 0
}

# render_policy: helm template zone-policy with ci/values.yaml into $EVAL_TMP/zp.yaml (exit 77 if helm is missing).
render_policy() {
  command -v helm >/dev/null || { echo "UNVERIFIABLE: helm not installed and no kind cluster"; exit 77; }
  helm template zone-policy "$CHART" -f "$CHART/ci/values.yaml" >"$EVAL_TMP/zp.yaml" 2>"$EVAL_TMP/zp.err" \
    || { cat "$EVAL_TMP/zp.err"; echo "FAIL: helm template of zone-policy failed"; exit 1; }
}

# static_mentions <key> <where: annotations|labels>: the rendered, Deny-bound, plane-scoped policy
# has a validation (or a variable it uses) naming <key>. Prints the evidence, exits 1 on a defect, 77 otherwise.
static_mentions() {
  render_policy
  python3 - "$EVAL_TMP/zp.yaml" "$1" "$2" "$PLANE_LABEL" <<'PY'
import sys, yaml
f, key, where, plane = sys.argv[1:5]
docs = [d for d in yaml.safe_load_all(open(f)) if isinstance(d, dict)]
vaps = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "ValidatingAdmissionPolicy"}
binds = [d for d in docs if d.get("kind") == "ValidatingAdmissionPolicyBinding"]
hit = []
for b in binds:
    s = b.get("spec", {})
    p = vaps.get(s.get("policyName"))
    if not p or "Deny" not in (s.get("validationActions") or []):
        continue
    sel = ((s.get("matchResources") or {}).get("namespaceSelector") or {})
    if not any(e.get("key") == plane for e in sel.get("matchExpressions") or []) and plane not in (sel.get("matchLabels") or {}):
        continue
    rules = (p["spec"].get("matchConstraints") or {}).get("resourceRules") or []
    if not any("pods" in r.get("resources", []) and "CREATE" in r.get("operations", []) for r in rules):
        continue
    vars_ = {v["name"]: v["expression"] for v in p["spec"].get("variables") or []}
    for i, v in enumerate(p["spec"].get("validations") or []):
        text = v["expression"] + " " + " ".join(e for n, e in vars_.items() if "variables." + n in v["expression"])
        if key in text and (where == "annotations" and ("annotations" in text) or where == "labels" and "metadata.labels" in text):
            hit.append((p["metadata"]["name"], i, v.get("message", "").strip()))
if not hit:
    print(f"FAIL: no Deny-bound, plane-scoped ValidatingAdmissionPolicy validation on pod {where} names {key!r} in the zone-policy render")
    sys.exit(1)
for n, i, m in hit:
    print(f"render: policy {n!r}, validation {i} reads {key!r} from pod {where}; message: {m[:160]}...")
print("UNVERIFIABLE: the rendered policy carries the rule, but the API server's refusal needs a kind cluster with the zone installed (Docker unreachable or EVAL_KIND not set)")
sys.exit(77)
PY
  exit $?
}
