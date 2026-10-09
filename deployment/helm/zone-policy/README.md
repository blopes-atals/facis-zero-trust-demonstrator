# zone-policy — the identity policy of one zone

The one project chart of the identity path, and the last of the seven releases of a zone
(`scripts/install-zone/install.sh`), because it uses the CRDs the SPIRE and Istio releases own. It
installs into `istio-system`, the mesh root namespace:

- **`ClusterSPIFFEID` `plane-workloads`**: the registration by selector. Every pod with
  `spiffe.io/spire-managed-identity: "true"` in a namespace that carries the umbrella's plane label
  gets `spiffe://<trust domain>/ns/<namespace>/sa/<service account>`. A regular resource that the
  SPIRE controller-manager reconciles into entries, never a hook.
- **`PeerAuthentication` `default`** in `istio-system`: mesh-wide mutual TLS in `STRICT` mode, so a
  workload without a SPIRE entry has no mesh connection.
- **`ValidatingAdmissionPolicy` `proxy-takes-spire-socket`** and its binding: in every namespace
  with the plane label, a pod may not choose its injection templates (`inject.istio.io/templates`),
  and every mesh proxy of a pod (a container, init container or ephemeral container named
  `istio-proxy`, running the `proxyv2` image, or naming `pilot-agent`; the injector's
  `istio-validation` init container aside) must mount the `csi.spiffe.io` volume `workload-socket`
  at `/var/run/secrets/workload-spiffe-uds`. Without it a pod could drop the `spire` injection
  template, or run Istio's agent under another name, and that agent would take a certificate from
  istiod's CA, which stays on because it also signs istiod's own serving certificates. Evaluated
  after injection, on pod creation, pod updates and ephemeral containers; pods without a proxy are
  not concerned by this socket rule (STRICT leaves them outside the mesh), but the capture rule
  below refuses them. A program without these marks can still ask istiod's CA for a certificate;
  no peer trusts it (docs/workload-identity.md, "The proxy").
  The same policy holds **the capture rule** and **the proxy rule** (see below).
- **The identity-band checks**: three post-install and post-upgrade Jobs in the `identity` band of
  the hook-weight scheme (`templates/_hooks.tpl` is a copy of the umbrella's helper). They only read,
  through the Kubernetes API, with a read-only ServiceAccount, and a failure fails the release:

| Job | Weight | Fails the release when |
|---|---|---|
| `server-healthy` | 20 | the SPIRE server's StatefulSet is not Ready (its readiness probe is the server's health endpoint) or an agent is not Ready |
| `trust-bundle-published` | 25 | the server has published no X.509 authority in `spire-bundle`, or the controller-manager or the mesh runs with another trust domain than `trustDomain` |
| `registrations-reconciled` | 30 | the controller-manager reports an entry or render failure, a selected pod without its entry, or fewer selected pods than the running labelled pods of the plane namespaces |

Each check waits up to `checks.timeoutSeconds` for its condition. A failed job is kept for an hour
so that its log can be read; a successful one is removed by the hook delete policy.

The design is in [docs/workload-identity.md](../../../docs/workload-identity.md).

## The capture rule

The Istio CNI plugin builds each injected pod's redirect rules from the pod's capture annotations.
A registered pod annotated `traffic.sidecar.istio.io/excludeInboundPorts: "8080"` has that port
delivered to the application outside its proxy: the mesh-wide `STRICT` policy never sees the
connection, and an unregistered pod of the same namespace reaches it in plaintext. The third
validation of `proxy-takes-spire-socket` therefore pins the capture, in every namespace with the
plane label:

- The injector writes four capture annotations onto **every** pod it injects, and the policy runs
  after the injector, so it cannot refuse their presence; it compares their values with the
  injector's defaults instead. A pod is admitted only when each of them that it carries equals:

  | Annotation | Required value |
  |---|---|
  | `sidecar.istio.io/interceptionMode` | `REDIRECT` (not `NONE`, not `TPROXY`) |
  | `traffic.sidecar.istio.io/includeInboundPorts` | `*` |
  | `traffic.sidecar.istio.io/excludeInboundPorts` | the status port alone, `proxySocketPolicy.statusPort` (`15020`) |
  | `traffic.sidecar.istio.io/includeOutboundIPRanges` | `*` |

- These are refused whenever present: the optional capture annotations
  `traffic.sidecar.istio.io/excludeOutboundIPRanges`, `includeOutboundPorts`,
  `excludeOutboundPorts`, `excludeInterfaces`, `kubevirtInterfaces` and
  `istio.io/reroute-virtual-interfaces`; `status.sidecar.istio.io/port`, which moves the status
  port and so excludes an application port without naming `excludeInboundPorts`;
  `proxy.istio.io/config`, which can point the proxy at another discovery server;
  `sidecar.istio.io/proxyImage`, `sidecar.istio.io/bootstrapOverride`,
  `sidecar.istio.io/userVolume` and `userVolumeMount`, which swap the proxy's image, replace its
  bootstrap or mount the pod's volumes into it; and `proxy.istio.io/overrides`, which the injector
  writes when the pod brings its own `istio-proxy` container and merges it over the injected one.
  The injector writes none of these on a pod that does not ask for them.
- The injection opt-out `sidecar.istio.io/inject`, as an annotation or a label and whatever its
  value, is refused in a namespace with the injection label (`istio-injection` or `istio.io/rev`),
  because a pod without a proxy there is reachable in plaintext like an excluded port. The plane
  namespaces the zone file declares `mesh: false` (`istio-system`, `spire-system`) carry no
  injection label, and istiod and the `istio-cni` node agents, which opt out of injection, are
  admitted there, so their controllers can recreate them. The umbrella writes the injection label
  from the plane entry's `mesh` field and its verification hook checks it; every other clause
  applies in those namespaces too.

**The proxy rule** (fourth validation): every mesh proxy must be the injector's own, the image
`proxySocketPolicy.proxyImage`, no command, arguments starting with `proxy sidecar`, and no
`ISTIO_BOOTSTRAP_OVERRIDE` in its environment; a proxy of another image that mounts the SPIRE
socket would pass the socket rule and could accept plaintext on the inbound capture port.

An ordinary pod satisfies both rules with exactly what the injector writes. A workload that needs a
capture exception or a proxy setting gets it mesh-wide through the charts (for example
`meshConfig.defaultConfig`) in its own change, never through a pod annotation. The rule does not
cover what bypasses the capture without an annotation: capture is iptables inside the pod's
network namespace, so a host-networked pod or a container with `NET_ADMIN` steps around it, and the
redirect rules let UID and GID 1337, the proxy's own, leave without capture, so an application
container running as 1337 (by its `securityContext` or its image's `USER`) sends its outbound
traffic past the proxy. Those belong to a Pod Security level on the plane namespaces with a
`runAsUser`/`runAsGroup` rule, the follow-up change.

**Status-port coupling.** `proxySocketPolicy.statusPort` must equal the `istiod` release's
`global.proxy.statusPort`, which `deployment/helm/values/istiod.yaml` leaves at Istio's default,
`15020`. If the two differ, the injector writes a different exclusion than the policy expects and
every injected pod in a plane namespace is refused: the symptom is loud on purpose, rather than an
application port silently excluded.

**Proxy-image coupling.** `proxySocketPolicy.proxyImage` must equal the `istiod` release's
`global.proxy.image` in `deployment/helm/values/istiod.yaml`, the whole reference with its digest.
If the two differ, every injected pod in a plane namespace is refused by the proxy rule; an Istio
upgrade changes both.

## Values

| Key | Default | Meaning |
|---|---|---|
| `trustDomain` | none, required | The zone's trust domain, `zone.trustDomain` of the zone file (the installer fills it) |
| `spire.namespace` | `spire-system` | Where the `spire` release runs |
| `spire.className` | `spire-system-spire` | The controller-manager's class: `<release namespace>-<release name>` of the `spire` release |
| `spire.serverStatefulSet`, `spire.agentDaemonSet` | `spire-server`, `spire-agent` | Read by `server-healthy` |
| `spire.bundleConfigMap`, `spire.controllerManagerConfigMap` | `spire-bundle`, `spire-controller-manager` | Read by `trust-bundle-published` |
| `mesh.namespace`, `mesh.configMap` | `istio-system`, `istio` | The mesh root namespace and the mesh configuration |
| `registration.name` | `plane-workloads` | Name of the `ClusterSPIFFEID` |
| `registration.identityLabel` | `spiffe.io/spire-managed-identity: "true"` | The switch a workload carries to get an identity |
| `registration.planeLabel` | `ztd.facis.io/plane` | The umbrella's plane label; namespaces that carry it are selected |
| `peerAuthentication.mode` | `STRICT` | The only value accepted |
| `proxySocketPolicy.name` | `proxy-takes-spire-socket` | Name of the admission policy and its binding |
| `proxySocketPolicy.volume`, `proxySocketPolicy.mountPath`, `proxySocketPolicy.driver` | `workload-socket`, `/var/run/secrets/workload-spiffe-uds`, `csi.spiffe.io` | The volume, mount path and CSI driver every mesh proxy must have; those of Istio's `sidecar` template and the istiod values file |
| `proxySocketPolicy.statusPort` | `15020` | The proxy's status port, the one inbound port the capture rule lets the injector exclude; must equal the `istiod` release's `global.proxy.statusPort` (integer, required) |
| `proxySocketPolicy.proxyImage` | `docker.io/istio/proxyv2:1.31.1@sha256:d86c…` | The injected proxy's whole image reference, by digest; the proxy rule admits no other image for a mesh proxy; must equal the `istiod` release's `global.proxy.image` (string, required) |
| `checks.enabled` | `true` | The identity-band jobs |
| `checks.image` | `curlimages/curl` by digest | Image of the jobs (the umbrella's verification image) |
| `checks.timeoutSeconds` | `180` | How long each check waits before it fails the release |

`ci/values.yaml` is the kind zone, the file the CI chart job renders with.

```bash
helm lint deployment/helm/zone-policy -f deployment/helm/zone-policy/ci/values.yaml
helm template zone-policy deployment/helm/zone-policy -n istio-system \
  -f deployment/helm/zone-policy/ci/values.yaml
```
