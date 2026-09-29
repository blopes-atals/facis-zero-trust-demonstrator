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
| `github.com/Fraunhofer-AISEC/cmc` | v0.9.15 (commit `6754d3c`) | Apache-2.0 | Attested TLS (CMC `attestedtls`) for the inter-zone channel, wrapped by `internal/atls`, the only package allowed to import it. Unmodified upstream. See [Attested channel control](attested-channel.md). |
| `google.golang.org/grpc` | v1.82.1 | Apache-2.0 | Transport to the zone's `cmcd` (through CMC), and the in-process `cmcd` stand-in of the `internal/atls` tests. |
| `github.com/go-jose/go-jose/v4` | v4.1.4 | Apache-2.0 | JWS signing of the throwaway attestation metadata in the `internal/atls` test fixtures. Also used by CMC. |
| `github.com/sirupsen/logrus` | v1.9.4 | MIT | CMC's logger. The `internal/atls` tests set its level to keep CMC's per-handshake logging quiet. |

### Brought in by CMC

CMC v0.9.15 adds the following modules to the build. The CMC pin itself needs client confirmation,
and so do the two MPL-2.0 modules marked below: they are file-level copyleft and are linked into a
deliverable, not called as a service, so the [licence exception](#licence-exceptions) route
applies to them until Dash or the client clears them. The last column says whether a CGO-free
production build with the tags `nodefaults,grpc` still links the module. That build keeps only the
gRPC attester and drops the TEE drivers and the in-process backend.

| Module | Version | Licence | Linked with `nodefaults,grpc` |
|---|---|---|---|
| `github.com/containerd/containerd/v2` | v2.3.2 | Apache-2.0 | yes |
| `github.com/containerd/continuity` | v0.5.0 | Apache-2.0 | yes |
| `github.com/containerd/log` | v0.1.0 | Apache-2.0 | yes |
| `github.com/dsnet/golib/memfile` | v1.0.0 | BSD-2-Clause | no |
| `github.com/edgelesssys/ego` | v1.9.0 | **MPL-2.0** — confirm | no (SGX driver, needs cgo) |
| `github.com/fxamacker/cbor/v2` | v2.9.1 | MIT | yes |
| `github.com/google/go-attestation` | v0.6.0 | Apache-2.0 | yes |
| `github.com/google/go-configfs-tsm` | v0.3.3 | Apache-2.0 | no |
| `github.com/google/go-eventlog` | v0.0.2 | Apache-2.0 | no |
| `github.com/google/go-sev-guest` | v0.14.1 | Apache-2.0 | no |
| `github.com/google/go-tdx-guest` | v0.3.2-0.20250131194449-460f94c01da7 | Apache-2.0 | yes |
| `github.com/google/go-tpm` | v0.9.8 | Apache-2.0 | yes |
| `github.com/google/logger` | v1.1.2 | Apache-2.0 | no |
| `github.com/mattn/go-sqlite3` | v1.14.44 | MIT | no (needs cgo) |
| `github.com/opencontainers/runtime-spec` | v1.3.0 | Apache-2.0 | yes |
| `github.com/pion/dtls/v3` | v3.1.4 | MIT | no |
| `github.com/pion/logging` | v0.2.4 | MIT | no |
| `github.com/pion/transport/v4` | v4.0.1 | MIT | no |
| `github.com/plgd-dev/go-coap/v3` | v3.5.1 | Apache-2.0 | yes |
| `github.com/robertkrimen/otto` | v0.5.1 | MIT | no |
| `github.com/veraison/go-cose` | v1.3.0 | **MPL-2.0** — confirm | yes (COSE signatures of CMC reports) |
| `github.com/x448/float16` | v0.8.4 | MIT | yes |
| `go.mozilla.org/pkcs7` | v0.9.0 | MIT | yes |
| `go.uber.org/atomic` | v1.11.0 | MIT | no |
| `go.uber.org/multierr` | v1.11.0 | MIT | no |
| `golang.org/x/exp` | v0.0.0-20260410095643-746e56fc9e2f | BSD-3-Clause | yes |
| `golang.org/x/sync` | v0.23.0 | BSD-3-Clause | yes |
| `google.golang.org/genproto/googleapis/rpc` | v0.0.0-20260427160629-7cedc36a6bc4 | Apache-2.0 | yes |
| `google.golang.org/protobuf` | v1.36.12-0.20260120151049-f2248ac996af | BSD-3-Clause | yes |
| `gopkg.in/sourcemap.v1` | v1.0.5 | BSD-2-Clause | no |

Licences were read from each module's licence file; Dash and the SBOM remain authoritative.
