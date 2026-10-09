# Mesh identity evidence (2026-10-09T09:08:49Z)

Cluster context `kind-ztd-tls13`, zone file `deployment/helm/ztd/ci/values.yaml` (trust domain `kind.facis-ztd.local`), installed with `scripts/install-zone/install.sh`: the seven releases `ztd`, `spire-crds`, `spire`, `istio-base`, `istiod`, `istio-cni`, `zone-policy`. Commit `f8647121efe4d96a3989b2219097bbb972245172`, tree dirty: false. Versions in `environment.json`.

Probe results: an HTTP code with the first line of the body when the call went through its proxies; `denied(28)` when a raw TCP connection timed out because the policy dropped the packets; `denied(56)` when the peer reset the connection; `error(<exit>)`, which fails a negative check, for any other failure (a name that does not resolve, an exec that failed).


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
ztd-tls13-control-plane Ready control-plane 104s v1.35.5 172.18.0.6 <none> Debian GNU/Linux 13 (trixie) 6.8.0-146-generic containerd://2.3.1
ztd-tls13-worker Ready <none> 89s v1.35.5 172.18.0.5 <none> Debian GNU/Linux 13 (trixie) 6.8.0-146-generic containerd://2.3.1
```


## 1. Clean slate

- PASS: no plane namespace and no control-plane namespace exists before the install
- PASS: no SPIRE or Istio custom resource definition exists before the install
  none

## 2. install-order-idempotent: the zone from an empty cluster, twice

- PASS: first installer run from an empty cluster returns 0, no manual step between the releases
  182s

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
  76s; 7 releases upgraded in place
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

- PASS: every image the SPIRE and Istio pods run (containers and init containers) is pinned by digest
  9 images; not pinned: none

```
NAME READY STATUS RESTARTS AGE IP NODE NOMINATED NODE READINESS GATES
spire-agent-lffqz 1/1 Running 0 3m54s 172.18.0.5 ztd-tls13-worker <none> <none>
spire-server-0 2/2 Running 0 3m54s 10.244.1.151 ztd-tls13-worker <none> <none>
spire-spiffe-csi-driver-6bcv7 2/2 Running 0 3m54s 10.244.1.190 ztd-tls13-worker <none> <none>

NAME READY STATUS RESTARTS AGE IP NODE NOMINATED NODE READINESS GATES
istio-cni-node-57qwd 1/1 Running 0 114s 10.244.1.199 ztd-tls13-worker <none> <none>
istio-cni-node-rqdcp 1/1 Running 0 114s 10.244.0.203 ztd-tls13-control-plane <none> <none>
istiod-84f7f755d9-t4kn7 1/1 Running 0 2m17s 10.244.1.212 ztd-tls13-worker <none> <none>
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
ztd-mgmt Active 4m28s management enabled
ztd-data Active 4m28s data enabled
spire-system Active 4m28s management 
istio-system Active 4m28s management 
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
caller 3/3 Running 0 31s 10.244.1.120 ztd-tls13-worker <none> <none>
data-plain 2/2 Running 0 30s 10.244.1.134 ztd-tls13-worker <none> <none>
pdp-adapter 2/2 Running 0 30s 10.244.1.66 ztd-tls13-worker <none> <none>
peer 2/2 Running 0 31s 10.244.1.166 ztd-tls13-worker <none> <none>
probe 1/1 Running 0 31s 10.244.1.235 ztd-tls13-worker <none> <none>
unregistered 0/2 Init:1/2 0 31s 10.244.1.168 ztd-tls13-worker <none> <none>
unregistered-svid 1/1 Running 0 31s 10.244.1.157 ztd-tls13-worker <none> <none>

NAME READY STATUS RESTARTS AGE IP NODE NOMINATED NODE READINESS GATES
mgmt-caller 2/2 Running 0 30s 10.244.1.112 ztd-tls13-worker <none> <none>
openbao 2/2 Running 0 30s 10.244.1.198 ztd-tls13-worker <none> <none>
probe 1/1 Running 0 30s 10.244.1.164 ztd-tls13-worker <none> <none>
tsa-policy-engine 2/2 Running 0 30s 10.244.1.174 ztd-tls13-worker <none> <none>
```


## 6. svid-over-csi-socket

- PASS: the labelled pod mounts the csi.spiffe.io volume
  volumes: workload-socket,spiffe-workload-api (one for the Workload API client, one for the proxy)
- PASS: the SVID fetched over the mounted socket carries the SPIFFE ID of the pod's service account in the zone's trust domain
  spiffe://kind.facis-ztd.local/ns/ztd-data/sa/stand-in
- PASS: the SVID chains to the SPIRE server's CA (the bundle read from the server)
  issuer=serialNumber=242525115579297786951446278860186383165,CN=kind.facis-ztd.local,O=FACIS ZTD,C=ARPA; SPIRE CA subject=serialNumber=242525115579297786951446278860186383165,CN=kind.facis-ztd.local,O=FACIS ZTD,C=ARPA

```
subject=O=SPIRE,C=US
issuer=serialNumber=242525115579297786951446278860186383165,CN=kind.facis-ztd.local,O=FACIS ZTD,C=ARPA
notBefore=Oct  9 09:13:23 2026 GMT
notAfter=Oct  9 13:13:33 2026 GMT
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
- PASS: the injected proxy's image is pinned by digest
  docker.io/istio/proxyv2:1.31.1@sha256:d86cba0dd1eb15c00b6901c69ce5ae3d2d5f8427a47751098cf8c3ab2a4a62e9
- PASS: the injected init containers (istio-validation) are pinned by digest
  istio-validation=docker.io/istio/proxyv2:1.31.1@sha256:d86cba0dd1eb15c00b6901c69ce5ae3d2d5f8427a47751098cf8c3ab2a4a62e9

## 8. mesh-identity-issued-by-spire


```
RESOURCE NAME     TYPE           STATUS     VALID CERT     SERIAL NUMBER                        NOT AFTER                NOT BEFORE               TRUST DOMAIN
default           Cert Chain     ACTIVE     true           a49fa60d1f7ed1ac59814649f4a6d3d6     2026-10-09T13:13:33Z     2026-10-09T09:13:23Z     kind.facis-ztd.local
ROOTCA            CA             ACTIVE     true           b674a3636f7960f2f9387977e0e8f33d     2026-10-10T09:09:36Z     2026-10-09T09:09:26Z     kind.facis-ztd.local
```

- PASS: the proxy's workload certificate (default) has O = SPIRE in its subject
  subject=O=SPIRE,C=US
- PASS: its issuer is the SPIRE server CA and it chains to SPIRE's bundle
  issuer=serialNumber=242525115579297786951446278860186383165,CN=kind.facis-ztd.local,O=FACIS ZTD,C=ARPA
- PASS: its URI SAN equals the SVID fetched over the socket
  spiffe://kind.facis-ztd.local/ns/ztd-data/sa/stand-in
- PASS: the proxy holds a root bundle under ROOTCA, and it is the SPIRE server's CA
  ROOTCA (SPIFFE validator, trust domains: kind.facis-ztd.local) DC:EF:5D:70:08:74:82:6F:38:16:5F:86:D3:DC:A2:8A:B4:55:B0:DD:5E:E7:B9:0B:61:1F:74:B6:33:BA:5E:8C, SPIRE CA DC:EF:5D:70:08:74:82:6F:38:16:5F:86:D3:DC:A2:8A:B4:55:B0:DD:5E:E7:B9:0B:61:1F:74:B6:33:BA:5E:8C
- PASS: the ROOTCA bundle trusts the zone's trust domain and no other
  kind.facis-ztd.local
- PASS: istiod's own CA did not issue it (istiod's root is a certificate, and the leaf does not verify against it)
  istiod root subject=O=kind.facis-ztd.local

istiod's CA stays on, because it also signs istiod's own serving certificates. A proxy that found no SPIRE socket would ask it for a certificate; the admission policy `proxy-takes-spire-socket` of zone-policy keeps such a proxy out of the plane namespaces. Server-side dry runs, which persist nothing:

- PASS: a pod that chooses its injection templates (inject.istio.io/templates: sidecar, which drops the SPIRE socket) is refused at admission
  denied request: a pod in a plane namespace may not choose its injection templates (inject.istio.io/templates): every injection is the sidecar template with the SPIRE socket
- PASS: a pod that brings its own istio-proxy without the csi.spiffe.io socket is refused at admission
  denied request: a mesh proxy in a plane namespace must take its certificate from SPIRE: every container named istio-proxy, running the proxyv2 image or naming pilot-agent must mount the csi.spiffe.io volume workload-sock
- PASS: a pod that runs Istio's agent itself (proxyv2, proxy sidecar) under another container name, with its own istio-token volume and no injection, is refused at admission
  denied request: a mesh proxy in a plane namespace must take its certificate from SPIRE: every container named istio-proxy, running the proxyv2 image or naming pilot-agent must mount the csi.spiffe.io volume workload-sock
- PASS: an ordinary pod in the same namespace is admitted, its proxy on the SPIRE socket

Outside the plane namespaces the policy does not apply, and istiod's injector still injects a pod labelled `sidecar.istio.io/inject: "true"` with the templates it names. A pod in a scratch namespace without the plane label:

- PASS: there it is admitted with a proxy and no SPIRE socket: that proxy would ask istiod's CA
  containers: istio-validation,istio-proxy,outside
- PASS: but istiod's CA (15012) is not reachable from a namespace without the plane label: the meshControlPlane opening admits the plane namespaces only
  → denied(28)

What no admission rule can close is a program that is not a mesh proxy by any of the policy's marks and calls istiod's CA on 15012 from a plane namespace itself. The guarantee against it is that no peer trusts istiod's CA. A certificate for the labelled caller's own SPIFFE ID, signed with istiod's CA key (read from `istio-ca-secret`, the key istiod signs every certificate with), is presented to the meshed peer's proxy from the proxy-less `probe` pod, next to the caller's SPIRE SVID:

- PASS: the certificate verifies against istiod's root (istio-ca-root-cert) and carries the caller's SPIFFE ID
  spiffe://kind.facis-ztd.local/ns/ztd-data/sa/stand-in, issuer=O=kind.facis-ztd.local
- PASS: with the caller's SPIRE SVID the peer's proxy completes the handshake and the request succeeds
  → peer 200 
- PASS: with the istiod-signed certificate for the same SPIFFE ID the peer's proxy refuses the handshake: its ROOTCA is SPIRE's bundle only
  → curl: (56) OpenSSL SSL_read: OpenSSL/3.3.2: error:0A000416:SSL routines::ssl/tls alert certificate unknown, errno 0

The security baseline sets TLS 1.3 as the minimum (ADR 005), and the `istiod` release raises the mesh mTLS minimum to it (`meshConfig.meshMTLS.minProtocolVersion: TLSV1_3`; Istio's default is TLS 1.2). The same SVID, once at TLS 1.3 and once with TLS 1.2 as the highest version offered:

- PASS: at TLS 1.3 with the caller's SPIRE SVID the peer's proxy completes the handshake and the request succeeds
  → peer 200 
- PASS: capped at TLS 1.2 with the same SVID the peer's proxy refuses the handshake with a protocol alert: the mesh mTLS minimum is TLS 1.3
  → curl: (35) OpenSSL/3.3.2: error:0A00042E:SSL routines::tlsv1 alert protocol version

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
  By=spiffe://kind.facis-ztd.local/ns/ztd-data/sa/stand-in;Hash=37023ea0051a7b0b20f1f83e29ac207c4cfdb28c5146d5bb3c1cb7ff31f4e4b2;Subject="O=SPIRE,C=US";URI=spiffe://kind.facis-ztd.local/ns/ztd-data/sa/stand-in
- PASS: both proxies counted the request (istio_requests_total)
  caller (reporter=source) 1 → 2, peer (reporter=destination) 3 → 4
- PASS: the peer's proxy records the requests as mutual_tls

## 11. default-deny-with-chained-cni

- PASS: the CNI configuration of node ztd-tls13-worker lists the Istio plugin after Cilium
  /etc/cni/net.d/05-cilium.conflist: cilium-cni → istio-cni
- PASS: the CNI configuration of node ztd-tls13-control-plane lists the Istio plugin after Cilium
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
  Name:	openbao.ztd-mgmt.svc.cluster.local Address: 10.96.164.62 

## 12. control-planes-under-default-deny

- PASS: the registered proxies reach istiod through the meshControlPlane opening and report SYNCED for every xDS type
  proxies 4, not SYNCED: none
- PASS: the API server reaches istiod's injection webhook (15017) through the controlPlaneWebhooks opening: a dry-run pod in ztd-data is injected
  containers: istio-validation,istio-proxy,webhook-probe
- PASS: the API server reaches the controller-manager's webhook (9443) through the controlPlaneWebhooks opening: it refuses a ClusterSPIFFEID with a broken template
  Error from server (Forbidden): error when creating "STDIN": admission webhook "vclusterspiffeid.kb.io" denied the request: invalid SPIFFEID template: template: spiffeIDTemplate:1: unclosed action

Raw TCP probes from the proxy-less `probe` pods to the SPIRE server (10.244.1.151) and istiod (10.244.1.212), on every port they listen on:

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
- PASS: node ztd-tls13-worker: the SPIRE agent's metrics port 9988 listens on the loopback only, not on the node's addresses
  listening (hex address:port): 0100007F:2704 
- PASS: node ztd-tls13-worker: the agent's metrics answer on 127.0.0.1:9988 (the contract with a node-local collector)
  105 spire_agent samples

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
  install-zone: release spire: the zone file /tmp/tmp.SCav6ztwNq/no-td.yaml does not state the zone fact zone.trustDomain (for global.spire.trustDomain), zone.trustDomain (for global.spire.caSubject.commonName)
- PASS: the istiod release does not render without the trust domain
  install-zone: release istiod: the zone file /tmp/tmp.SCav6ztwNq/no-td.yaml does not state the zone fact zone.trustDomain (for meshConfig.trustDomain)
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
