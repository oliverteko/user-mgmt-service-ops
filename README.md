# user-mgmt-service-ops

Ops Repository für `user-mgmt-service` — GitOps-Deployment via [ArgoCD](https://argo-cd.readthedocs.io/). Enthält den Helm Chart (`helm/user-mgmt-service/`, verschoben aus dem [App-Repo](https://github.com/oliverteko/user_mgmt_service)) und die ArgoCD Application Manifests (`argocd/application-staging.yaml`, `argocd/application-prod.yaml`).

Dieses Repo ist die **einzige Quelle der Wahrheit** für den Cluster-Zustand von `user-mgmt-service`: ArgoCD beobachtet `main` und gleicht den Cluster automatisch mit dem hier deklarierten Zustand ab (`syncPolicy.automated` mit `prune` + `selfHeal`).

## Architektur

- **Namespace `argocd`**: ArgoCD selbst (Controller, Server, Repo-Server, Dashboard).
- **Namespace `user-mgmt-staging`**: Staging-Umgebung — von ArgoCD über den Helm Chart mit `values-staging.yaml` gerendert und angewendet.
- **Namespace `user-mgmt-prod`**: Prod-Umgebung — derselbe Chart mit `values-prod.yaml`.
- **Namespace `monitoring`**: kube-prometheus-stack (Prometheus, Grafana, Alertmanager) — verwaltet über eine eigene ArgoCD Application ([`argocd/application-monitoring.yaml`](argocd/application-monitoring.yaml)), konfiguriert über [`helm/kube-prometheus-stack/values.yaml`](helm/kube-prometheus-stack/README.md). Überwacht Pods in allen Namespaces (u.a. CPU/Memory) sowie speziell den `backend` in `user-mgmt-staging`/`user-mgmt-prod` über dessen `ServiceMonitor`/`PrometheusRule` (siehe [Monitoring-Sektion der Chart-README](helm/user-mgmt-service/README.md#monitoring)).
- Staging und Prod laufen **parallel im selben Cluster**, sind aber durch `ResourceQuota` (harte CPU-/Memory-Obergrenzen je Namespace) und `NetworkPolicy` (kein Netzwerkzugriff zwischen den Namespaces) voneinander isoliert — Details in [`helm/user-mgmt-service/README.md`](helm/user-mgmt-service/README.md#staging-vs-prod).
- **`app-secret`** wird bewusst **nicht** von ArgoCD verwaltet (`secret.create: false` in beiden Application-Manifesten) — echte Zugangsdaten landen nie in Git. Das Secret wird in jedem Namespace separat imperativ im Cluster gehalten (siehe App-Repo, `argocd-bootstrap.yml`-Workflow).

## Einmaliges Setup (Cluster-Bootstrap)

Im App-Repo automatisiert als `workflow_dispatch`-Workflow `argocd-bootstrap.yml` (installiert Traefik + ArgoCD, legt `app-secret` in beiden Namespaces an, wendet beide Applications an). Manuell entspricht das:

```bash
# ArgoCD installieren (eigener Namespace, getrennt von den App-Namespaces)
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace

# Applications anwenden — ArgoCD übernimmt ab hier das Deployment beider Umgebungen
kubectl apply -f argocd/application-staging.yaml
kubectl apply -f argocd/application-prod.yaml
kubectl apply -f argocd/application-monitoring.yaml
```

Voraussetzung: `app-secret` existiert bereits in den Namespaces `user-mgmt-staging` und `user-mgmt-prod`, sowie `alertmanager-webhook` im Namespace `monitoring` (siehe App-Repo `k8s/README.md` / `helm/user-mgmt-service/README.md`, Abschnitt "Secrets", bzw. [`helm/kube-prometheus-stack/README.md`](helm/kube-prometheus-stack/README.md)).

## Dashboard-Zugriff

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Dashboard unter `https://localhost:8080` (Self-signed-Zertifikat-Warnung ignorieren). Login:

- Username: `admin`
- Passwort (initial):
  ```bash
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
  ```

Im Dashboard erscheinen zwei separate Applications: `user-mgmt-service-staging` und `user-mgmt-service-prod`.

## GitOps-Workflow testen

1. In `helm/user-mgmt-service/values-staging.yaml` (oder `values.yaml` für beide Umgebungen gleichzeitig) z.B. `backend.replicaCount` ändern.
2. Committen und nach `main` pushen.
3. Im Dashboard (oder `kubectl get application -n argocd -w`) beobachten: die betroffene Application erkennt die Abweichung (`OutOfSync`) und synchronisiert automatisch (`Synced`).
4. Verifizieren: `kubectl get deploy backend -n user-mgmt-staging` zeigt die neue Replica-Zahl.

Kein manueller `helm upgrade`/`kubectl apply` mehr nötig — jede Änderung an `values.yaml`/`values-staging.yaml`/`values-prod.yaml` oder den Templates in diesem Repo wird automatisch übernommen. Der `promote`-Job in `build-and-push.yml` (App-Repo) aktualisiert bei jedem Build automatisch den Image-Tag in `values.yaml` — das betrifft **beide** Umgebungen gleichzeitig, da sie den Tag von dort erben.

## Chart-Dokumentation

Siehe [`helm/user-mgmt-service/README.md`](helm/user-mgmt-service/README.md) für Details zu Konfiguration, Secrets-Handling, Ingress sowie Staging/Prod-Isolation (ResourceQuota, NetworkPolicy).
