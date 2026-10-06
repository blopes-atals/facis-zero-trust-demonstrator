#!/usr/bin/env bash
# Evidence that the zone's mesh identities are SPIRE's, on the local kind cluster with Cilium chained
# (scripts/dev/kind-cilium-up.sh). Installs the zone from an empty cluster with
# scripts/install-zone/install.sh, twice, then proves with stand-in pods: an SVID over the CSI socket,
# the proxy's certificate and root bundle issued by SPIRE, an unregistered workload cut off, traffic
# through the proxies, the default deny intact with the chained CNI and both control planes inside
# it, the native-sidecar version rule, the identity-band checks, and a teardown that leaves nothing
# behind. Writes docs/evidences/mesh-identity/evidence.md and environment.json; the exit status is
# non-zero if any check failed. Never run by CI: the evidence is the record of a run on a cluster.
#
#   KUBE_CONTEXT   kubectl context   (default: kind-ztd)
#   ZONE_VALUES    zone file         (default: deployment/helm/ztd/ci/values.yaml, the kind zone)
#
# Every check is "<test>; check $? <title>": the status of the test is what the check records.
# shellcheck disable=SC2319,SC2016,SC2181,SC1091
set -uo pipefail
if [ -n "${CI:-}" ]; then
  echo "verify-mesh-identity: refusing to run under CI; the evidence is written from a run on a cluster" >&2
  exit 2
fi
cd "$(dirname "$0")" || exit 1
REPO=$(git rev-parse --show-toplevel)
CHART=$REPO/deployment/helm/ztd
ZONE_VALUES=${ZONE_VALUES:-$CHART/ci/values.yaml}
CONTEXT=${KUBE_CONTEXT:-kind-ztd}
INSTALL=$REPO/scripts/install-zone/install.sh
EVID=$REPO/docs/evidences/mesh-identity
export ZONE_VALUES KUBE_CONTEXT=$CONTEXT
# yaml_get <file> <key>... : one value out of a YAML file; the path travels as an argument, never inside the source
yaml_get() { python3 -c 'import sys,yaml
v=yaml.safe_load(open(sys.argv[1]))
for k in sys.argv[2:]: v=v[k]
print(v)' "$@"; }
MGMT=$(yaml_get "$CHART/values.yaml" planes management namespace)
DATA=$(yaml_get "$CHART/values.yaml" planes data namespace)
TD=$(yaml_get "$ZONE_VALUES" zone trustDomain)
SPIRE_NS=spire-system; ISTIO_NS=istio-system
images_spire=""; images_istio=""; images_proxy=""
RELEASES="ztd:ztd-system spire-crds:$SPIRE_NS spire:$SPIRE_NS istio-base:$ISTIO_NS istiod:$ISTIO_NS istio-cni:$ISTIO_NS zone-policy:$ISTIO_NS"
SA_ID="spiffe://$TD/ns/$DATA/sa/stand-in"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
OUT=$work/evidence.md
failures=0
# The commit and the dirty flag are read before anything is written into the tree.
commit=$(git rev-parse HEAD)
dirty=false; [ -n "$(git status --porcelain)" ] && dirty=true
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)

k() { kubectl --context "$CONTEXT" "$@"; }
h() { helm --kube-context "$CONTEXT" "$@"; }
say() { printf '%s\n' "$@" >> "$OUT"; }
code() { say '' '```'; say "$@"; say '```' ''; }
check() { # check <PASS-condition exit status> <title> <detail...>
  local status=$1; shift; local title=$1; shift
  if [ "$status" -eq 0 ]; then say "- PASS: $title"; else say "- **FAIL**: $title"; failures=$((failures+1)); fi
  [ $# -gt 0 ] && say "  $*"
  return 0
}
section() { say '' "## $1" ''; echo "== $1"; }
spire_server() { k -n "$SPIRE_NS" exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server "$@"; }
# http <ns> <pod> <container> <url>: HTTP code and the first line of the body, or denied(<curl exit>)
http() {
  local out rc
  out=$(k -n "$1" exec "$2" -c "$3" -- curl -sS -m 15 -w '\n%{http_code}' "$4" 2>/dev/null); rc=$?
  if [ $rc -eq 0 ]; then printf '%s %s' "$(tail -1 <<<"$out")" "$(head -1 <<<"$out" | cut -c1-110)"; else echo "denied($rc)"; fi
}
# tcp <ns> <pod> <ip> <port>: "connected" when a TCP connection is established, else denied(<curl exit>)
tcp() {
  local rc
  k -n "$1" exec "$2" -c app -- curl -s -o /dev/null --connect-timeout 4 -m 6 "http://$3:$4/" >/dev/null 2>&1; rc=$?
  case $rc in 7|28) echo "denied($rc)";; *) echo connected;; esac
}
fingerprint() { openssl x509 -noout -fingerprint -sha256 -in "$1" | cut -d= -f2; }
# metric <ns> <pod> <reporter>: istio_requests_total of the proxy for one reporter, summed
metric() {
  k -n "$1" exec "$2" -c istio-proxy -- pilot-agent request GET stats/prometheus 2>/dev/null \
    | awk -v r="reporter=\"$3\"" '/^istio_requests_total/ && index($0, r) { s += $NF } END { print s + 0 }'
}

: > "$OUT"
say "# Mesh identity evidence ($started)" ''
say "Cluster context \`$CONTEXT\`, zone file \`${ZONE_VALUES#"$REPO"/}\` (trust domain \`$TD\`), installed with \`scripts/install-zone/install.sh\`: the seven releases \`ztd\`, \`spire-crds\`, \`spire\`, \`istio-base\`, \`istiod\`, \`istio-cni\`, \`zone-policy\`. Commit \`$commit\`, tree dirty: $dirty. Versions in \`environment.json\`." ''
say 'Probe results: an HTTP code with the first line of the body when the call went through its proxies; `denied(28)` when a raw TCP connection timed out because the policy dropped the packets; `denied(56)` when the peer reset the connection.' ''

# --------------------------------------------------------------------------------------------
section "0. Preconditions"
server=$(k version -o json | jq -r .serverVersion.gitVersion)
recorded=$(yaml_get "$ZONE_VALUES" zone kubernetesVersion)
[ "$server" = "$recorded" ]; check $? "the zone file records the server version the cluster runs" "server $server, recorded $recorded"
python3 - "$server" <<'PY'; check $? "native-sidecar-version: the server is Kubernetes 1.33 or later (native sidecar containers)" "server $server"
import re, sys
major, minor = map(int, re.match(r"v(\d+)\.(\d+)", sys.argv[1]).groups())
sys.exit(0 if (major, minor) >= (1, 33) else 1)
PY
cni=$(k -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
[ -n "$cni" ]; check $? "Cilium is the CNI" "$cni"
excl=$(k -n kube-system get cm cilium-config -o jsonpath='{.data.cni-exclusive}' 2>/dev/null)
[ "$excl" = "false" ]; check $? "cni-exclusive=false (the Istio CNI plugin can chain)" "cni-exclusive=$excl"
inotify=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)
[ "$inotify" -ge 512 ]; check $? "the host allows 512 inotify instances (kind runs every node's agents on one kernel; the Istio CNI agent fails below)" "fs.inotify.max_user_instances=$inotify"
code "$(k get nodes -o wide | sed 's/  */ /g')"

# --------------------------------------------------------------------------------------------
section "1. Clean slate"
"$INSTALL" uninstall >"$work/clean.log" 2>&1
k get ns "$MGMT" "$DATA" "$SPIRE_NS" "$ISTIO_NS" >/dev/null 2>&1; [ $? -ne 0 ]; check $? "no plane namespace and no control-plane namespace exists before the install"
left=$(k get crd -o name | grep -E 'spiffe\.io|istio\.io' || true)
[ -z "$left" ]; check $? "no SPIRE or Istio custom resource definition exists before the install" "${left:-none}"

# --------------------------------------------------------------------------------------------
section "2. install-order-idempotent: the zone from an empty cluster, twice"
start=$(date +%s)
"$INSTALL" install >"$work/install1.log" 2>&1; rc=$?
check $rc "first installer run from an empty cluster returns 0, no manual step between the releases" "$(( $(date +%s) - start ))s"
code "$(grep -E '^(  [0-9]/7|step|zone installed)' "$work/install1.log")"
[ $rc -ne 0 ] && code "$(tail -30 "$work/install1.log")"
for r in $RELEASES; do h get manifest "${r%%:*}" -n "${r#*:}" >"$work/manifest-1-${r%%:*}.yaml" 2>/dev/null; done
start=$(date +%s)
"$INSTALL" install >"$work/install2.log" 2>&1; rc=$?
check $rc "second installer run returns 0" "$(( $(date +%s) - start ))s; $(grep -c 'deployed, revision' "$work/install2.log") releases upgraded in place"
same=0; diffs=""
for r in $RELEASES; do
  h get manifest "${r%%:*}" -n "${r#*:}" >"$work/manifest-2-${r%%:*}.yaml" 2>/dev/null
  if [ -s "$work/manifest-1-${r%%:*}.yaml" ] && diff -q "$work/manifest-1-${r%%:*}.yaml" "$work/manifest-2-${r%%:*}.yaml" >/dev/null; then same=$((same+1)); else diffs="$diffs ${r%%:*}"; fi
done
[ "$same" -eq 7 ]; check $? "helm get manifest of every release is identical between the two runs" "$same of 7 identical${diffs:+; differ:$diffs}"
tail -1 "$work/install2.log" | grep -q '^zone installed: every pod'; check $? "every pod in the plane and control-plane namespaces is Ready (the installer's exit condition)" "$(tail -1 "$work/install2.log")"
code "$(h list -A -o json | jq -r '(["RELEASE","NAMESPACE","REVISION","STATUS","CHART"] | join(" ")), (.[] | [.name, .namespace, .revision, .status, .chart] | join(" "))')"
images_spire=$(k -n "$SPIRE_NS" get pods -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | sort -u | paste -sd, -)
images_istio=$(k -n "$ISTIO_NS" get pods -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | sort -u | paste -sd, -)
code "$(k get pods -n "$SPIRE_NS" -o wide | sed 's/  */ /g'; echo; k get pods -n "$ISTIO_NS" -o wide | sed 's/  */ /g')"

# --------------------------------------------------------------------------------------------
section "3. The identity-band checks of zone-policy, and a failing step"
st=$(h status zone-policy -n "$ISTIO_NS" -o json | jq -r .info.status)
[ "$st" = deployed ]; check $? "zone-policy is deployed: the server-healthy, trust-bundle-published and registrations-reconciled jobs (weights 20, 25, 30) passed" "$st"
left=$(k -n "$ISTIO_NS" get jobs -l ztd.facis.io/identity-check -o name 2>/dev/null)
[ -z "$left" ]; check $? "the identity-check jobs were removed by their hook delete policy" "${left:-none left}"
hooked=$(h get manifest zone-policy -n "$ISTIO_NS" | python3 -c 'import sys,yaml
print(sum(1 for d in yaml.safe_load_all(sys.stdin) if d and d["kind"]=="ClusterSPIFFEID" and "helm.sh/hook" in (d["metadata"].get("annotations") or {})))')
[ "$hooked" = 0 ] && k get clusterspiffeid plane-workloads >/dev/null 2>&1; check $? "the ClusterSPIFFEID is a regular resource of the release, not a hook" "ClusterSPIFFEIDs with a hook annotation: $hooked"

out=$(STEP_TIMEOUT=1s "$INSTALL" install 2>&1); rc=$?
line=$(grep -m1 'FAILED' <<<"$out")
[ $rc -ne 0 ] && grep -q 'step 1/7 FAILED: release ztd' <<<"$out" && ! grep -q 'step 2/7' <<<"$out"
check $? "a release that does not reach a ready state within its timeout (here 1 s) stops the installer at that step, non-zero, naming the release" "$line"
st=$(h status ztd -n ztd-system -o json | jq -r .info.status)
[ "$st" = deployed ]; check $? "the failed release was rolled back by the lifecycle step" "ztd: $st, $(h history ztd -n ztd-system --max 1 -o json | jq -r '.[0].description')"

# --------------------------------------------------------------------------------------------
section "4. The layout of the control planes"
code "$(k get ns "$MGMT" "$DATA" "$SPIRE_NS" "$ISTIO_NS" -L ztd.facis.io/plane,istio-injection | sed 's/  */ /g')"
for ns in "$SPIRE_NS" "$ISTIO_NS"; do
  [ "$(k get ns "$ns" -o jsonpath='{.metadata.labels.ztd\.facis\.io/plane}')" = management ] && [ -z "$(k get ns "$ns" -o jsonpath='{.metadata.labels.istio-injection}')" ]
  check $? "$ns is a management-plane namespace without the injection label"
done
code "$(for ns in "$SPIRE_NS" "$ISTIO_NS"; do k -n "$ns" get networkpolicy,ciliumnetworkpolicy -o custom-columns=NAMESPACE:.metadata.namespace,KIND:.kind,NAME:.metadata.name,OPENING:.metadata.annotations.ztd\\.facis\\.io/declared-opening --no-headers; done | sed 's/  */ /g')"
pols() { { k -n "$1" get networkpolicy -o name; k -n "$1" get ciliumnetworkpolicy -o name; } | sed 's#.*/##' | sort | tr '\n' ' ' | sed 's/ $//'; }
want_spire="allow-control-plane-openings allow-dns-egress allow-intra-plane allow-kube-api-egress default-deny"
want_istio="allow-control-plane-openings allow-dns-egress allow-intra-plane allow-kube-api-egress allow-mesh-control-plane-ingress default-deny"
[ "$(pols "$SPIRE_NS")" = "$want_spire" ]; check $? "$SPIRE_NS holds only the default deny, the DNS bypass, the intra-plane lane, the API lane and the entity-sourced openings (webhook, agents)" "$(pols "$SPIRE_NS")"
[ "$(pols "$ISTIO_NS")" = "$want_istio" ]; check $? "$ISTIO_NS holds only the default deny, the DNS bypass, the intra-plane lane, the API lane, the webhook opening and the sidecars' xDS opening" "$(pols "$ISTIO_NS")"
sidecars=$(k -n "$SPIRE_NS" get pods -o json | jq -r '.items[] | select([.spec.containers[].name, (.spec.initContainers // [])[].name] | index("istio-proxy")) | .metadata.name')
[ -z "$sidecars" ]; check $? "no SPIRE pod has an istio-proxy container" "${sidecars:-none}"
agents_ready=$(k -n "$SPIRE_NS" get ds spire-agent -o jsonpath='{.status.numberReady}')
attested=$(spire_server agent list -output json 2>/dev/null | jq '.agents | length')
[ -n "$attested" ] && [ "$attested" = "$agents_ready" ] && [ "$attested" -gt 0 ]; check $? "every SPIRE agent is attested by the server (through the identityServer opening)" "agents Ready $agents_ready, attested $attested"
server_td=$(k -n "$SPIRE_NS" get cm spire-server -o jsonpath='{.data.server\.conf}' | jq -r .server.trust_domain)
mesh_td=$(k -n "$ISTIO_NS" get cm istio -o jsonpath='{.data.mesh}' | awk '/^trustDomain:/ {print $2}')
[ "$server_td" = "$TD" ] && [ "$mesh_td" = "$TD" ]; check $? "the SPIRE server and the mesh run with the zone's trust domain" "SPIRE $server_td, mesh $mesh_td, zone file $TD"

# --------------------------------------------------------------------------------------------
section "5. Stand-in pods"
say 'From `scripts/verify-mesh-identity/fixtures/stand-ins.yaml`: in the data plane a meshed peer, a labelled caller with a Workload API client on the CSI socket, an unlabelled meshed pod, an unlabelled pod without proxy with a Workload API client, the matrix pair `pdp-adapter` and the cross-plane caller `data-plain`; in the management plane `tsa-policy-engine`, `openbao` and `mgmt-caller`; in both a proxy-less `probe` for raw TCP probes. All in the service account `stand-in` unless noted.' ''
sed -e "s/__DATA__/$DATA/g" -e "s/__MGMT__/$MGMT/g" fixtures/stand-ins.yaml | k apply -f - >/dev/null
k -n "$DATA" wait --for=condition=Ready pod/peer pod/caller pod/unregistered-svid pod/probe pod/pdp-adapter pod/data-plain --timeout=240s >/dev/null 2>&1; check $? "the labelled data-plane stand-ins are Ready"
k -n "$MGMT" wait --for=condition=Ready pod/tsa-policy-engine pod/openbao pod/mgmt-caller pod/probe --timeout=240s >/dev/null 2>&1; check $? "the management-plane stand-ins are Ready"
sleep 10
code "$(k get pods -n "$DATA" -o wide | sed 's/  */ /g'; echo; k get pods -n "$MGMT" -o wide | sed 's/  */ /g')"

# --------------------------------------------------------------------------------------------
section "6. svid-over-csi-socket"
vol=$(k -n "$DATA" get pod caller -o json | jq -r '[.spec.volumes[] | select(.csi.driver == "csi.spiffe.io") | .name] | join(",")')
[ -n "$vol" ]; check $? "the labelled pod mounts the csi.spiffe.io volume" "volumes: $vol (one for the Workload API client, one for the proxy)"
k -n "$DATA" exec caller -c svid -- /opt/spire/bin/spire-agent api fetch x509 -socketPath /run/spiffe/socket -output json >"$work/svid.json" 2>"$work/svid.err"
# The JSON carries the private key too; only the certificates and the ID are kept from it.
svid_id=$(jq -r '.svids[0].spiffe_id' "$work/svid.json" 2>/dev/null)
jq -r '.svids[0].x509_svid' "$work/svid.json" | base64 -d >"$work/svid-chain.der" 2>/dev/null
openssl x509 -inform DER -in "$work/svid-chain.der" -out "$work/svid.pem" 2>/dev/null
spire_server bundle show >"$work/spire-bundle.pem" 2>/dev/null
[ "$svid_id" = "$SA_ID" ]; check $? "the SVID fetched over the mounted socket carries the SPIFFE ID of the pod's service account in the zone's trust domain" "$svid_id"
issuer=$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$work/svid.pem" 2>/dev/null)
ca_subject=$(openssl x509 -noout -subject -nameopt RFC2253 -in "$work/spire-bundle.pem" 2>/dev/null)
openssl verify -CAfile "$work/spire-bundle.pem" "$work/svid.pem" >/dev/null 2>&1; check $? "the SVID chains to the SPIRE server's CA (the bundle read from the server)" "${issuer}; SPIRE CA ${ca_subject}"
code "$(openssl x509 -noout -subject -issuer -dates -ext subjectAltName -nameopt RFC2253 -in "$work/svid.pem")"
spire_server entry show -output json >"$work/entries.json" 2>/dev/null
uid_caller=$(k -n "$DATA" get pod caller -o jsonpath='{.metadata.uid}')
uid_unreg=$(k -n "$DATA" get pod unregistered -o jsonpath='{.metadata.uid}')
uid_unreg_svid=$(k -n "$DATA" get pod unregistered-svid -o jsonpath='{.metadata.uid}')
entry_for() { jq -r --arg u "k8s:pod-uid:$1" '.entries[] | select([.selectors[] | "\(.type):\(.value)"] | index($u)) | "spiffe://\(.spiffe_id.trust_domain)\(.spiffe_id.path)"' "$work/entries.json"; }
[ "$(entry_for "$uid_caller")" = "$SA_ID" ]; check $? "the SPIRE server lists an entry for the labelled pod, created from the ClusterSPIFFEID" "$(entry_for "$uid_caller")"
[ -z "$(entry_for "$uid_unreg")$(entry_for "$uid_unreg_svid")" ]; check $? "the SPIRE server lists no entry for the two unlabelled pods"
out=$(k -n "$DATA" exec unregistered-svid -c svid -- /opt/spire/bin/spire-agent api fetch x509 -socketPath /run/spiffe/socket -timeout 5s 2>&1); rc=$?
[ $rc -ne 0 ]; check $? "an unlabelled pod's fetch over the mounted socket returns no SVID" "$(grep -v 'command terminated' <<<"$out" | tail -1)"
stats=$(k get clusterspiffeid plane-workloads -o jsonpath='{.status.stats}')
say "  ClusterSPIFFEID \`plane-workloads\` status: \`$stats\`"

# --------------------------------------------------------------------------------------------
section "7. native-sidecar-version"
pod=$(k -n "$DATA" get pod caller -o json)
images_proxy=$(jq -r '.spec.initContainers[] | select(.name == "istio-proxy") | .image' <<<"$pod")
jq -e '[.spec.initContainers[] | select(.name == "istio-proxy" and .restartPolicy == "Always")] | length == 1' <<<"$pod" >/dev/null \
  && jq -e '[.spec.containers[] | select(.name == "istio-proxy")] | length == 0' <<<"$pod" >/dev/null
check $? "istio-proxy is an init container with restartPolicy Always (a native sidecar), not a regular container" "$(jq -r '[.spec.initContainers[] | "\(.name)(restartPolicy=\(.restartPolicy // "-"))"] | join(", ")' <<<"$pod")"
[ "$(jq -r '.status.conditions[] | select(.type == "Ready") | .status' <<<"$pod")" = True ]; check $? "the meshed pod is Ready"

# --------------------------------------------------------------------------------------------
section "8. mesh-identity-issued-by-spire"
istioctl --context "$CONTEXT" proxy-config secret caller -n "$DATA" >"$work/secret.txt" 2>&1
code "$(cat "$work/secret.txt")"
istioctl --context "$CONTEXT" proxy-config secret caller -n "$DATA" -o json >"$work/secret.json" 2>/dev/null
jq -r '.dynamicActiveSecrets[] | select(.name == "default") | .secret.tlsCertificate.certificateChain.inlineBytes' "$work/secret.json" | base64 -d >"$work/proxy-chain.pem" 2>/dev/null
# SPIRE serves ROOTCA as Envoy's SPIFFE certificate validator: one trust bundle per trust domain.
jq -r --arg td "$TD" '.dynamicActiveSecrets[] | select(.name == "ROOTCA") | .secret.validationContext
  | (.trustedCa.inlineBytes // (.customValidatorConfig.typedConfig.trustDomains[]? | select(.name == $td) | .trustBundle.inlineBytes))' \
  "$work/secret.json" | base64 -d >"$work/proxy-root.pem" 2>/dev/null
rootca_domains=$(jq -r '[.dynamicActiveSecrets[] | select(.name == "ROOTCA") | .secret.validationContext.customValidatorConfig.typedConfig.trustDomains[]?.name] | join(",")' "$work/secret.json")
openssl x509 -in "$work/proxy-chain.pem" -out "$work/proxy-leaf.pem" 2>/dev/null
subj=$(openssl x509 -noout -subject -nameopt RFC2253 -in "$work/proxy-leaf.pem" 2>/dev/null)
p_issuer=$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$work/proxy-leaf.pem" 2>/dev/null)
p_uri=$(openssl x509 -noout -ext subjectAltName -in "$work/proxy-leaf.pem" 2>/dev/null | grep -o 'URI:[^,]*' | sed 's/URI://')
grep -q 'O=SPIRE' <<<"$subj"; check $? "the proxy's workload certificate (default) has O = SPIRE in its subject" "$subj"
[ "${p_issuer#issuer=}" = "${ca_subject#subject=}" ] && openssl verify -CAfile "$work/spire-bundle.pem" "$work/proxy-leaf.pem" >/dev/null 2>&1
check $? "its issuer is the SPIRE server CA and it chains to SPIRE's bundle" "$p_issuer"
[ "$p_uri" = "$svid_id" ]; check $? "its URI SAN equals the SVID fetched over the socket" "$p_uri"
[ -s "$work/proxy-root.pem" ] && [ "$(fingerprint "$work/proxy-root.pem")" = "$(fingerprint "$work/spire-bundle.pem")" ]
check $? "the proxy holds a root bundle under ROOTCA, and it is the SPIRE server's CA" "ROOTCA (SPIFFE validator, trust domains: ${rootca_domains:-none}) $(fingerprint "$work/proxy-root.pem" 2>/dev/null), SPIRE CA $(fingerprint "$work/spire-bundle.pem")"
[ "$rootca_domains" = "$TD" ]; check $? "the ROOTCA bundle trusts the zone's trust domain and no other" "${rootca_domains:-none}"
k -n "$SPIRE_NS" get cm istio-ca-root-cert -o jsonpath='{.data.root-cert\.pem}' >"$work/istiod-root.pem"
[ -s "$work/istiod-root.pem" ] && openssl x509 -noout -in "$work/istiod-root.pem" >/dev/null 2>&1 \
  && ! openssl verify -CAfile "$work/istiod-root.pem" "$work/proxy-leaf.pem" >/dev/null 2>&1; check $? "istiod's own CA did not issue it (istiod's root is a certificate, and the leaf does not verify against it)" "istiod root $(openssl x509 -noout -subject -nameopt RFC2253 -in "$work/istiod-root.pem")"

# --------------------------------------------------------------------------------------------
section "9. unregistered-workload-cut-off"
# The pod never runs (its proxy is not ready), so istioctl cannot port-forward to it; the proxy's
# own admin endpoint is read through the running container instead.
active=$(k -n "$DATA" exec unregistered -c istio-proxy -- pilot-agent request GET 'config_dump?resource=dynamic_active_secrets' 2>/dev/null | jq -c '[.configs[]? | .name]')
warming=$(k -n "$DATA" exec unregistered -c istio-proxy -- pilot-agent request GET 'config_dump?resource=dynamic_warming_secrets' 2>/dev/null | jq -c '[.configs[]? | .name]')
[ -n "$active" ] && ! jq -e 'index("default")' <<<"$active" >/dev/null && jq -e 'index("default")' <<<"$warming" >/dev/null
check $? "the unlabelled pod's proxy holds no workload certificate: it asked for 'default' and was never served" "active secrets $active, still warming $warming"
log=$(k -n "$DATA" logs unregistered -c istio-proxy --tail=200 2>/dev/null | grep -m1 -o 'workload is not authorized for the requested identities[^{]*')
[ -n "$log" ]; check $? "the SPIRE agent refuses its proxy over SDS" "$log"
appstate=$(k -n "$DATA" get pod unregistered -o jsonpath='{.status.containerStatuses[?(@.name=="app")].state}')
grep -q waiting <<<"$appstate"; check $? "its application container never starts: the native sidecar holds it until the proxy has a certificate" "$appstate"
r=$(http "$DATA" unregistered istio-proxy "http://peer.$DATA.svc:8080/hostname")
case $r in denied*) true;; *) false;; esac; check $? "a call from its network namespace to the meshed peer is refused: the peer accepts mTLS only (STRICT)" "→ $r"
r=$(http "$DATA" caller app "http://peer.$DATA.svc:8080/hostname")
[ "${r%% *}" = 200 ]; check $? "the labelled pod's call to the same peer succeeds" "→ $r"

# --------------------------------------------------------------------------------------------
section "10. traffic-through-the-proxies"
src0=$(metric "$DATA" caller source); dst0=$(metric "$DATA" peer destination)
xfcc=$(k -n "$DATA" exec caller -c app -- curl -sS -m 15 "http://peer.$DATA.svc:8080/header?key=X-Forwarded-Client-Cert" 2>&1)
grep -qF "URI=$SA_ID" <<<"$xfcc"; check $? "the peer sees the caller's SPIFFE identity in X-Forwarded-Client-Cert" "$xfcc"
sleep 3
src1=$(metric "$DATA" caller source); dst1=$(metric "$DATA" peer destination)
[ "$src1" -gt "$src0" ] && [ "$dst1" -gt "$dst0" ]; check $? "both proxies counted the request (istio_requests_total)" "caller (reporter=source) $src0 → $src1, peer (reporter=destination) $dst0 → $dst1"
k -n "$DATA" exec peer -c istio-proxy -- pilot-agent request GET stats/prometheus 2>/dev/null | grep '^istio_requests_total' | grep -q 'connection_security_policy="mutual_tls"'
check $? "the peer's proxy records the requests as mutual_tls"

# --------------------------------------------------------------------------------------------
section "11. default-deny-with-chained-cni"
for P in $(k -n "$ISTIO_NS" get pod -l k8s-app=istio-cni-node -o jsonpath='{.items[*].metadata.name}'); do
  NODE=$(k -n "$ISTIO_NS" get pod "$P" -o jsonpath='{.spec.nodeName}')
  conf=$(k -n "$ISTIO_NS" exec "$P" -- sh -c 'ls /host/etc/cni/net.d/*.conflist | head -1')
  plugins=$(k -n "$ISTIO_NS" exec "$P" -- cat "$conf" | jq -r '[.plugins[].type] | join(" → ")')
  [[ "$plugins" == cilium-cni*istio-cni* ]]; check $? "the CNI configuration of node $NODE lists the Istio plugin after Cilium" "${conf#/host}: $plugins"
done
[ "$excl" = false ]; check $? "Cilium still runs with cni-exclusive=false" "cni-exclusive=$excl"
r=$(http "$DATA" data-plain app "http://openbao.$MGMT.svc:8080/hostname")
case $r in denied*) true;; *) false;; esac; check $? "data-plane pod → openbao (management): DENIED at the network layer with the proxies in place" "→ $r"
r=$(http "$DATA" data-plain app "http://tsa-policy-engine.$MGMT.svc:8080/hostname")
case $r in denied*) true;; *) false;; esac; check $? "data-plane pod → tsa-policy-engine (management): DENIED" "→ $r"
r=$(http "$DATA" pdp-adapter app "http://tsa-policy-engine.$MGMT.svc:8080/hostname")
[ "${r%% *}" = 200 ]; check $? "pdp-adapter → tsa-policy-engine: ALLOWED (matrix lane pdp-adapter-to-tsa), through the proxies" "→ $r"
r=$(http "$DATA" pdp-adapter app "http://openbao.$MGMT.svc:8080/hostname")
case $r in denied*) true;; *) false;; esac; check $? "pdp-adapter → openbao: DENIED (a lane is one pair, not a licence)" "→ $r"
r=$(http "$MGMT" mgmt-caller app "http://peer.$DATA.svc:8080/hostname")
case $r in denied*) true;; *) false;; esac; check $? "management pod → data plane: DENIED (the default deny is both directions)" "→ $r"
r=$(k -n "$DATA" exec probe -c app -- nslookup "openbao.$MGMT.svc.cluster.local" 2>&1 | grep -A1 '^Name:' | tr '\n' ' ')
[ -n "$r" ]; check $? "DNS bypass: names still resolve" "$r"

# --------------------------------------------------------------------------------------------
section "12. control-planes-under-default-deny"
istioctl --context "$CONTEXT" proxy-status -o json >"$work/ps.json" 2>/dev/null
unsynced=$(jq -r --arg ns "$DATA" '.resources[] | select(.node.metadata.NAMESPACE == $ns and (.node.id | test("^(caller|peer|pdp-adapter|data-plain)\\."))) | . as $r | .genericXdsConfigs[] | select(.configStatus != "SYNCED") | "\($r.node.id) \(.typeUrl) \(.configStatus)"' "$work/ps.json")
synced=$(jq -r --arg ns "$DATA" '[.resources[] | select(.node.metadata.NAMESPACE == $ns and (.node.id | test("^(caller|peer|pdp-adapter|data-plain)\\.")))] | length' "$work/ps.json")
[ "$synced" = 4 ] && [ -z "$unsynced" ]; check $? "the registered proxies reach istiod through the meshControlPlane opening and report SYNCED for every xDS type" "proxies $synced, not SYNCED: ${unsynced:-none}"
# The API server -> the webhooks, asked of each webhook now, by server-side dry runs that persist
# nothing: istiod's injector must add the proxy, and the controller-manager's validator must refuse
# a ClusterSPIFFEID whose template does not parse (its failurePolicy may be Ignore, so an admitted
# object would prove nothing; only the webhook's own refusal shows it was reached).
inj=$(k -n "$DATA" run webhook-probe --image=registry.k8s.io/e2e-test-images/agnhost:2.53 --restart=Never \
  --dry-run=server -o json 2>&1 | jq -r '[(.spec.initContainers // [])[].name, .spec.containers[].name] | join(",")' 2>&1)
grep -qw istio-proxy <<<"$inj"; check $? "the API server reaches istiod's injection webhook (15017) through the controlPlaneWebhooks opening: a dry-run pod in $DATA is injected" "containers: $inj"
cs=$(printf '%s\n' 'apiVersion: spire.spiffe.io/v1alpha1' 'kind: ClusterSPIFFEID' 'metadata: { name: webhook-probe }' \
  'spec: { spiffeIDTemplate: "spiffe://{{ .TrustDomain" }' | k create --dry-run=server -f - 2>&1)
grep -q 'admission webhook "vclusterspiffeid.kb.io" denied the request' <<<"$cs"
check $? "the API server reaches the controller-manager's webhook (9443) through the controlPlaneWebhooks opening: it refuses a ClusterSPIFFEID with a broken template" "$(head -c 300 <<<"$cs")"
SPIRE_IP=$(k -n "$SPIRE_NS" get pod spire-server-0 -o jsonpath='{.status.podIP}')
ISTIOD_IP=$(k -n "$ISTIO_NS" get pod -l app=istiod -o jsonpath='{.items[0].status.podIP}')
say '' "Raw TCP probes from the proxy-less \`probe\` pods to the SPIRE server ($SPIRE_IP) and istiod ($ISTIOD_IP), on every port they listen on:" ''
for ns in "$DATA" "$MGMT"; do
  for port in 8081 8080 9443 9988 8082 8083; do
    r=$(tcp "$ns" probe "$SPIRE_IP" "$port")
    case $r in denied*) true;; *) false;; esac; check $? "$ns → SPIRE server :$port DENIED" "→ $r"
  done
  for port in 15017 15014 15010 8080; do
    r=$(tcp "$ns" probe "$ISTIOD_IP" "$port")
    case $r in denied*) true;; *) false;; esac; check $? "$ns → istiod :$port DENIED" "→ $r"
  done
  r=$(tcp "$ns" probe "$ISTIOD_IP" 15012)
  [ "$r" = connected ]; check $? "$ns → istiod :15012 (xDS) reachable: the declared meshControlPlane opening" "→ $r"
done

# --------------------------------------------------------------------------------------------
section "13. A declared registration without its entry fails the release"
say 'The registrations-reconciled check counts the running labelled pods of every plane namespace and compares them with what the controller-manager reconciled. To make one registration go unreconciled, the kind namespace `local-path-storage`, which the controller-manager is configured to ignore, is labelled as a plane for the duration of the step and gets a labelled pod; then zone-policy is upgraded through the lifecycle step with a 20 s check timeout. Afterwards the label and the pod are removed and the rollback restores the release.' ''
k label ns local-path-storage ztd.facis.io/plane=data --overwrite >/dev/null
k -n local-path-storage run declared-not-reconciled --image=docker.io/curlimages/curl:8.10.1@sha256:d9b4541e214bcd85196d6e92e2753ac6d0ea699f0af5741f8c6cccbfcf00ef4b --labels=spiffe.io/spire-managed-identity=true --command -- sleep 3600 >/dev/null
k -n local-path-storage wait --for=condition=Ready pod/declared-not-reconciled --timeout=120s >/dev/null 2>&1
printf 'trustDomain: %s\nchecks:\n  timeoutSeconds: 20\n' "$TD" >"$work/zp-values.yaml"
k config view --minify --flatten --context "$CONTEXT" >"$work/kubeconfig"
res=$(KUBECONFIG=$work/kubeconfig LIFECYCLE_RELEASE=zone-policy LIFECYCLE_NAMESPACE=$ISTIO_NS LIFECYCLE_CHART=$REPO/deployment/helm/zone-policy \
  LIFECYCLE_VALUES_FILE=$work/zp-values.yaml LIFECYCLE_TIMEOUT=3m "$REPO/scripts/lifecycle.sh" deploy 2>/dev/null | grep '^RESULT_JSON=' | cut -d= -f2-)
[ "$(jq -r .ok <<<"$res")" = false ]; check $? "the upgrade fails and is rolled back" "$(jq -r '.error.message' <<<"$res")"
jl=$(k -n "$ISTIO_NS" logs job/zone-policy-registrations-reconciled 2>/dev/null | grep -E '^(FAIL|ok)' | tail -2 | tr '\n' ' ')
grep -q 'FAIL every registration' <<<"$jl"; check $? "the registrations-reconciled job exits non-zero naming the gap" "$jl"
k -n "$ISTIO_NS" delete job -l ztd.facis.io/identity-check --ignore-not-found >/dev/null
k -n local-path-storage delete pod declared-not-reconciled --wait=true >/dev/null 2>&1
k label ns local-path-storage ztd.facis.io/plane- >/dev/null
st=$(h status zone-policy -n "$ISTIO_NS" -o json | jq -r .info.status)
[ "$st" = deployed ]; check $? "after the step the release is deployed again (rollback)" "$(h history zone-policy -n "$ISTIO_NS" --max 3 -o json | jq -r '[.[] | "\(.revision) \(.status)"] | join(", ")')"

# --------------------------------------------------------------------------------------------
section "14. Render guards (no cluster)"
python3 - "$ZONE_VALUES" "$work/no-td.yaml" <<'PY'
import sys, yaml
z = yaml.safe_load(open(sys.argv[1])); z["zone"].pop("trustDomain", None)
yaml.safe_dump(z, open(sys.argv[2], "w"))
PY
out=$(ZONE_VALUES=$work/no-td.yaml "$INSTALL" render spire 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q 'zone.trustDomain' <<<"$out"; check $? "the spire release does not render without the trust domain" "$(tail -1 <<<"$out")"
out=$(ZONE_VALUES=$work/no-td.yaml "$INSTALL" render istiod 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q 'zone.trustDomain' <<<"$out"; check $? "the istiod release does not render without the trust domain" "$(tail -1 <<<"$out")"
out=$(helm template ztd "$CHART" -f "$work/no-td.yaml" 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q "/zone/trustDomain" <<<"$out"; check $? "the umbrella refuses a meshed zone without a trust domain, on the schema" "$(grep -o "at '/zone/trustDomain'.*" <<<"$out" | head -1)"
helm template ztd "$CHART" -f "$CHART/zones/ionos.yaml" >/dev/null 2>&1; check $? "the umbrella renders zones/ionos.yaml (mesh none) without a trust domain"
out=$(helm template ztd "$CHART" -f "$ZONE_VALUES" --set zone.kubernetesVersion=v1.32.0 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q 'native sidecar' <<<"$out"; check $? "the umbrella refuses sidecar mode below Kubernetes 1.33" "$(grep -o 'mesh.mode sidecar needs.*' <<<"$out")"
out=$(helm template ztd "$CHART" -f "$ZONE_VALUES" --set cni.cilium.enabled=false 2>&1); rc=$?
[ $rc -ne 0 ] && grep -q 'derogation' <<<"$out"; check $? "the umbrella refuses a meshed zone without Cilium, naming the openings and the derogation" "$(grep -o 'mesh.mode sidecar needs Cilium[^:]*' <<<"$out")"

# --------------------------------------------------------------------------------------------
section "15. Teardown: uninstall in reverse order"
kept=$(k get crd -o json | jq -r '[.items[] | select(.spec.group == "spire.spiffe.io") | "\(.metadata.name)=\(.metadata.annotations["helm.sh/resource-policy"] // "none")"] | join(" ")')
[ "$(wc -w <<<"$kept")" = 3 ] && ! grep -q '=keep' <<<"$kept"
check $? "the three SPIRE CRDs carry no helm.sh/resource-policy keep, so the uninstall of spire-crds removes them through Helm alone (the installer deletes CRDs itself only for istio-base)" "$kept"
sed -e "s/__DATA__/$DATA/g" -e "s/__MGMT__/$MGMT/g" fixtures/stand-ins.yaml | k delete -f - --wait=true >/dev/null 2>&1
"$INSTALL" uninstall >"$work/uninstall.log" 2>&1; rc=$?
check $rc "the installer uninstalls the seven releases in reverse order" "$(grep -c 'done$' "$work/uninstall.log") releases removed"
code "$(cat "$work/uninstall.log")"
for _ in $(seq 1 60); do k get ns "$MGMT" "$DATA" "$SPIRE_NS" "$ISTIO_NS" >/dev/null 2>&1 || break; sleep 3; done
left=$(k get ns "$MGMT" "$DATA" "$SPIRE_NS" "$ISTIO_NS" --ignore-not-found -o name 2>/dev/null)
[ -z "$left" ]; check $? "no plane namespace and no control-plane namespace remains" "${left:-none}"
left=$(k get crd -o name | grep -E 'spiffe\.io|istio\.io' || true)
[ -z "$left" ]; check $? "no SPIRE or Istio custom resource definition remains" "${left:-none}"
left=$(k get validatingwebhookconfiguration,mutatingwebhookconfiguration -o name | grep -E 'istio|spire' || true)
[ -z "$left" ]; check $? "no admission webhook of either control plane remains" "${left:-none}"
say "  the umbrella's release namespace \`ztd-system\` remains, as expected: the installer creates it and no release owns it" ''

# --------------------------------------------------------------------------------------------
say '' '## Result' ''
if [ "$failures" -eq 0 ]; then say 'All checks passed.'; else say "**$failures check(s) failed.**"; fi

# environment.json: what the run was made on.
ver() { "$@" 2>/dev/null | head -1; }
node_image=$(sed -n 's/^NODE_IMAGE=\${KIND_NODE_IMAGE:-\(.*\)}$/\1/p' "$REPO/scripts/dev/kind-cilium-up.sh")
host_kind="$(uname -s) $(uname -r)"
grep -qi microsoft /proc/version 2>/dev/null && host_kind="$host_kind (WSL)"
[ -r /etc/os-release ] && host_kind="$host_kind, $(. /etc/os-release && echo "$PRETTY_NAME")"
jq -n --arg commit "$commit" --argjson dirty "$dirty" --arg date "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg host "$host_kind" --arg context "$CONTEXT" --arg zone "${ZONE_VALUES#"$REPO"/}" --arg td "$TD" \
  --arg kind "$(ver kind version)" --arg kubectl "$(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion)" \
  --arg helm "$(ver helm version --short)" --arg istioctl "$(istioctl version --remote=false 2>/dev/null | sed 's/^client version: //' | head -1)" \
  --arg cilium "$(cilium version --client 2>/dev/null | head -1)" --arg server "$server" --arg cni "$cni" --arg nodeImage "$node_image" \
  --arg spire "$(sed -n 's/^SPIRE_VERSION=\([^ ]*\).*/\1/p' "$INSTALL")" --arg spireCrds "$(sed -n 's/^SPIRE_CRDS_VERSION=\(.*\)/\1/p' "$INSTALL")" \
  --arg istio "$(sed -n 's/^ISTIO_VERSION=\(.*\)/\1/p' "$INSTALL")" \
  --arg imgSpire "$images_spire" --arg imgIstio "$images_istio" --arg imgProxy "$images_proxy" \
  --argjson failures "$failures" '{
    commit: $commit, dirty: $dirty, date: $date, finished: $finished,
    host: { kind: $host },
    cluster: { context: $context, kubernetes: $server, kindNodeImage: $nodeImage, cni: $cni },
    zone: { file: $zone, trustDomain: $td },
    tools: { kind: $kind, kubectl: $kubectl, helm: $helm, istioctl: $istioctl, cilium: $cilium },
    charts: { "spire-crds": $spireCrds, spire: $spire, "istio-base": $istio, istiod: $istio, "istio-cni": $istio },
    images: { "spire-system": ($imgSpire | split(",")), "istio-system": ($imgIstio | split(",")), proxy: $imgProxy, cilium: $cni },
    result: { failures: $failures }
  }' >"$work/environment.json"

mkdir -p "$EVID"
cp "$OUT" "$EVID/evidence.md"
cp "$work/environment.json" "$EVID/environment.json"
echo "evidence written to ${EVID#"$REPO"/} ($failures failure(s))"
exit $(( failures > 0 ))
