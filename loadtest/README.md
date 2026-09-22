# k6 Load Test

Verifies that the backend HPA ([`helm/user-mgmt-service/templates/hpa.yaml`](../helm/user-mgmt-service/templates/hpa.yaml)) actually scales under load, scales back down once load drops, and that the service stays available (requests spread across whatever replicas exist) throughout. Runs as a one-off Kubernetes `Job` — **not** ArgoCD-managed, since a load test is an on-demand action, not continuously-reconciled state.

Targets **staging** (`user-mgmt-staging`) by default: `values-staging.yaml` enables autoscaling (`minReplicas: 1`, `maxReplicas: 3`) specifically so this has something to scale, without generating artificial load against prod.

## Prerequisites

- `helm/user-mgmt-service` deployed to `user-mgmt-staging` with the current `values-staging.yaml` (HPA enabled) — see the [ops repo README](../README.md).
- `kube-prometheus-stack` deployed ([`argocd/application-monitoring.yaml`](../argocd/application-monitoring.yaml)) — the Job pushes its own metrics there via Prometheus remote-write.
- `metrics-server` in the cluster (already required by the HPA itself, installed by `argocd-bootstrap.yml` in the App-Repo).

## Run it

```bash
# 1. Load the test script into a ConfigMap (re-run this if you edit login-loadtest.js)
kubectl create configmap k6-login-loadtest-script \
  --from-file=login-loadtest.js=loadtest/login-loadtest.js \
  -n user-mgmt-staging \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. Start the load test
kubectl apply -f loadtest/k6-job.yaml -n user-mgmt-staging
```

Full run takes ~8 minutes (ramp to 5 VUs, ramp to 15, hold 15 for 3 min, ramp down, then a 3 min zero-load hold so scale-down has time to clear staging's 60s HPA stabilization window). Apply the Job with `-n user-mgmt-staging` — the manifest has no namespace of its own. For a quick ~90s dry run, uncomment `QUICK_TEST: "true"` in `k6-job.yaml` before applying — that profile is too short to reliably trigger scale-down, only scale-up.

## Watch it happen

```bash
# k6's own progress/summary
kubectl logs -f job/k6-login-loadtest -n user-mgmt-staging

# HPA reacting (watch DESIRED/CURRENT replicas change)
kubectl get hpa backend -n user-mgmt-staging -w

# Pods actually coming up/down
kubectl get pods -n user-mgmt-staging -l app.kubernetes.io/component=backend -w
```

In Grafana, open **user-mgmt-service / Load Test & HPA** (provisioned automatically, see [`helm/kube-prometheus-stack/values.yaml`](../helm/kube-prometheus-stack/values.yaml)) and set the time range to cover the run. It plots, side by side: active k6 VUs, HPA desired vs. current replicas, actual pod replica count, request rate, average response time, and 5xx error rate — so the causal chain (load up → CPU up → HPA scales → replicas up → load down → HPA scales back down) is visible in one place.

## What "stays available during scaling" means here

- k6's `http_req_failed` / `login_errors` thresholds (see `login-loadtest.js`) fail the run if the error rate exceeds 5% at any point — including during scale-up/down, when pods are being added or terminated.
- Requests are never sent to a specific pod: the Job targets the `backend` **Service** (`http://backend:8080`), so Kubernetes' own Service round-robin (`kube-proxy`) is what distributes load across whichever replicas are currently `Ready` — new pods only receive traffic once their `readinessProbe` passes, and terminating pods stop receiving new traffic before shutdown. No extra strategy configuration is needed on the client side.
- The **Error Rate (5xx)** panel on the Grafana dashboard above should stay near zero for the whole run, including the scaling transitions, as visual confirmation.

## Clean up / re-run

```bash
kubectl delete job k6-login-loadtest -n user-mgmt-staging --ignore-not-found
# then re-apply loadtest/k6-job.yaml to run again
```

(`ttlSecondsAfterFinished: 3600` on the Job also auto-deletes it an hour after it finishes, if you forget.)

## Module service load test (Task 6, vertical scaling)

[`module-loadtest.js`](module-loadtest.js) / [`module-k6-job.yaml`](module-k6-job.yaml) - 40 VUs (ramp 30s to 10, 1m to 40, hold 3m) that each list the modules (`GET /modules`) and assign one to a test user (`PUT /users/{id}/modules/{moduleId}`), **through the backend** like a real client (the module_service only accepts traffic from the backend, NetworkPolicy `module-service-ingress`). Each iteration = 3 module_service requests behind the backend's timeout/retry/circuit breaker.

```bash
kubectl create configmap k6-module-loadtest-script -n user-mgmt-staging   --from-file=loadtest/module-loadtest.js --dry-run=client -o yaml | kubectl apply -f -
kubectl delete job k6-module-loadtest -n user-mgmt-staging --ignore-not-found
kubectl apply -n user-mgmt-staging -f loadtest/module-k6-job.yaml
```

Watch Grafana "user-mgmt-service / Module Service" while it runs. Results on staging (1 module_service replica, 2026-09-22):

| | limit 500m CPU / 256Mi | limit **1 CPU** / 256Mi (current) |
|---|---|---|
| Requests in 5 min / throughput | 5 938 / 19.6 req/s | 7 156 / 23.7 req/s |
| Failed requests / restarts | 0 / 0 | 0 / 0 |
| module_service CPU on the plateau | pinned at 500m | ~670m (below the limit) |
| module_service CPU throttled | 51 % of periods | 0.2 % |
| module_service server p95 | 0.22 s | 0.24 s |
| module_service memory | 64 -> 72 Mi | 64 -> 72 Mi |
| end-to-end median / p95 (k6) | 1.07 s / 3.61 s | 0.70 s / 3.32 s |

With 1 CPU the module_service is no longer the bottleneck. The remaining end-to-end latency (and the crossed `p(95)<1000` k6 threshold) comes from the backend waiting for its own PostgreSQL connections - `backend.dbPoolSize: 2`, kept small because the smallest managed PostgreSQL only allows ~22 connections for staging + prod together (Hikari acquire avg 0.44 s, up to 29 requests pending). Fixing that would need a larger database plan or a DigitalOcean connection pool (PgBouncer), not more module_service resources.
