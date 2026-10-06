# Upwork 3.23.2 GitOps regressions, reproduction

Three Argo apps, all on `ce-mgmt`, tracking label `argocd.argoproj.io/instance` (as Upwork).

| App | Path | Reproduces |
|---|---|---|
| `upwork-ns` | `upwork-repro/ns-app` | Their wave-1 namespace app owning `calico-system`, while the tigera-operator chart also renders it (`managementCluster.service.enabled: true`) |
| `upwork-oidc` | `upwork-repro/oidc-config` (Helm) | Their config chart: Helm-labelled `tigera-oidc-credentials` in `tigera-operator` + OIDC `Authentication` |
| `upwork-policy` | `upwork-repro/policy-app` | A policy with `source: {}` vs a control policy without it |
