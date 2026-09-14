# kube-prometheus-stack

Deklarative Konfiguration für den [prometheus-community/kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) Helm Chart (Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics). Der Chart selbst wird **nicht** in diesem Repo vendored — nur [`values.yaml`](values.yaml) liegt hier; [`argocd/application-monitoring.yaml`](../../argocd/application-monitoring.yaml) zieht den Chart als zweite Source direkt aus dem `prometheus-community` Helm-Repo (Multi-Source Application) und rendert ihn mit dieser `values.yaml`.

## Was läuft hier

- **Namespace `monitoring`** — eigener, dedizierter Namespace (per `CreateNamespace=true` in der ArgoCD Application angelegt).
- **Prometheus** — `serviceMonitorSelectorNilUsesHelmValues: false` / `ruleSelectorNilUsesHelmValues: false`, damit auch ServiceMonitor/PrometheusRule-Objekte aus fremden Helm-Releases (z.B. `helm/user-mgmt-service`, siehe [dessen README](../user-mgmt-service/README.md#monitoring)) erkannt werden, nicht nur die dieses Releases.
- **Grafana** — `defaultDashboardsEnabled: true` liefert die vorgefertigten Kubernetes-Dashboards (u.a. Pod-CPU/-Memory pro Namespace) direkt mit; zusätzlich ein eigenes Dashboard `user-mgmt-service / Backend HTTP` (Request Rate, durchschnittliche Response Time, 5xx-Error-Rate), provisioniert über `grafana.dashboards` in `values.yaml`. Erreichbar über Ingress (`grafana.user-mgmt.local`, Traefik).
- **Alertmanager** — ein generischer Webhook-Receiver; die Webhook-URL kommt aus dem Secret `alertmanager-webhook` im Namespace `monitoring` (imperativ angelegt über `argocd-bootstrap.yml` im App-Repo, aus dem GitHub Secret `ALERTMANAGER_WEBHOOK_URL` — landet nie in Git, analog zu `app-secret`).

## ArgoCD-Besonderheit: `ServerSideApply=true`

Die CRDs dieses Charts (ServiceMonitor, PrometheusRule, Alertmanager, ...) überschreiten das 262144-Byte-Limit der `kubectl.kubernetes.io/last-applied-configuration`-Annotation, die Client-Side-Apply verwendet. `argocd/application-monitoring.yaml` setzt deshalb `syncOptions: [ServerSideApply=true]`.

## Verifikation

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 91.2.3 -f helm/kube-prometheus-stack/values.yaml -n monitoring
```

## Zugriff

```bash
kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d
```

Login (`admin` / obiges Passwort) über `http://grafana.user-mgmt.local/` (Host-Header/`/etc/hosts` auf die Traefik-LoadBalancer-IP, analog zu [`staging.user-mgmt.local`](../user-mgmt-service/README.md#staging-vs-prod)) oder per Port-Forward:

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```
