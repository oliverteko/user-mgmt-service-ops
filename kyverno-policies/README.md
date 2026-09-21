# Kyverno ClusterPolicies

Four `ClusterPolicy` objects, applied via [`argocd/application-kyverno-policies.yaml`](../argocd/application-kyverno-policies.yaml) (plain-manifest Application, not Helm - these are custom resources, unrelated to how [`argocd/application-kyverno.yaml`](../argocd/application-kyverno.yaml) installs Kyverno itself into the `policy` namespace).

| Policy | Catches |
|---|---|
| [`require-requests-limits.yaml`](require-requests-limits.yaml) | Missing CPU/memory requests or memory limit on any container |
| [`disallow-latest-tag.yaml`](disallow-latest-tag.yaml) | Missing image tag, or `:latest` |
| [`require-run-as-nonroot.yaml`](require-run-as-nonroot.yaml) | No `runAsNonRoot: true` (pod- or container-level) |
| [`require-probes.yaml`](require-probes.yaml) | Missing `readinessProbe` or `livenessProbe` on a Deployment/StatefulSet/DaemonSet |

All four: `validationFailureAction: Enforce` (rejects at admission, not just an audit log entry). The first three match `kinds: [Pod]` - Kyverno's default [pod-controller autogen](https://kyverno.io/docs/writing-policies/autogen/) then automatically derives equivalent rules for `Deployment`/`StatefulSet`/`DaemonSet`/`Job`/`CronJob`, so a `kubectl apply` of a bad `Deployment` gets rejected directly, without having to write the rule twice. `require-probes` is the exception: it matches the long-running workload kinds directly with autogen off, because a run-to-completion `Job` (like the [k6 load test](../loadtest/README.md)) has nothing meaningful to probe and would otherwise be blocked.

## Why scoped to `user-mgmt-*` namespaces only

Every rule adds `namespaces: [user-mgmt-*]` to its `match`. Enforcing cluster-wide from day one would also gate `kube-system`, `argocd`, `traefik`, `monitoring`, and `policy` itself - workloads from Helm charts this repo doesn't author (ArgoCD, Traefik, kube-prometheus-stack, Kyverno), several of which don't set `runAsNonRoot` or pin every image tag the way this policy requires. Enforcing there risks blocking their own pods (including, amusingly, Kyverno's) and breaking the cluster on the very first sync. Scoping to our own namespaces keeps the blast radius to what this repo actually controls and can guarantee compliance for.

## Proving enforcement works

[`demo/bad-deployment.yaml`](demo/bad-deployment.yaml) deliberately violates all four policies at once (no requests/limits, `nginx:latest`, no `runAsNonRoot`, no probes). It's excluded from the ArgoCD-synced directory (`directory.exclude` in `application-kyverno-policies.yaml`) - never applied automatically, only by hand as a one-off test:

```bash
kubectl create namespace user-mgmt-demo
kubectl apply -f kyverno-policies/demo/bad-deployment.yaml
```

Expected: the `kubectl apply` itself fails (admission webhook rejection, not a Pending/CrashLoopBackOff resource that then gets cleaned up), one error block per violated policy. The four `autogen-*` rule names below are the reliable part to look for; exact message wording may shift slightly across Kyverno versions.

Clean up afterwards - nothing was actually created, but the namespace was:

```bash
kubectl delete namespace user-mgmt-demo
```

## Verifying the real app still passes

`helm/user-mgmt-service`'s `backend`/`frontend` Deployments were updated alongside these policies (pod-level `runAsNonRoot: true`, container-level `allowPrivilegeEscalation: false` + dropped capabilities) specifically so they comply - both container images already ran as non-root at the Docker layer already, this just makes Kyverno's check pass explicitly too. After `application-kyverno-policies.yaml` has synced:

```bash
kubectl get deploy -n user-mgmt-staging
kubectl get deploy -n user-mgmt-prod
# both should already exist/scale normally - if a real change to the chart
# ever violates one of these policies, the ArgoCD sync itself will start
# failing with the same "blocked due to the following policies" error.
```

## Local/offline validation (no cluster needed)

The [Kyverno CLI](https://kyverno.io/docs/kyverno-cli/) (`scoop install kyverno-cli` / `brew install kyverno`) tests a policy against a resource manifest without any cluster at all - this is how the two checks below were actually verified, not just described:

```bash
kyverno apply kyverno-policies/require-requests-limits.yaml kyverno-policies/disallow-latest-tag.yaml kyverno-policies/require-run-as-nonroot.yaml kyverno-policies/require-probes.yaml \
  --resource kyverno-policies/demo/bad-deployment.yaml
```

Actual output (Kyverno CLI 1.19.1, chart 3.9.1 - `kyverno version`):

```
Applying 15 policy rule(s) to 1 resource(s)...
policy require-requests-limits -> resource user-mgmt-demo/Deployment/policy-violation-demo failed:
1 - autogen-validate-resources validation error: CPU and memory resource requests and a memory limit are required for every container. rule autogen-validate-resources failed at path /spec/template/spec/containers/0/resources/
policy disallow-latest-tag -> resource user-mgmt-demo/Deployment/policy-violation-demo failed:
1 - autogen-validate-image-tag validation failure: validation error: Using a mutable image tag e.g. 'latest' is not allowed. rule autogen-validate-image-tag failed at path /image/
policy require-run-as-nonroot -> resource user-mgmt-demo/Deployment/policy-violation-demo failed:
1 - autogen-run-as-non-root validation error: Running as root is not allowed. Either spec.securityContext.runAsNonRoot must be true, or every container's securityContext.runAsNonRoot must be true. rule autogen-run-as-non-root[0] failed at path /spec/template/spec/securityContext/ rule autogen-run-as-non-root[1] failed at path /spec/template/spec/containers/0/securityContext/
policy require-probes -> resource user-mgmt-demo/Deployment/policy-violation-demo failed:
1 - autogen-require-probes validation error: Every container must define both a readinessProbe and a livenessProbe. rule autogen-require-probes failed at path /spec/template/spec/containers/0/livenessProbe/

pass: 1, fail: 4, warn: 0, error: 0, skip: 0
```

All four policies correctly reject it. The lone "pass" is `disallow-latest-tag`'s *other* rule (`require-image-tag`, checking that a tag is present at all) - `nginx:latest` does have a tag, it's just the disallowed one, so that rule passes while its sibling `validate-image-tag` fails; not a false negative on the demo manifest as a whole.

The real chart, checked the same way (also confirms both environments actually comply, not just the demo manifest):

```bash
helm template user-mgmt-service ../helm/user-mgmt-service -f ../helm/user-mgmt-service/values-staging.yaml \
  -s templates/backend-deployment.yaml -s templates/frontend-deployment.yaml > /tmp/staging.yaml
helm template user-mgmt-service ../helm/user-mgmt-service -f ../helm/user-mgmt-service/values-prod.yaml \
  -s templates/backend-deployment.yaml -s templates/frontend-deployment.yaml > /tmp/prod.yaml
kyverno apply kyverno-policies/*.yaml --resource /tmp/staging.yaml --resource /tmp/prod.yaml
# pass: 20, fail: 0, warn: 0, error: 0, skip: 0
```

The k6 load-test Job (`loadtest/k6-job.yaml`, with `namespace: user-mgmt-staging` added) passes too: `pass: 4, fail: 0`.

One gotcha hit while writing `require-probes.yaml`: an early version used `readinessProbe: "?*"` / `livenessProbe: "?*"` to check presence, which passed the CLI's own policy validation but **silently failed against real Deployments that do have both probes** - `"?*"` is a string-wildcard pattern (works for `require-requests-limits`' `memory: "?*"`, since `memory` is a string), but `readinessProbe`/`livenessProbe` are objects, and Kyverno's pattern matching doesn't coerce an object into that check the way you'd hope. Fixed by matching `{}` (empty object = "must exist as an object") instead. Caught here only because the real chart was tested against the policy, not just the intentionally-bad demo manifest - a reminder that a policy that correctly rejects a bad resource can still be silently wrong for the resources it's supposed to let through.

Also worth knowing: the CLI (and cluster-side Kyverno) prints a deprecation warning for `kyverno.io/v1 ClusterPolicy`, pointing at newer CEL-based policy CRDs (`ValidatingPolicy`, etc. under `policies.kyverno.io`). `ClusterPolicy` is still fully supported as of chart 3.9.1 - not an error, just a heads-up that the pattern-based policy language used here is the older (but still current, still most-documented) of two ways to write Kyverno policies.
