# Sourced by the checks of this capability. Pure helpers; no side effects.
ADR_DIR="$EVAL_ROOT/docs/adr"
ADR_0001="$ADR_DIR/0001-service-mesh-mode-istio-ambient-with-cilium.md"
fail() { echo "FAIL: $*"; exit 1; }
unverifiable() { echo "UNVERIFIABLE: $*"; exit 77; }
# The superseding record is the one ADR-0001's status line links to; print its path.
superseding_record() {
  local line target
  line=$(grep -iE 'status' "$ADR_0001" | grep -iE 'superseded by' | head -1) || true
  [ -n "$line" ] || { echo ""; return 1; }
  target=$(grep -oE '\]\(([^)]*[0-9]{4}-[^)]*\.md)[^)]*\)' <<<"$line" | head -1 | sed -E 's/^\]\(//; s/[#)].*$//')
  [ -n "$target" ] || { echo ""; return 1; }
  if [ -f "$ADR_DIR/$target" ]; then echo "$ADR_DIR/$target"; else echo "$target"; return 1; fi
}
mkdocs_cmd() {
  if command -v mkdocs >/dev/null; then echo mkdocs; elif command -v uvx >/dev/null; then echo "uvx mkdocs"; else return 1; fi
}
# render_chart <extra helm args...> -> prints the rendered manifests of deployment/helm/ztd with ci/values.yaml
render_chart() { helm template ztd "$EVAL_ROOT/deployment/helm/ztd" -f "$EVAL_ROOT/deployment/helm/ztd/ci/values.yaml" "$@"; }
# plane namespaces from the chart's values.yaml
plane_namespaces() {
  python3 - "$EVAL_ROOT/deployment/helm/ztd/values.yaml" <<'PY'
import sys, yaml
v = yaml.safe_load(open(sys.argv[1]))
print(v["planes"]["management"]["namespace"]); print(v["planes"]["data"]["namespace"])
PY
}
# ns_labels <manifests-file> <namespace> -> "key=value" lines of that Namespace's labels
ns_labels() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
for d in docs:
    if d.get("kind") == "Namespace" and d.get("metadata", {}).get("name") == sys.argv[2]:
        for k, v in (d["metadata"].get("labels") or {}).items(): print(f"{k}={v}")
        break
else:
    print("NAMESPACE-NOT-RENDERED")
PY
}
kinds_of() { python3 -c 'import sys,yaml; [print(d.get("kind")) for d in yaml.safe_load_all(open(sys.argv[1])) if d]' "$1"; }
