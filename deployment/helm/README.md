# Helm charts

Charts for the demonstrator. A zone is seven Helm releases, installed in order by
`scripts/install-zone/install.sh` from one zone file:

| Directory | Release(s) | What |
|---|---|---|
| `ztd/` | `ztd` | the umbrella chart: management and data planes and the two control-plane namespaces, baseline deny network policies with the declared openings, the allow matrix, the hook-weight bands |
| `values/` | `spire-crds`, `spire`, `istio-base`, `istiod`, `istio-cni` | the values files of the upstream SPIRE and Istio charts, installed as they ship and pinned by version; `values/README.md` lists every value set and why |
| `zone-policy/` | `zone-policy` | the registration of the workloads with SPIRE, mesh-wide STRICT mTLS, the identity-band checks |
| `bdd-pool/` | (BDD) | the namespaces and bindings of the deployment-lifecycle scenarios |

Workload identity exists before any workload starts because of the identity path, not because of an
install order (`docs/umbrella-chart.md`). Each chart documents its values alongside it.
