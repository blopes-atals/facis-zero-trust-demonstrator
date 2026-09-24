# Architecture

## 6. Plane separation and staleness windows

### Trust boundaries (diagram 03)

Each trust zone is its own SPIFFE trust domain. The two domains meet only through the attested
channel and a TRAIN verdict; they are never merged. Data-plane calls into the management plane are
denied by default, and a workload without an SVID or running an unsigned image cannot join or
start.

![Trust boundaries](diagrams/03-trust-boundaries.svg)

Source: [`diagrams/03-trust-boundaries.mmd`](diagrams/03-trust-boundaries.mmd).

### Management-plane roles (ZT-55)

ZT-55 (SRS 3.3) names five management-plane components that must not be reachable from the data
plane. The table binds each of them, in the order the requirement names them, to the service or
services that implement it in this demonstrator. The allow matrix below refers to these roles by
name, so coverage of the five components can be checked here before the permitted paths are read.

Every role in the table below is bound to at least one service; none is unimplemented.

The supply boundary records who provides a service, not where it runs. *Internally operated* means
this project deploys and operates the service; *externally supplied* means it is provided to the
demonstrator by the XFSC stack. The distinction matters because the project can apply both
enforcement layers on its own side of an externally supplied service, but not inside it.

| ZT-55 role | Implementing service(s) | Supply boundary | Evidence |
|---|---|---|---|
| Policy Engine | TSA policy engine (Trust Services API) | Externally supplied | [External XFSC components](dependencies.md#external-xfsc-components) |
| TRAIN | TCR (trust-list resolution); TSPA (trust-list publication) | Externally supplied | [External XFSC components](dependencies.md#external-xfsc-components); [TSPA in the ZT-35 flow](tspa-publish-api.md#3-what-tspa-is-in-the-zt-35-flow) |
| SPIRE control plane | SPIRE server and its controller-manager | Internally operated | [Workload identity](environments/osc.md#2-workload-identity) |
| OCM | OCM W-Stack, used by the backend as the credential verification service | Externally supplied | [External XFSC components](dependencies.md#external-xfsc-components) |
| Observability stack | OpenTelemetry Collector, read through Prometheus and Jaeger | Internally operated | [Operations](environments/osc.md#operations) |

### Allow matrix (data plane → management plane)

Default DENY at both layers (NetworkPolicy and mesh AuthorizationPolicy). These are the only
permitted paths. The ZT-55 role column names the management-plane role from the table above that
the destination serves. A destination outside the five roles is denied by the catch-all row
unless it has its own ALLOW row. Three such explicit exceptions exist; each is marked *exception*
in the role column with the supporting service it provides, and is justified under
[Explicit exceptions](#explicit-exceptions) below the matrix.

| From data-plane workload → | ZT-55 role | Allowed? | Path/layer that enforces |
|---|---|---|---|
| PDP adapter → TSA policy engine | Policy Engine | ALLOW (mTLS, named pair) | mesh policy |
| aTLS gateway → TCR resolve | TRAIN (resolution) | ALLOW (named pair) | mesh policy |
| aTLS gateway → cmcd | exception: attestation for the aTLS channel | ALLOW (named pair) | mesh policy |
| workloads → OTel collector (export only) | Observability stack | ALLOW (declared bypass, ZT-26) | mesh policy, egress-restricted |
| workloads → DNS | exception: name-resolution infrastructure | ALLOW (declared bypass) | NetworkPolicy port 53 |
| backend → verification service | OCM | ALLOW (named pair) | mesh policy |
| backend → Keycloak token endpoint | exception: identity and token issuance | ALLOW (named pair) | mesh policy |
| any data-plane workload → TSPA (trust-list publication) | TRAIN (publication) | **DENY** | both layers; ZT-55 matrix test |
| any data-plane workload → SPIRE server | SPIRE control plane | **DENY** | both layers; ZT-55 matrix test |
| anything else data → management, outside the five ZT-55 roles (for example ArgoCD, OpenBao, Harbor, estserver, admin APIs) | outside the five roles | **DENY** | both layers; ZT-55 matrix test |

The two TRAIN rows carry opposite verdicts on purpose. ZT-35 (SRS 3.1.3) requires any endpoint
that establishes attested TLS connections to *resolve* its peers' trusted hashes from TRAIN, so
the aTLS gateway needs a read path to TCR at run time. The same requirement assigns *publication*
to the endpoint's CI/CD pipeline, which uploads the hash on deployment; no data-plane workload
publishes. Publication writes the trust anchors that every peer relies on, so leaving it reachable
from the data plane would let a compromised data-plane workload alter trust decisions, which
ZT-55 forbids. Publication therefore stays denied from the data plane and is reached only through
the pipeline's dedicated control channel.

#### Explicit exceptions

Three permitted destinations are not one of the five ZT-55 roles. Each is a supporting service
that a named data-plane path depends on, and each is allowed only by its own row; every other
destination outside the five roles falls to the catch-all denial.

- **aTLS gateway → cmcd — attestation for the aTLS channel.** The attested channel between the
  zones requires both ends to present evidence of the software they run, bound to the TLS
  connection it is presented on ([trust boundary between the zones](environments/osc.md#6-the-trust-boundary-between-the-zones)).
  That evidence comes from CMC (ZT-31, ZT-71; [specifications](specifications.md)), and cmcd is
  the per-zone CMC service that receives the pipeline-signed reference metadata the evidence is
  checked against. Without this path the gateway cannot establish attested TLS as ZT-35
  (SRS 3.1.3) requires.
- **workloads → DNS — name-resolution infrastructure.** Data-plane workloads reach the
  destinations permitted above by service name, so without name resolution none of those paths
  can be used. The exception is a declared bypass limited to port 53 at the NetworkPolicy layer.
- **backend → Keycloak token endpoint — identity and token issuance.** Keycloak is the
  demonstrator's identity provider (ZT-21, ZT-22; [Keycloak integration](keycloak.md)), and its
  token endpoint is where tokens from that provider are issued. The path is limited to the token
  endpoint for the backend as a named pair.

### Staleness matrix

Maximum window in which a revoked or rotated artefact still authorises. All values are proposed.

| Artefact | Rotation/lifetime | Cache | Max stale-authorisation window |
|---|---|---|---|
| SVID | 1 h TTL | in-process | ≤ 1 h (mesh) |
| Keycloak/issuer JWKS | rotate on demand | guard cache 5 min | ≤ 5 min |
| Access token | 300 s lifetime | — | ≤ 300 s after revocation of its basis |
| Policy bundle | poll 60 s | TSA cache | ≤ 60 s |
| Trust list / measurement | TTL 300 s | TCR/gateway | ≤ 300 s + channel lifetime 15 min ⇒ ≤ ~20 min for an established channel (bounded by channel re-establishment) |
| Credential revocation | checked per verification | outcome TTL 120 s | ≤ renewal interval (≤ token lifetime 300 s) + 120 s |
