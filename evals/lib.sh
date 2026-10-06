# Shared helpers for the checks of this suite. Sourced, never executed.
# REPO is the git work tree that holds evals/ (the runner's EVAL_ROOT may be a symlink farm).
REPO=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
CTX=${ZTD_EVAL_CONTEXT:-kind-ztd}
DATA=ztd-data
MGMT=ztd-mgmt
SPIRE_NS=spire-system
ISTIO_NS=istio-system
TD_KIND=kind.facis-ztd.local
INSTALL=$REPO/scripts/install-zone/install.sh
ZTD_CHART=$REPO/deployment/helm/ztd
KIND_ZONE=$ZTD_CHART/ci/values.yaml
k() { kubectl --context "$CTX" "$@"; }
h() { helm --kube-context "$CTX" "$@"; }

# need_live: exit 77 unless setup provisioned the zone on the kind cluster.
need_live() {
  if [ "${ZTD_LIVE:-0}" != 1 ]; then
    echo "UNVERIFIABLE: needs the kind-ztd cluster with the zone installed by evals/setup.sh (${ZTD_LIVE_REASON:-setup did not run})"
    exit 77
  fi
}
# render_all [dir]: the CI render of the seven releases from the pinned charts (install.sh render).
render_all() {
  local d=${1:-$EVAL_TMP/render}
  mkdir -p "$d"
  RENDER_DIR=$d "$INSTALL" render >"$d.log" 2>&1
}
# spire_server <args>: the spire-server CLI inside the server pod.
spire_server() { k -n "$SPIRE_NS" exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server "$@"; }
# fetch_svid <ns> <pod>: X.509 SVID JSON fetched over the CSI-mounted socket by the pod's svid container.
fetch_svid() {
  k -n "$1" exec "$2" -c svid -- /opt/spire/bin/spire-agent api fetch x509 \
    -socketPath /spiffe-workload-api/spire-agent.sock -timeout 10s -output json
}
# evidence_section <heading-substring>: lines of that "## " section of the committed evidence.
evidence_section() {
  awk -v s="$1" '/^## /{ on = index($0, s) > 0; next } on' "$REPO/docs/evidences/mesh-identity/evidence.md"
}
# evidence_section_passed <heading-substring>: at least one PASS line and no FAIL line in the section.
evidence_section_passed() {
  local sec; sec=$(evidence_section "$1")
  local p f
  p=$(grep -c '^- PASS' <<<"$sec"); f=$(grep -c '^- \*\*FAIL' <<<"$sec")
  echo "evidence section '$1': $p PASS, $f FAIL"
  [ "$p" -gt 0 ] && [ "$f" -eq 0 ]
}
# tcp_probe <ns> <pod> <container> <ip> <port>: connected | dropped | refused | other(<rc>)
# "connected" when curl established TCP (time_connect > 0); "dropped" on a connect timeout.
tcp_probe() {
  local out rc
  out=$(k -n "$1" exec "$2" -c "$3" -- curl -s -o /dev/null --connect-timeout 4 -m 8 -w '%{time_connect}' "http://$4:$5/" 2>/dev/null); rc=$?
  if [ -n "$out" ] && awk -v t="$out" 'BEGIN { exit !(t + 0 > 0) }'; then echo connected; return; fi
  case $rc in 28) echo dropped ;; 7) echo refused ;; *) echo "other($rc)" ;; esac
}
# need_state: exit 77 unless setup recorded its lifecycle runs (ZTD_STATE).
need_state() {
  if [ -z "${ZTD_STATE:-}" ] || [ ! -e "$ZTD_STATE/install1.rc" ]; then
    echo "UNVERIFIABLE: needs the lifecycle runs evals/setup.sh records on the kind-ztd cluster (${ZTD_LIVE_REASON:-setup did not run})"
    exit 77
  fi
}
# classify_policies <ns>: one line per policy rule class (evals/policies.py).
classify_policies() {
  k -n "$1" get networkpolicies -o json > "$EVAL_TMP/np-$1.json"
  k -n "$1" get ciliumnetworkpolicies -o json > "$EVAL_TMP/cnp-$1.json" 2>/dev/null || echo '{"items":[]}' > "$EVAL_TMP/cnp-$1.json"
  k get ciliumclusterwidenetworkpolicies -o json > "$EVAL_TMP/ccnp.json" 2>/dev/null || echo '{"items":[]}' > "$EVAL_TMP/ccnp.json"
  python3 "$REPO/evals/policies.py" "$1" "$EVAL_TMP/np-$1.json" "$EVAL_TMP/cnp-$1.json" "$EVAL_TMP/ccnp.json"
}
# pod_ports <ns> <pod>: container ports declared by the pod (all containers)
pod_ports() { k -n "$1" get pod "$2" -o json | jq -r '[.spec.containers[], (.spec.initContainers // [])[]] | .[].ports // [] | .[].containerPort' | sort -un; }
# spire_bundle_pem: the SPIRE server's X.509 bundle (PEM)
spire_bundle_pem() { spire_server bundle show -format pem; }
# pem_fingerprints <file>: sorted SHA-256 fingerprints of every certificate in a PEM file
pem_fingerprints() {
  python3 - "$1" <<'PY'
import re, sys, subprocess
pem = open(sys.argv[1]).read()
fps = set()
for blk in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S):
    out = subprocess.run(["openssl", "x509", "-noout", "-fingerprint", "-sha256"], input=blk, capture_output=True, text=True).stdout
    if "=" in out: fps.add(out.strip().split("=", 1)[1])
print("\n".join(sorted(fps)))
PY
}
# probe_control: the probe pod must connect where a lane allows it (intra-plane, ev-peer:8080),
# so that "dropped" results mean a policy drop, not a broken probe.
probe_control() {
  local ip r; ip=$(k -n "$DATA" get pod ev-peer -o jsonpath='{.status.podIP}')
  r=$(tcp_probe "$DATA" ev-probe app "$ip" 8080)
  echo "control: ev-probe -> ev-peer $ip:8080 (intra-plane lane) $r"
  [ "$r" = connected ] || { echo "BROKEN CHECK: the probe pod connects nowhere"; exit 1; }
}
