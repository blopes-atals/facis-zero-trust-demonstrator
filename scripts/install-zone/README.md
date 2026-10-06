# install-zone

Installs one zone of the demonstrator, from an empty cluster that already runs its CNI, as seven
Helm releases in a fixed order, each through the deployment lifecycle step
(`scripts/lifecycle.sh`: a server-side dry run, then `helm upgrade --install --wait` with rollback
on failure), each waiting on the previous:

| # | Release | Namespace | Chart | Values |
|---|---|---|---|---|
| 1 | `ztd` | `ztd-system` | `deployment/helm/ztd` (the umbrella) | the zone file |
| 2 | `spire-crds` | `spire-system` | `spire-crds` 0.6.1, SPIFFE hardened charts | `deployment/helm/values/spire-crds.yaml` |
| 3 | `spire` | `spire-system` | `spire` 0.30.2 (SPIRE v1.15.3) | `deployment/helm/values/spire.yaml` + zone facts |
| 4 | `istio-base` | `istio-system` | `base` 1.31.1, Istio release archive | `deployment/helm/values/istio-base.yaml` |
| 5 | `istiod` | `istio-system` | `istiod` 1.31.1 | `deployment/helm/values/istiod.yaml` + zone facts |
| 6 | `istio-cni` | `istio-system` | `cni` 1.31.1 | `deployment/helm/values/istio-cni.yaml` |
| 7 | `zone-policy` | `istio-system` | `deployment/helm/zone-policy` | chart defaults + zone facts; also waits for its Jobs |

The umbrella creates every namespace the later releases install into; the lifecycle step never
creates one. The only namespace the installer creates is the umbrella's release namespace,
`ztd-system`, which holds the release record and its verification job.

## Usage

```bash
ZONE_VALUES=deployment/helm/ztd/zones/<zone>.yaml KUBE_CONTEXT=<context> scripts/install-zone/install.sh plan
ZONE_VALUES=deployment/helm/ztd/zones/<zone>.yaml KUBE_CONTEXT=<context> scripts/install-zone/install.sh install
ZONE_VALUES=deployment/helm/ztd/zones/<zone>.yaml KUBE_CONTEXT=<context> scripts/install-zone/install.sh uninstall
scripts/install-zone/install.sh render [release...]     # no cluster: what CI runs
```

On the local kind cluster the defaults apply (`ZONE_VALUES` is the kind zone,
`deployment/helm/ztd/ci/values.yaml`; `KUBE_CONTEXT` is `kind-ztd`):

```bash
scripts/dev/kind-cilium-up.sh
scripts/install-zone/install.sh install
```

| Variable | Default | Meaning |
|---|---|---|
| `ZONE_VALUES` | `deployment/helm/ztd/ci/values.yaml` | the zone file |
| `KUBE_CONTEXT` | `kind-ztd` | the kubectl context of the zone's cluster |
| `STEP_TIMEOUT` | `10m` | the timeout of each release |
| `RENDER_DIR` | unset | with `render`, write each release's manifest there |
| `INSTALL_ZONE_CACHE` | `~/.cache/ztd-install-zone` | where the pinned charts are kept |

- **`install`** first renders all seven releases with their zone facts, so a missing fact stops the
  run before anything is installed; then installs them in order. It stops at the first release
  that does not reach a ready state, exits non-zero and names the release and the lifecycle step's
  error; the failed release is rolled back. It exits 0 only when every pod in the plane and
  control-plane namespaces is Ready (finished Job pods aside).
- **Idempotent.** Run again, it upgrades every release in place with identical manifests.
- **`render`** renders every release, or only the ones named; a name that is not one of the seven
  releases (`ztd`, `spire-crds`, `spire`, `istio-base`, `istiod`, `istio-cni`, `zone-policy`)
  stops it with a non-zero exit and the list of valid names, before anything is rendered.
- **`plan`** lists the seven steps without touching a cluster; `install` against an unreachable
  cluster prints the same list and refuses to continue, changing nothing.
- Every command first checks that the zone file exists, and stops with `zone file not found:
  <path>` and a non-zero exit when it does not. `help` (or `-h`, `--help`) prints the usage and
  exits 0; any other word prints the usage and `unknown command '<word>'` on stderr and exits 2.
- **`uninstall`** removes the releases in reverse order (`zone-policy`, `istio-cni`, `istiod`,
  `istio-base`, `spire`, `spire-crds`, then the umbrella, which takes the namespaces with it) and
  removes the CRDs each release owned, including the ones Istio's `base` chart marks to be kept by
  Helm. Delete the workloads in the plane namespaces first: a pod that still mounts the SPIFFE CSI
  volume when the driver goes holds its namespace in `Terminating`.

## The facts a zone file must carry

The umbrella reads the whole file (`deployment/helm/ztd/zones/README.md`). Where the mesh runs, it
must also state `zone.trustDomain` (the DNS zone delegated to the trust zone), the API lane
(`networkPolicy.kubeApi.enabled: true` with its port), `cni.cilium.enabled: true`, a
`zone.kubernetesVersion` of 1.33 or later, the control-plane namespaces in `planes.extra` and the
openings. The other releases read these zone facts from it:

| Release | Value | Zone fact |
|---|---|---|
| `spire` | `global.spire.trustDomain`, `global.spire.caSubject.commonName` | `zone.trustDomain` |
| `spire` | `global.spire.clusterName` | `zone.name` |
| `spire` | `global.spire.persistence.storageClass` | `zone.storageClass` |
| `istiod` | `meshConfig.trustDomain` | `zone.trustDomain` |
| `zone-policy` | `trustDomain` | `zone.trustDomain` |

A release whose zone fact is missing does not render, and the message names the fact.

## Pins

The chart versions and digests are at the top of `install.sh` and in `docs/dependencies.md`; the
container images are pinned by tag and digest in the values files under `deployment/helm/values/`. The SPIRE
charts come from `https://spiffe.github.io/helm-charts-hardened/` and are checked against their
sha256. The Istio 1.31 charts are not in Istio's Helm repository or OCI registry; they come from
the release archive `istio-1.31.1-linux-amd64.tar.gz`, checked against its published sha256. An
upgrade changes a version and its digest here and reruns `scripts/verify-mesh-identity/verify.sh`.

## Tools

`helm` (v4.3.0, the pipeline's), `kubectl`, `jq`, `curl`, `python3` with PyYAML, and `sha256sum`
or `shasum`. On a kind host, raise `fs.inotify.max_user_instances` to 512 first
(`sudo sysctl -w fs.inotify.max_user_instances=512`): every kind node shares the host kernel, and
the Istio CNI agent fails to start below that limit.
