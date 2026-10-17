# Secrets

How the demonstrator holds credentials and key material, and how it proves none of them leaks into a
log (TDR-BDD-08). Two stores are sanctioned: **Kubernetes Secrets**, and **OpenBao** for X.509 key
material as ZT-11 prescribes ([ADR-0004](adr/0004-openbao-as-x509-key-value-store.md)). Nothing
else holds a credential: not a ConfigMap, not a chart value, not an image, not the repository.

OpenBao is MPL-2.0. It is deployed as a separate, unmodified service and used through its API; the
written licence exception for it (Licence Exception Notice v1.0, follow-up requirement F-07) is
**open** — submitted, not yet decided. See [OSS dependencies](dependencies.md#licence-exceptions).

## OpenBao as a release of its own

OpenBao is the release `ztd-openbao`, from the project chart `deployment/helm/ztd-openbao` (its values
in the chart's `README.md`). It is the eighth and last release of a zone ([Deployment](deployment.md)): the zone installer
(`scripts/install-zone/install.sh`) installs it into the management-plane namespace after
`zone-policy`, with `--wait --wait-for-jobs`. The umbrella chart installs no OpenBao, and its schema
refuses the values it once took for it (`openbao.enabled`, `openbaoBootstrap`, `openbaoExternal`).
Every zone the installer installs gets the release: the kind zone and the participant zones A and B.
The IONOS cluster, which runs the visualization only, does not.

| | |
|---|---|
| Chart | `deployment/helm/ztd-openbao`, wrapping `openbao` 0.28.3 from `https://openbao.github.io/openbao-helm`, locked in the chart's `Chart.lock` |
| Server | OpenBao v2.5.4, the upstream chart's app version, image pinned by digest in `values.yaml` |
| Mode | standalone, one replica, file storage on a volume of the zone's storage class |
| Namespace | the management plane (`ztd-mgmt`, the umbrella's `planes.management.namespace`) |
| Names | StatefulSet `ztd-openbao`, pod `ztd-openbao-0`, Services `ztd-openbao` and `ztd-openbao-internal`, ServiceAccount `ztd-openbao` |
| Engines | KV version 2 at `secret/`, transit at `transit/` |
| Not used | the agent injector, the Kubernetes auth method and its cluster-wide auth-delegator binding (they come with the ZT-11 signing flow), high availability |

The chart version and the server version are different numbers: 0.28.3 is the upstream Helm chart,
v2.5.4 the OpenBao it ships. The OpenBao 2.7.0 image in `scripts/tools/pins.env` is a separate pin,
used only by the token-store integration tests.

The installer builds the upstream chart from the lock file into its cache before it renders or
installs the release (`helm dependency build`, which refuses a lock that does not match the chart's
dependencies), and checks the built archive's digest on every later use. It fills the release's zone
facts from the umbrella's defaults with the zone file on top: the management namespace, the zone's
`zone.storageClass` (refused when the zone file does not state it) and the Cilium switch.

**Identity and transport.** The server pods, the bootstrap Job and the verification hook carry the
identity label `spiffe.io/spire-managed-identity: "true"`. Because the release is installed after
istiod and after the registration rule of `zone-policy`, each pod is created with the injector's
sidecar, a SPIRE entry and an SVID: the server holds
`spiffe://<trust domain>/ns/ztd-mgmt/sa/ztd-openbao`, the bootstrap `…/sa/ztd-openbao-bootstrap`, the
verification hook `…/sa/default`. The server listens without TLS inside its pod; between pods the
sidecars carry its traffic as mesh mTLS under the mesh-wide STRICT peer authentication
([ADR-0009](adr/0009-service-mesh-mode-istio-sidecar-with-cilium.md),
[Workload identity](workload-identity.md)), and the plane's default deny admits only pods of the same
plane. The jobs complete under injection: the native sidecar exits with the job's container. The
mesh-identity proof (`scripts/verify-mesh-identity/verify.sh`) shows `ztd-mgmt/ztd-openbao-0` as a
matched declared workload in its registration inventory.

Without a mesh (the secrets baseline on kind's own CNI) the label is inert: the pods start without a
proxy and the release installs the same way.

### Bootstrap

A sealed OpenBao is not ready, and with `--wait` Helm runs post-install hooks only once every regular
resource is ready, so no hook could ever unseal it. The bootstrap is therefore a regular Job of the same
release, `ztd-openbao-bootstrap-<hash>`, which `--wait-for-jobs` waits for. It reaches the sealed
server through the main Service `ztd-openbao`, which publishes not-ready addresses: Kubernetes marks
the endpoint ready and the mesh routes to it. Its state lives in the Kubernetes Secret
`ztd-openbao-bootstrap` in the management namespace, and every run is safe to repeat:

| State found | What the Job does |
|---|---|
| not initialised, no Secret | initialises with one key share, stores the unseal key and the root token in the Secret (`state=initialized`) |
| not initialised, Secret present | fails: the store was lost; the Secret is never overwritten |
| initialised, no Secret | fails: it never re-initialises |
| sealed | unseals with the stored key |
| `state=initialized` | enables kv-v2 and transit, creates the fixture transit key `ztd-fixture` and the fixture KV value `secret/ztd-fixture/canary`, the policy `ztd-verify` and a periodic verification token (768 h); checks the token; sets `state=configured` |
| `state=configured`, root token still present | revokes it if it is still valid, then removes it from the Secret |
| `state=configured` | renews the verification token and exits |

After a successful run the Secret holds the unseal key, the verification token and the state; the root
token is revoked. Credentials reach `curl` through header and body files in a memory volume, never on
a command line, and the Job's log names states and HTTP codes only.

**The upgrade rerun.** The Job's name carries a hash of its script and of the whole of the chart's
values, the upstream chart's included. The server's StatefulSet uses the `RollingUpdate` strategy
(the upstream default, `OnDelete`, would leave a changed value unapplied until someone deleted the
pod by hand), so an upgrade that changes the server's pod template, such as its image or resources,
restarts the server, which comes back sealed. The same change renders a Job with a new name: Helm
creates it, it waits for the pod of the new revision, unseals it before `--wait` gives up, and Helm
removes the previous Job. An upgrade with the same values renders the same name, so the manifest is
identical and no Job runs.

The `ztd-verify` policy can read `sys/mounts/*`, read `secret/data/ztd-fixture/*`, use the
`ztd-fixture` transit key, and look up and renew itself. Nothing else.

The Job's Role may create Secrets in the management namespace — Kubernetes RBAC cannot limit `create`
to one name — and may read and patch only `ztd-openbao-bootstrap`. It may also read, by name, the
StatefulSet `ztd-openbao` and the pod `ztd-openbao-0`: before it asks the server anything, the Job
waits until that pod runs the StatefulSet's update revision, so that on an upgrade it never unseals
the pod being replaced (still listed by the Service) and leaves the new one sealed.

**Network.** The Job reaches the Kubernetes API from the management plane; on a meshed zone the call
leaves through its sidecar as plain TCP, since the API server has no sidecar. Under Cilium the chart
opens that lane itself, as a `CiliumNetworkPolicy` to the `kube-apiserver` entity for the Job's pods
only (the zone fact `cni.cilium.enabled`). With another CNI the umbrella's `networkPolicy.kubeApi`
lane must be open (on kind, `scripts/secrets/kind-api-lane.sh` prints it from the live cluster).

### Verification

The `platform`-band hook `ztd-verify-openbao` runs after every install and upgrade, in the management
namespace, with the verification token from a Secret volume and no Kubernetes API access. It fails the
release unless the server is initialised and unsealed, `secret/` is KV version 2 and `transit/` is
transit; with the bundled server it also reads the fixture value (printing a 12-character hash of it,
never the value) and round-trips the fixture transit key. It renews the token, so the token does not
expire while the release is upgraded or verified at least once every 32 days. The Job stays until the
next run replaces it, so its log can be collected (`kubectl -n ztd-mgmt logs job/ztd-verify-openbao
-c verify`).

**Token expiry.** If the verification token expires, the hook fails. Recovery: generate a root token
with the unseal key (`bao operator generate-root`), issue a new periodic token with the `ztd-verify`
policy, write it to the Secret's `verify-token`, and revoke the root token again.

### The node pin on the participant zones

On the participant clusters of zone A and zone B the provider's pod network masquerades pod traffic
between nodes, so a meshed pod on another node than istiod never passes its proxy's readiness. Their
zone files set `openbao.pinToMeshNode: true`, and the installer then reads the node istiod runs on
after the istiod release and pins the OpenBao server and both jobs to it, a required node affinity on
`kubernetes.io/hostname` (the chart value `global.pin.node`; `istiod-node-not-found`, which matches no
node, when istiod has none). The server's volume (`WaitForFirstConsumer`) binds on that node. The pin
is temporary: it falls when the provider's network is fixed
([OSC environment](environments/osc.md#the-node-pin-of-openbao)). The kind zone is not pinned.

### After a restart: manual unseal

OpenBao seals itself whenever its pod restarts and stays not ready until it is unsealed. The bootstrap
covers the restarts the lifecycle causes: the first install, and an upgrade that changes a value
(above). A restart the lifecycle does not cause, such as an eviction, a node reboot or an
out-of-memory kill, leaves the server sealed until it is unsealed by hand:

```bash
scripts/secrets/unseal.sh            # namespace ztd-mgmt, pod ztd-openbao-0
```

The script reads the key from the Secret and hands it to `bao write sys/unseal key=-` on standard
input, so it never appears on a command line (which the API server's audit log records) or in the
output. The data survives: the secrets baseline restarts the pod, observes it sealed and not ready,
unseals it and finds the same fixture value. This manual step is a declared reading of the TDR's
"zero manual intervention" rule ([Specification changes](specifications.md)): deploy, redeploy and
uninstall need none; an automatic unseal needs a key-management backend the demonstrator does not
operate.

### Teardown

`scripts/install-zone/install.sh uninstall` removes `ztd-openbao` first, then the other releases in
reverse order; the umbrella's uninstall deletes the plane namespaces, and with them the OpenBao volume
and the bootstrap Secret. It is a destructive reset: the next install initialises a new, empty store.

### An existing OpenBao

The XFSC ArgoCD deployment, which FACIS names as the reference deployment, already installs OpenBao —
the same chart, 0.28.3, wrapped with selectable auto-unseal backends
([`eclipse-xfsc/deployment`, `INFRA/security/openbao/Chart.yaml`](https://github.com/eclipse-xfsc/deployment/blob/739606691ecff72b3a40404a19fce44d9c22b0ee/INFRA/security/openbao/Chart.yaml)).
There the release uses that instance instead of its own: `openbao.server.enabled: false`,
`external.address` names it and `external.verifyTokenSecret` names a Secret in the management
namespace with a `verify-token` key. Nothing is installed or initialised; only the verification hook
runs (health, unseal state and the two engines). `openbao.server.enabled` and `external.address` are
exclusive.

## The baseline proof (TDR-BDD-08)

`release.yml` proves the baseline on every candidate, in two jobs of the same run:

**Secrets baseline** (`scripts/secrets/baseline.sh`) installs two releases on a disposable kind cluster
with kind's own CNI and no mesh: the umbrella, then `ztd-openbao` with its kind values. It restarts
OpenBao and unseals it by hand (`restart.json`), upgrades both releases again, and runs the canary scan
(`scripts/secrets/canary_scan.py`) twice: right after the install, before the restart deletes the first
OpenBao pod and the upgrade replaces the verification hook, and again at the end. `scan.json` holds both
stages and is clean only if both were. Each scan:

- a synthetic credential, the canary, is put in a Kubernetes Secret that a probe pod in the data plane
  consumes as an environment variable and as a file;
- the raw output of every container in every namespace is collected — init containers too, and the
  previous instance of any container that restarted — with every pod spec and every ConfigMap (data
  and decoded binaryData);
- they are searched for the canary (plain and base64), for OpenBao's live credentials read from the
  cluster (the unseal key, the verification token and the fixture value), and for the shapes of
  credentials: PEM private keys, OpenBao tokens and, in ConfigMaps, non-empty password fields and any
  key named like a credential (password, secret, token, API key, private key, credential) that holds
  a value. The root token is revoked and gone by then, so it can only be found by its shape;
- a **negative control** proves the scan finds what it looks for: a pod in its own namespace prints the
  canary, and the scan must detect it there. It is reported apart from the baseline.

A container that never started has no output and is counted as such; any other collection failure
fails the scan, and is reported by operation and exit status only — kubectl's own message can quote
what it was given, and evidence never carries it. The demonstrator has no deployed service that consumes a credential yet, so the probe
stands in for one; the scan covers every container and applies to the services as they land.

**Secrets log audit** runs once the first job has completed. It downloads that job's published log
through the job-level REST endpoint (`scripts/secrets/log_audit.py`, `log-audit.json`) and requires
the canary to be absent and a masking control to be present only masked: the first job registers both
values with `::add-mask::` and prints `ZTD_MASK_CONTROL=<value>` once, which must appear as
`ZTD_MASK_CONTROL=***`. Without the control, a log in which nothing was masked, or the wrong log, could
pass. Both values are derived from the repository, run id and attempt — synthetic, never real
credentials — and the audit refuses evidence from another run or attempt.

The row is decided in the audit job, from both halves for the same run. Evidence publishes counts,
scope, locations and the canary's SHA-256, never a value.

**What masking proves.** A clean published log shows that GitHub's masking removed the registered
values from the published log. It does not show that a component never emitted one; that is what the
scan of the raw container output is for.

## Pipeline credentials

Workflow secrets reach a step through `env`, are masked by GitHub, and are never echoed. A job's
kubeconfig is written with `umask 077` to the runner's temporary directory. See
[CI/CD](ci-cd.md#repository-protection-and-least-privilege) for token scopes.
