# OSS dependencies and external references

Third-party components the demonstrator depends on, and the upstream projects it integrates with
but does not own.

## Licence compliance

Every dependency clears Eclipse Dash before it ships. The scan runs on every pull request and a
dependency Dash marks `restricted` blocks the merge; anything Dash cannot clear automatically goes
to the Eclipse IP team for review. See [CI/CD](ci-cd.md).

A dependency under a licence the project cannot accept is replaced, not waived. The exception below
is the only other route, and it is not a way to waive the rule.

Generated inventories — the CycloneDX SBOM and the Dash summary — are published with each release
and are the authoritative list. This page records the components chosen and why.

## Licence exceptions

When a component under a non-Apache-2.0-compatible licence is **prescribed by the requirements** and
therefore cannot be replaced, the Technical Development Requirements oblige us to inform the client
in writing *before* it is included. The merge stays blocked until the client's written decision
arrives.

A licence exception notice states:

- the component, its version and its licence;
- the requirement that prescribes it, and why no compliant alternative satisfies that requirement;
- how the component is consumed — a deployed service called through its API, or code linked into a
  deliverable — since that is what decides whether its obligations reach project code;
- the effect on the Apache-2.0 outbound licence of the demonstrator;
- the decision requested, and what happens if it is declined.

### Worked example — OpenBao

**Licence Exception Notice v1.0** (8 September 2026, submitted with Project Plan v1.7) covers
OpenBao, MPL-2.0, prescribed by ZT-11, and Grafana, AGPL-3.0, for optional internal use. OpenBao is
deployed as a cluster-internal service and consumed unmodified through its API, so its file-level
copyleft does not reach newly developed components, which stay Apache-2.0. The FACIS decision is
open and tracked as follow-up requirement F-07.

The reasoning, the consequences if the exception is declined, and the references are recorded in
[ADR-0004](adr/0004-openbao-as-x509-key-value-store.md).

## External XFSC components

The demonstrator integrates XFSC components rather than reimplementing them: the Trust Services API
for policy evaluation, the Organisation Credential Manager for wallets, TRAIN for trust anchoring,
and ORCE for orchestration. Versions are pinned at deployment and recorded with the release.

## Go dependencies

Direct dependencies of the Go module. Transitive dependencies are listed in the SBOM.

| Dependency | Version | Licence | Purpose |
|---|---|---|---|
| `authelia.com/provider/oauth2` | v0.3.2 | Apache-2.0 | OAuth 2.0 framework behind the connector's provider adapter: RFC 7591 client registration and RFC 9449 DPoP. Requires Go 1.27.x. |
| `golang.org/x/crypto` | v0.57.0 | BSD-3-Clause | bcrypt hashing of client secrets |

## Identity and service mesh

The identity path and the mesh ([Workload identity](workload-identity.md)) are installed from the
upstream charts as they ship, one Helm release per chart, by `scripts/install-zone/install.sh`,
which pins each by version and digest. The values the repository sets on them are listed with their
reasons in `deployment/helm/values/README.md`.

| Component | Version | Installed through | Licence | Why |
|---|---|---|---|---|
| SPIRE (server, agent, controller-manager, SPIFFE CSI driver) | v1.15.3 | chart `spire` 0.30.2 and chart `spire-crds` 0.6.1, from the SPIFFE hardened charts `https://spiffe.github.io/helm-charts-hardened/` | Apache-2.0 | the only issuer of workload and mesh identities (ZT-24): attests every pod and serves its SVID over the CSI-mounted Workload API socket and to the mesh proxy over SDS |
| Istio, sidecar mode | 1.31.1 | charts `base`, `istiod` and `cni` 1.31.1, from the Istio release archive `istio-1.31.1-linux-amd64.tar.gz` (`manifests/charts`), pinned by its published sha256 | Apache-2.0 | the service mesh of [ADR-0006](adr/0006-service-mesh-mode-istio-sidecar-with-cilium.md): native sidecars that take their certificates from SPIRE, mesh-wide STRICT mTLS, the CNI plugin chained behind Cilium |
| Cilium | 1.20.2 | chart `cilium/cilium`, by `scripts/dev/kind-cilium-up.sh` on kind; the zone's CNI elsewhere | Apache-2.0 | the CNI and the enforcer of the network policies, with `cni.exclusive=false` so that the Istio plugin can chain |
| istioctl | 1.31.1 | the operator's machine | Apache-2.0 | reads a proxy's secrets and sync status in the proof; never installs |

The Istio 1.31 charts are taken from the release archive because Istio's Helm repository and OCI
registry do not carry them (on 2026-10-06 the repository's index stopped at 1.31.0-rc.0); the
archive is the release Istio publishes, and its charts are the same charts.

**Upgrades.** An upgrade changes the pinned version and digest in the installer, then reruns
`scripts/verify-mesh-identity/verify.sh` and commits its evidence. The local proof runs on kind node
v1.35.5 with Cilium 1.20.2. At every Istio minor upgrade the
[ADR-0006](adr/0006-service-mesh-mode-istio-sidecar-with-cilium.md) reopen check
(`scripts/mesh-mode/check-upstream-state.sh`) runs alongside the proof. The SPIRE charts are
upgraded as a pair (`spire-crds` first), because the controller-manager in `spire` is built
against the CRDs of its `spire-crds`.
