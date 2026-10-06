# Troubleshooting

Symptoms, causes and checks for the demonstrator.

## Reading a refusal

The demonstrator is built so that a refusal explains itself. Before debugging, read the denial: the
guard returns the layer and the rule that produced the decision, and the matching audit entry
carries the same reason code. A refusal with a reason is working as designed — the question is
whether the reason is the one you expected.

## Workload identity and mesh enrolment

| Symptom | Likely cause | Check |
|---|---|---|
| A pod starts but no traffic reaches it | It never received an SVID, so the mesh has no identity to route to | Look for a SPIRE registration entry matching the pod's service account; a missing entry is the answer, not a mesh problem |
| The SVID exists but the SPIFFE ID is wrong | The registration selector matches more, or less, than intended | Compare the SPIFFE ID in the workload's certificate with the selector that produced it |
| Traffic works between two pods that should not be able to talk | L7 enforcement is owned by neither component on that path, or by both | Check which component owns L7 for that path in the mesh configuration — [ADR-0006](adr/0006-service-mesh-mode-istio-sidecar-with-cilium.md) requires exactly one: where the sidecar enforces L7, Cilium is held to L3/L4 |
| The Istio CNI plugin never chains | Cilium claimed the CNI configuration exclusively | Confirm Cilium is installed with `cni.exclusive=false` |
| A meshed pod stays `Init:1/2`, its application container never starts, and its proxy holds no workload certificate | The pod has no SPIRE entry: it lacks the label `spiffe.io/spire-managed-identity: "true"`, or its namespace lacks the plane label, so the native sidecar never becomes ready under STRICT | `istioctl proxy-config secret <pod> -n <ns>` shows no `default` entry; the proxy logs `workload is not authorized for the requested identities ["default"]`; `spire-server entry show` lists no entry with `k8s:pod-uid:<pod uid>`. Add the label; never relax STRICT |
| The proxy has a `default` certificate but no `ROOTCA`, and every mTLS handshake fails validation | The SPIRE agent serves no resource under the name the proxy asks for its validation context: the SDS names of the `spire` release were changed | `istioctl proxy-config secret <pod>` lists `default` and no `ROOTCA`; the `spire-agent` ConfigMap must hold `sds` with `default_svid_name` `default`, `default_all_bundles_name` `ROOTCA` and `default_bundle_name` `null` ([the SDS contract](workload-identity.md#the-sds-contract)) |
| A pod is stuck in `ContainerCreating` with `MountVolume.SetUp failed for volume … csi.spiffe.io` | The SPIRE agent or the SPIFFE CSI driver is not Ready on that node, so the socket cannot be mounted yet | `kubectl -n spire-system get pods -o wide` for the agent and the CSI driver on the pod's node; the agent's log names an attestation failure (for example the server unreachable on 8081, which is the `identityServer` opening) |
| The umbrella refuses to render: `mesh.mode sidecar needs Cilium (cni.cilium.enabled)` | The zone file sets `cni.cilium.enabled: false` while the mesh runs, so the control-plane openings by entity cannot be rendered | The zone's CNI is not Cilium: a declared derogation of the preferred stack is needed before that zone is installed ([Workload identity](workload-identity.md#openings-under-the-default-deny)); on a Cilium cluster, correct the zone file |
| A `ClusterSPIFFEID` or `PeerAuthentication` is refused with `failed calling webhook … context deadline exceeded` | The API server cannot reach the webhook pod under the default deny | `cilium-dbg monitor --type drop` on the webhook pod's node shows the dropped SYN and its source identity; the `controlPlaneWebhooks` opening admits `kube-apiserver`, `host` and `remote-node` on the webhook port |
| The `istio-cni-node` pods crash with `couldn't initialize inotify: too many open files` (kind) | The host's inotify instance limit, shared by every kind node | `sysctl fs.inotify.max_user_instances`; raise it to 512 (`sudo sysctl -w fs.inotify.max_user_instances=512`), the value kind's known issues give |
| A pod in a plane namespace is refused with `ValidatingAdmissionPolicy 'proxy-takes-spire-socket' … denied request` | The pod names its own injection templates (`inject.istio.io/templates`), or brings an `istio-proxy` container that does not mount the SPIRE socket; its proxy would take a certificate from istiod's CA instead of SPIRE | The message names which rule refused it. Remove the annotation and any `istio-proxy` override from the pod template; the default injection already carries the socket ([the proxy](workload-identity.md#the-proxy)) |
| The `zone-policy` release fails at an identity check | The check's job names what is missing: the server or an agent not Ready, no bundle, a trust domain that differs from the zone file, or a labelled pod without an entry | `kubectl -n istio-system logs job/zone-policy-<check>`; the failed job is kept for an hour |

## Admission control rejections

| Symptom | Likely cause | Check |
|---|---|---|
| An image will not start and the event is generic | Gatekeeper refused it but the reason did not reach the event | Read the provider's decision, which carries the reason code; a refusal with no reason code is a defect in the provider |
| A correctly signed image is refused | The verification key does not match the key the image was signed with | Compare the signing key used by the pipeline with the key material the provider was configured with |
| An unsigned image starts | The constraint is not bound to that namespace, or the provider is not reachable | Confirm the constraint's scope, then confirm the provider answers — an unreachable provider must fail closed, not open |

## Token issuance, DPoP proofs and the token store

| Symptom | Likely cause | Check |
|---|---|---|
| Registration succeeds but no token is issued | The presentation did not verify, so there is nothing to derive a token from | Read the verification outcome first; the token failure is downstream of it |
| A token is rejected on use | The DPoP proof is not bound to the key that requested the token, or is being replayed | Compare the proof's key thumbprint with the one recorded at issuance |
| The upstream call carries the caller's own token | Substitution did not happen | Trace the outbound request — the caller's proof must never be forwarded onward |
| Everything fails after a control-plane blip | The token store failed closed, as designed | Confirm the alert was raised; fail-secure is the correct behaviour, silence is not |

## Attested channel handshake failures

| Symptom | Likely cause | Check |
|---|---|---|
| The handshake aborts | The peer's measurement does not match the expected value | Compare the report's measurement with the expected value resolved from TRAIN; a mismatch is a working refusal |
| The handshake aborts and the expected value is absent | The trust-list entry is missing or stale, not the peer | Resolve the peer's digest through TRAIN directly before suspecting the peer |
| The report verifies but the channel is refused | The evidence is not bound to this connection | Confirm the TLS exporter value is present in the report's user data — an unbound report is a replay risk, so refusal is correct |
| Application traffic appears after a failed handshake | A serious defect | This must be impossible and is asserted by an acceptance scenario; treat any instance as a stop-the-line finding |

## Credential verification and trust-list staleness

| Symptom | Likely cause | Check |
|---|---|---|
| A credential that worked yesterday is refused | It was revoked | Check the status list entry before anything else |
| Verification fails for every credential at once | The status list or the trust anchor is unreachable | Check reachability; an unreachable list must deny, and the alert tells you which one it was |
| A peer that should be trusted is not listed | The trust list has not been republished since the peer was added | Compare the published trust list with what the connector resolved, not with what you expect it to contain |

## Logs

Services emit structured JSON logs. Correlate by the request identifier carried across hops rather
than by timestamp.
