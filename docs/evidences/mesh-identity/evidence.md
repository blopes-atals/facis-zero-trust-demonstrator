# Mesh identity evidence (2026-10-06T11:31:46Z)

Cluster context `kind-ztd`, zone file `deployment/helm/ztd/ci/values.yaml` (trust domain `kind.facis-ztd.local`), installed with `scripts/install-zone/install.sh`: the seven releases `ztd`, `spire-crds`, `spire`, `istio-base`, `istiod`, `istio-cni`, `zone-policy`. Commit `1ca87530a557ef4d01d25ba07e00d5c6684f2d73`, tree dirty: false. Versions in `environment.json`.

Probe results: an HTTP code with the first line of the body when the call went through its proxies; `denied(28)` when a raw TCP connection timed out because the policy dropped the packets; `denied(56)` when the peer reset the connection.


## 0. Preconditions

- PASS: the zone file records the server version the cluster runs
  server v1.35.5, recorded v1.35.5
- PASS: native-sidecar-version: the server is Kubernetes 1.33 or later (native sidecar containers)
  server v1.35.5
- PASS: Cilium is the CNI
  quay.io/cilium/cilium:v1.20.2@sha256:2939231d0d3e3ebddcd80fffa168b7ddcc78fdf0dc864d1c8c126ff523c54f01
- PASS: cni-exclusive=false (the Istio CNI plugin can chain)
  cni-exclusive=false
- PASS: the host allows 512 inotify instances (kind runs every node's agents on one kernel; the Istio CNI agent fails below)
  fs.inotify.max_user_instances=512

```
NAME STATUS ROLES AGE VERSION INTERNAL-IP EXTERNAL-IP OS-IMAGE KERNEL-VERSION CONTAINER-RUNTIME
ztd-control-plane Ready control-plane 161m v1.35.5 172.18.0.3 <none> Debian GNU/Linux 13 (trixie) 6.8.0-139-generic containerd://2.3.1
ztd-worker Ready <none> 161m v1.35.5 172.18.0.4 <none> Debian GNU/Linux 13 (trixie) 6.8.0-139-generic containerd://2.3.1
```


## 1. Clean slate

- PASS: no plane namespace and no control-plane namespace exists before the install
- PASS: no SPIRE or Istio custom resource definition exists before the install
  none

## 2. install-order-idempotent: the zone from an empty cluster, twice

- PASS: first installer run from an empty cluster returns 0, no manual step between the releases
  108s

```
  1/7  ztd          into ztd-system    chart deployment/helm/ztd values the zone file
  2/7  spire-crds   into spire-system  chart spire-crds 0.6.1 values deployment/helm/values/spire-crds.yaml
  3/7  spire        into spire-system  chart spire 0.30.2 values deployment/helm/values/spire.yaml + zone facts global.spire.trustDomain=zone.trustDomain global.spire.clusterName=zone.name global.spire.persistence.storageClass=zone.storageClass global.spire.caSubject.commonName=zone.trustDomain
  4/7  istio-base   into istio-system  chart base 1.31.1  values deployment/helm/values/istio-base.yaml
  5/7  istiod       into istio-system  chart istiod 1.31.1 values deployment/helm/values/istiod.yaml + zone facts meshConfig.trustDomain=zone.trustDomain
  6/7  istio-cni    into istio-system  chart cni 1.31.1   values deployment/helm/values/istio-cni.yaml
  7/7  zone-policy  into istio-system  chart deployment/helm/zone-policy values chart defaults + zone facts trustDomain=zone.trustDomain (wait-for-jobs)
step 1/7: ztd into ztd-system ...
step 1/7: ztd deployed, revision 1
step 2/7: spire-crds into spire-system ...
step 2/7: spire-crds deployed, revision 1
step 3/7: spire into spire-system ...
step 3/7: spire deployed, revision 1
step 4/7: istio-base into istio-system ...
step 4/7: istio-base deployed, revision 1
step 5/7: istiod into istio-system ...
step 5/7: istiod deployed, revision 1
step 6/7: istio-cni into istio-system ...
step 6/7: istio-cni deployed, revision 1
step 7/7: zone-policy into istio-system ...
step 7/7: zone-policy deployed, revision 1
zone installed: every pod in ztd-mgmt ztd-data spire-system istio-system is Ready
```

- PASS: second installer run returns 0
  56s; 7 releases upgraded in place
- PASS: helm get manifest of every release is identical between the two runs
  7 of 7 identical
- PASS: every pod in the plane and control-plane namespaces is Ready (the installer's exit condition)
  zone installed: every pod in ztd-mgmt ztd-data spire-system istio-system is Ready

```
RELEASE NAMESPACE REVISION STATUS CHART
cilium kube-system 1 deployed cilium-1.20.2
istio-base istio-system 2 deployed base-1.31.1
istio-cni istio-system 2 deployed cni-1.31.1
istiod istio-system 2 deployed istiod-1.31.1
spire spire-system 2 deployed spire-0.30.2
spire-crds spire-system 2 deployed spire-crds-0.6.1
zone-policy istio-system 2 deployed zone-policy-0.1.0
ztd ztd-system 2 deployed ztd-0.2.0
```


```
NAME READY STATUS RESTARTS AGE IP NODE NOMINATED NODE READINESS GATES
spire-agent-jh4m5 1/1 Running 0 2m30s 172.18.0.4 ztd-worker <none> <none>
spire-server-0 2/2 Running 0 2m29s 10.244.1.150 ztd-worker <none> <none>
spire-spiffe-csi-driver-b9mnh 2/2 Running 0 2m30s 10.244.1.248 ztd-worker <none> <none>

NAME READY STATUS RESTARTS AGE IP NODE NOMINATED NODE READINESS GATES
istio-cni-node-vrkc7 1/1 Running 0 78s 10.244.0.62 ztd-control-plane <none> <none>
istio-cni-node-vrlzb 1/1 Running 0 78s 10.244.1.86 ztd-worker <none> <none>
istiod-769f98b848-969k8 1/1 Running 0 86s 10.244.1.84 ztd-worker <none> <none>
```


## 3. The identity-band checks of zone-policy, and a failing step

- PASS: zone-policy is deployed: the server-healthy, trust-bundle-published and registrations-reconciled jobs (weights 20, 25, 30) passed
  deployed
- PASS: the identity-check jobs were removed by their hook delete policy
  none left
- PASS: the ClusterSPIFFEID is a regular resource of the release, not a hook
  ClusterSPIFFEIDs with a hook annotation: 0
- PASS: a release that does not reach a ready state within its timeout (here 1 s) stops the installer at that step, non-zero, naming the release
  step 1/7 FAILED: release ztd in ztd-system: helm did not reach a ready release and rolled it back
- PASS: the failed release was rolled back by the lifecycle step
  ztd: deployed, Rollback to 2

## 4. The layout of the control planes


```
NAME STATUS AGE PLANE ISTIO-INJECTION
ztd-mgmt Active 2m51s management enabled
ztd-data Active 2m51s data enabled
spire-system Active 2m51s management 
istio-system Active 2m51s management 
```

- PASS: spire-system is a management-plane namespace without the injection label
- PASS: istio-system is a management-plane namespace without the injection label

```
spire-system NetworkPolicy allow-dns-egress <none>
spire-system NetworkPolicy allow-intra-plane <none>
spire-system NetworkPolicy default-deny <none>
spire-system CiliumNetworkPolicy allow-control-plane-openings controlPlaneWebhooks,identityServer
spire-system CiliumNetworkPolicy allow-kube-api-egress kubeApi
istio-system NetworkPolicy allow-dns-egress <none>
istio-system NetworkPolicy allow-intra-plane <none>
istio-system NetworkPolicy allow-mesh-control-plane-ingress meshControlPlane
istio-system NetworkPolicy default-deny <none>
istio-system CiliumNetworkPolicy allow-control-plane-openings controlPlaneWebhooks
istio-system CiliumNetworkPolicy allow-kube-api-egress kubeApi
```

- PASS: spire-system holds only the default deny, the DNS bypass, the intra-plane lane, the API lane and the entity-sourced openings (webhook, agents)
  allow-control-plane-openings allow-dns-egress allow-intra-plane allow-kube-api-egress default-deny
- PASS: istio-system holds only the default deny, the DNS bypass, the intra-plane lane, the API lane, the webhook opening and the sidecars' xDS opening
  allow-control-plane-openings allow-dns-egress allow-intra-plane allow-kube-api-egress allow-mesh-control-plane-ingress default-deny
- PASS: no SPIRE pod has an istio-proxy container
  none
- PASS: every SPIRE agent is attested by the server (through the identityServer opening)
  agents Ready 1, attested 1
- PASS: the SPIRE server and the mesh run with the zone's trust domain
  SPIRE kind.facis-ztd.local, mesh kind.facis-ztd.local, zone file kind.facis-ztd.local

## 5. Stand-in pods

From `scripts/verify-mesh-identity/fixtures/stand-ins.yaml`: in the data plane a meshed peer, a labelled caller with a Workload API client on the CSI socket, an unlabelled meshed pod, an unlabelled pod without proxy with a Workload API client, the matrix pair `pdp-adapter` and the cross-plane caller `data-plain`; in the management plane `tsa-policy-engine`, `openbao` and `mgmt-caller`; in both a proxy-less `probe` for raw TCP probes. All in the service account `stand-in` unless noted.

- PASS: the labelled data-plane stand-ins are Ready
- PASS: the management-plane stand-ins are Ready

```
NAME READY STATUS RESTARTS AGE IP NODE NOMINATED NODE READINESS GATES
caller 3/3 Running 0 19s 10.244.1.222 ztd-worker <none> <none>
data-plain 2/2 Running 0 19s 10.244.1.66 ztd-worker <none> <none>
pdp-adapter 2/2 Running 0 19s 10.244.1.39 ztd-worker <none> <none>
peer 2/2 Running 0 19s 10.244.1.252 ztd-worker <none> <none>
probe 1/1 Running 0 19s 10.244.1.250 ztd-worker <none> <none>
unregistered 0/2 Init:1/2 0 19s 10.244.1.77 ztd-worker <none> <none>
unregistered-svid 1/1 Running 0 19s 10.244.1.47 ztd-worker <none> <none>

NAME READY STATUS RESTARTS AGE IP NODE NOMINATED NODE READINESS GATES
mgmt-caller 2/2 Running 0 19s 10.244.1.123 ztd-worker <none> <none>
openbao 2/2 Running 0 19s 10.244.1.51 ztd-worker <none> <none>
probe 1/1 Running 0 19s 10.244.1.79 ztd-worker <none> <none>
tsa-policy-engine 2/2 Running 0 19s 10.244.1.146 ztd-worker <none> <none>
```


## 6. svid-over-csi-socket

- PASS: the labelled pod mounts the csi.spiffe.io volume
  volumes: workload-socket,spiffe-workload-api (one for the Workload API client, one for the proxy)
- PASS: the SVID fetched over the mounted socket carries the SPIFFE ID of the pod's service account in the zone's trust domain
  spiffe://kind.facis-ztd.local/ns/ztd-data/sa/stand-in
- PASS: the SVID chains to the SPIRE server's CA (the bundle read from the server)
  issuer=serialNumber=20567247923986071622870146082131025447,CN=kind.facis-ztd.local,O=FACIS ZTD,C=ARPA; SPIRE CA subject=serialNumber=20567247923986071622870146082131025447,CN=kind.facis-ztd.local,O=FACIS ZTD,C=ARPA

```
subject=O=SPIRE,C=US
issuer=serialNumber=20567247923986071622870146082131025447,CN=kind.facis-ztd.local,O=FACIS ZTD,C=ARPA
notBefore=Oct  6 11:34:40 2026 GMT
notAfter=Oct  6 15:34:50 2026 GMT
X509v3 Subject Alternative Name: 
    URI:spiffe://kind.facis-ztd.local/ns/ztd-data/sa/stand-in
```

- PASS: the SPIRE server lists an entry for the labelled pod, created from the ClusterSPIFFEID
  spiffe://kind.facis-ztd.local/ns/ztd-data/sa/stand-in
- PASS: the SPIRE server lists no entry for the two unlabelled pods
- PASS: an unlabelled pod's fetch over the mounted socket returns no SVID
  rpc error: code = PermissionDenied desc = no identity issued
  ClusterSPIFFEID `plane-workloads` status: `{"entriesMasked":0,"entriesToSet":7,"entryFailures":0,"namespacesIgnored":0,"namespacesSelected":4,"podEntryRenderFailures":0,"podsSelected":7}`

## 7. native-sidecar-version

- PASS: istio-proxy is an init container with restartPolicy Always (a native sidecar), not a regular container
  istio-validation(restartPolicy=-), istio-proxy(restartPolicy=Always)
- PASS: the meshed pod is Ready

## 8. mesh-identity-issued-by-spire


```
RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER                        NOT AFTER                NOT BEFORE               TRUST DOMAIN
default           Cert Chain     ACTIVE     true           77eb06a083b046a102da926cef51af25     2026-10-06T15:34:50Z     2026-10-06T11:34:40Z     kind.facis-ztd.local
ROOTCA            CA             ACTIVE     true           0f791b9d0b24c916af38bfe225761e27     2026-10-07T11:32:14Z     2026-10-06T11:32:04Z     kind.facis-ztd.local
```

- PASS: the proxy's workload certificate (default) has O = SPIRE in its subject
  subject=O=SPIRE,C=US
- PASS: its issuer is the SPIRE server CA and it chains to SPIRE's bundle
  issuer=serialNumber=20567247923986071622870146082131025447,CN=kind.facis-ztd.local,O=FACIS ZTD,C=ARPA
- PASS: its URI SAN equals the SVID fetched over the socket
  spiffe://kind.facis-ztd.local/ns/ztd-data/sa/stand-in
- PASS: the proxy holds a root bundle under ROOTCA, and it is the SPIRE server's CA
  ROOTCA (SPIFFE validator, trust domains: kind.facis-ztd.local) CC:80:DE:39:64:98:2C:D2:F8:76:36:5C:29:34:62:2F:86:38:78:E1:B4:F6:48:E9:98:4A:4D:79:6E:85:1F:EC, SPIRE CA CC:80:DE:39:64:98:2C:D2:F8:76:36:5C:29:34:62:2F:86:38:78:E1:B4:F6:48:E9:98:4A:4D:79:6E:85:1F:EC
- PASS: the ROOTCA bundle trusts the zone's trust domain and no other
  kind.facis-ztd.local
- PASS: istiod's own CA did not issue it (istiod's root is a certificate, and the leaf does not verify against it)
  istiod root subject=O=kind.facis-ztd.local

## 9. unregistered-workload-cut-off

- PASS: the unlabelled pod's proxy holds no workload certificate: it asked for 'default' and was never served
  active secrets ["ROOTCA"], still warming ["default"]
- PASS: the SPIRE agent refuses its proxy over SDS
  workload is not authorized for the requested identities ["default"]
- PASS: its application container never starts: the native sidecar holds it until the proxy has a certificate
  {"waiting":{"reason":"PodInitializing"}}
- PASS: a call from its network namespace to the meshed peer is refused: the peer accepts mTLS only (STRICT)
  → denied(56)
- PASS: the labelled pod's call to the same peer succeeds
  → 200 peer

## 10. traffic-through-the-proxies

- PASS: the peer sees the caller's SPIFFE identity in X-Forwarded-Client-Cert
  By=spiffe://kind.facis-ztd.local/ns/ztd-data/sa/stand-in;Hash=f9fed810800a66e40726bc62ff613e95d4e4f3f215939c47d08feb2140c22086;Subject="O=SPIRE,C=US";URI=spiffe://kind.facis-ztd.local/ns/ztd-data/sa/stand-in
- PASS: both proxies counted the request (istio_requests_total)
  caller (reporter=source) 1 → 2, peer (reporter=destination) 1 → 2
- PASS: the peer's proxy records the requests as mutual_tls

## 11. default-deny-with-chained-cni

- PASS: the CNI configuration of node ztd-control-plane lists the Istio plugin after Cilium
  /etc/cni/net.d/05-cilium.conflist: cilium-cni → istio-cni
- PASS: the CNI configuration of node ztd-worker lists the Istio plugin after Cilium
  /etc/cni/net.d/05-cilium.conflist: cilium-cni → istio-cni
- PASS: Cilium still runs with cni-exclusive=false
  cni-exclusive=false
- PASS: data-plane pod → openbao (management): DENIED at the network layer with the proxies in place
  → denied(28)
- PASS: data-plane pod → tsa-policy-engine (management): DENIED
  → denied(28)
- PASS: pdp-adapter → tsa-policy-engine: ALLOWED (matrix lane pdp-adapter-to-tsa), through the proxies
  → 200 tsa-policy-engine
- PASS: pdp-adapter → openbao: DENIED (a lane is one pair, not a licence)
  → denied(28)
- PASS: management pod → data plane: DENIED (the default deny is both directions)
  → denied(28)
- PASS: DNS bypass: names still resolve
  Name:	openbao.ztd-mgmt.svc.cluster.local Address: 10.96.87.82 

## 12. control-planes-under-default-deny

- PASS: the registered proxies reach istiod through the meshControlPlane opening and report SYNCED for every xDS type
  proxies 4, not SYNCED: none
- PASS: the API server reaches istiod's injection webhook (15017) through the controlPlaneWebhooks opening: a dry-run pod in ztd-data is injected
  containers: istio-validation,istio-proxy,webhook-probe
- PASS: the API server reaches the controller-manager's webhook (9443) through the controlPlaneWebhooks opening: it refuses a ClusterSPIFFEID with a broken template
  Error from server (Forbidden): error when creating "STDIN": admission webhook "vclusterspiffeid.kb.io" denied the request: invalid SPIFFEID template: template: spiffeIDTemplate:1: unclosed action

Raw TCP probes from the proxy-less `probe` pods to the SPIRE server (10.244.1.150) and istiod (10.244.1.84), on every port they listen on:

- PASS: ztd-data → SPIRE server :8081 DENIED
  → denied(28)
- PASS: ztd-data → SPIRE server :8080 DENIED
  → denied(28)
- PASS: ztd-data → SPIRE server :9443 DENIED
  → denied(28)
- PASS: ztd-data → SPIRE server :9988 DENIED
  → denied(28)
- PASS: ztd-data → SPIRE server :8082 DENIED
  → denied(28)
- PASS: ztd-data → SPIRE server :8083 DENIED
  → denied(28)
- PASS: ztd-data → istiod :15017 DENIED
  → denied(28)
- PASS: ztd-data → istiod :15014 DENIED
  → denied(28)
- PASS: ztd-data → istiod :15010 DENIED
  → denied(28)
- PASS: ztd-data → istiod :8080 DENIED
  → denied(28)
- PASS: ztd-data → istiod :15012 (xDS) reachable: the declared meshControlPlane opening
  → connected
- PASS: ztd-mgmt → SPIRE server :8081 DENIED
  → denied(28)
- PASS: ztd-mgmt → SPIRE server :8080 DENIED
  → denied(28)
- PASS: ztd-mgmt → SPIRE server :9443 DENIED
  → denied(28)
- PASS: ztd-mgmt → SPIRE server :9988 DENIED
  → denied(28)
- PASS: ztd-mgmt → SPIRE server :8082 DENIED
  → denied(28)
- PASS: ztd-mgmt → SPIRE server :8083 DENIED
  → denied(28)
- PASS: ztd-mgmt → istiod :15017 DENIED
  → denied(28)
- PASS: ztd-mgmt → istiod :15014 DENIED
  → denied(28)
- PASS: ztd-mgmt → istiod :15010 DENIED
  → denied(28)
- PASS: ztd-mgmt → istiod :8080 DENIED
  → denied(28)
- PASS: ztd-mgmt → istiod :15012 (xDS) reachable: the declared meshControlPlane opening
  → connected

## 13. A declared registration without its entry fails the release

The registrations-reconciled check counts the running labelled pods of every plane namespace and compares them with what the controller-manager reconciled. To make one registration go unreconciled, the kind namespace `local-path-storage`, which the controller-manager is configured to ignore, is labelled as a plane for the duration of the step and gets a labelled pod; then zone-policy is upgraded through the lifecycle step with a 20 s check timeout. Afterwards the label and the pod are removed and the rollback restores the release.

- PASS: the upgrade fails and is rolled back
  helm did not reach a ready release and rolled it back
- PASS: the registrations-reconciled job exits non-zero naming the gap
  FAIL every registration the zone declares exists as an entry on the server (after 20s): labelled running pods 8, selected 7, entries to set 7, masked 0, entry failures 0, render failures 0 
- PASS: after the step the release is deployed again (rollback)
  2 superseded, 3 failed, 4 deployed

## 14. Render guards (no cluster)

- PASS: the spire release does not render without the trust domain
  install-zone: release spire: the zone file /tmp/tmp.I1bFLmrPMb/no-td.yaml does not state the zone fact zone.trustDomain (for global.spire.trustDomain), zone.trustDomain (for global.spire.caSubject.commonName)
- PASS: the istiod release does not render without the trust domain
  install-zone: release istiod: the zone file /tmp/tmp.I1bFLmrPMb/no-td.yaml does not state the zone fact zone.trustDomain (for meshConfig.trustDomain)
- PASS: the umbrella refuses a meshed zone without a trust domain, on the schema
  at '/zone/trustDomain': minLength: got 0, want 1
- PASS: the umbrella renders zones/ionos.yaml (mesh none) without a trust domain
- PASS: the umbrella refuses sidecar mode below Kubernetes 1.33
  mesh.mode sidecar needs native sidecar containers, which need Kubernetes 1.33 or later; zone.kubernetesVersion is v1.32.0
- PASS: the umbrella refuses a meshed zone without Cilium, naming the openings and the derogation
  mesh.mode sidecar needs Cilium (cni.cilium.enabled)

## 15. Teardown: uninstall in reverse order

- PASS: the three SPIRE CRDs carry no helm.sh/resource-policy keep, so the uninstall of spire-crds removes them through Helm alone (the installer deletes CRDs itself only for istio-base)
  clusterfederatedtrustdomains.spire.spiffe.io=none clusterspiffeids.spire.spiffe.io=none clusterstaticentries.spire.spiffe.io=none
- PASS: the installer uninstalls the seven releases in reverse order
  7 releases removed

```
uninstall zone-policy: done
uninstall istio-cni: done
uninstall istiod: done
uninstall istio-base: done
uninstall spire: done
uninstall spire-crds: done
uninstall ztd: done
```

- PASS: no plane namespace and no control-plane namespace remains
  none
- PASS: no SPIRE or Istio custom resource definition remains
  none
- PASS: no admission webhook of either control plane remains
  none
  the umbrella's release namespace `ztd-system` remains, as expected: the installer creates it and no release owns it


## Result

All checks passed.
