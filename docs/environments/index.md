# Environments

The demonstrator runs across **three managed Kubernetes clusters**: two on T-Systems Open Sovereign
Cloud carrying the two demonstration zones, and one on IONOS Cloud carrying the CI/CD and
visualization environment. The reasoning for three rather than two is recorded in
[ADR-0005](../adr/0005-three-cluster-reading-of-the-target-environment.md).

| Environment | Clusters | Role | Guide |
|---|---|---|---|
| T-Systems Open Sovereign Cloud | 2 | Zone A and zone B — the two demonstration zones and their trust boundary | [OSC setup](osc.md) |
| IONOS Cloud | 1 | CI/CD and the visualization environment | [IONOS setup](ionos.md) |

Each guide is written to be followed start to finish by someone who has not seen the cluster before.
Where a step cannot be executed yet it says so, rather than reading as though it had been done.

## What is common to all three

- **Kubernetes 1.29 or later.** Older versions are not supported; the mesh and admission baselines
  assume it. A cluster that runs the mesh needs **1.33 or later**, for the native sidecar containers
  of [ADR-0006](../adr/0006-service-mesh-mode-istio-sidecar-with-cilium.md).
- **Cilium as CNI**, configured with `cni.exclusive=false` so the Istio CNI plugin can chain behind
  it, and **Istio in sidecar mode** on top
  ([ADR-0006](../adr/0006-service-mesh-mode-istio-sidecar-with-cilium.md); ambient is the parked
  alternative).
- **The clusters are client-provided.** Provisioning them is out of scope; these guides begin at the
  point where a kubeconfig is in hand.
- **Nothing is applied by hand.** Every step below is a chart, a script in `scripts/` or a pipeline
  run. A step that cannot be expressed that way is a defect in the step, not a reason to click.

## Reproduction and verification

ZT-16 asks for documentation from which the setup of each cluster can be reproduced step by step.
Each guide therefore pairs every stage with the check that proves the stage worked — the command,
and what its output has to say. A stage without a check is not finished.
