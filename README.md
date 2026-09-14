# user-mgmt-service-ops

Ops Repository für `user-mgmt-service` — GitOps-Deployment via [ArgoCD](https://argo-cd.readthedocs.io/). Enthält den Helm Chart (`helm/user-mgmt-service/`, verschoben aus dem [App-Repo](https://github.com/oliverteko/user_mgmt_service)) und die ArgoCD Application Manifests (`argocd/application-staging.yaml`, `argocd/application-prod.yaml`).

Dieses Repo ist die **einzige Quelle der Wahrheit** für den Cluster-Zustand von `user-mgmt-service`: ArgoCD beobachtet `main` und gleicht den Cluster automatisch mit dem hier deklarierten Zustand ab (`syncPolicy.automated` mit `prune` + `selfHeal`).

## Architektur

- **Namespace `argocd`**: ArgoCD selbst (Controller, Server, Repo-Server, Dashboard).
- **Namespace `user-mgmt-staging`**: Staging-Umgebung — von ArgoCD über den Helm Chart mit `values-staging.yaml` gerendert und angewendet.
- **Namespace `user-mgmt-prod`**: Prod-Umgebung — derselbe Chart mit `values-prod.yaml`.
- **Namespace `monitoring`**: kube-prometheus-stack (Prometheus, Grafana, Alertmanager) — verwaltet über eine eigene ArgoCD Application ([`argocd/application-monitoring.yaml`](argocd/application-monitoring.yaml)), konfiguriert über [`helm/kube-prometheus-stack/values.yaml`](helm/kube-prometheus-stack/README.md). Überwacht Pods in allen Namespaces (u.a. CPU/Memory) sowie speziell den `backend` in `user-mgmt-staging`/`user-mgmt-prod` über dessen `ServiceMonitor`/`PrometheusRule` (siehe [Monitoring-Sektion der Chart-README](helm/user-mgmt-service/README.md#monitoring)).
- **[`loadtest/`](loadtest/README.md)**: k6 Load Test gegen `user-mgmt-staging`, läuft als einmaliger Kubernetes `Job` (nicht ArgoCD-verwaltet) und verifiziert, dass der backend-HPA unter Last hoch- und danach wieder runterskaliert.
- Staging und Prod laufen **parallel im selben Cluster**, sind aber durch `ResourceQuota` (harte CPU-/Memory-Obergrenzen je Namespace) und `NetworkPolicy` (kein Netzwerkzugriff zwischen den Namespaces) voneinander isoliert — Details in [`helm/user-mgmt-service/README.md`](helm/user-mgmt-service/README.md#staging-vs-prod).
- **`app-secret`** wird bewusst **nicht** von ArgoCD verwaltet (`secret.create: false` in beiden Application-Manifesten) — echte Zugangsdaten landen nie in Git. Das Secret wird in jedem Namespace separat imperativ im Cluster gehalten (siehe App-Repo, `argocd-bootstrap.yml`-Workflow).
- **PostgreSQL** läuft nicht mehr als Pod in diesem Chart, sondern als DigitalOcean Managed Database — per Terraform provisioniert (`terraform/database.tf`), nicht per Helm. Details in [`helm/user-mgmt-service/README.md`](helm/user-mgmt-service/README.md#managed-database).
- **Namespace `policy`**: [Kyverno](https://kyverno.io/) (Policy as Code) — erzwingt (`validationFailureAction: Enforce`) mindestens vier ClusterPolicies gegen alle `user-mgmt-*`-Namespaces (Requests/Limits, kein `:latest`-Tag, `runAsNonRoot`, Readiness-/Liveness-Probes). Details in [`kyverno-policies/README.md`](kyverno-policies/README.md), inkl. Nachweis, dass ein absichtlich ungültiges Deployment abgelehnt wird.

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

# Kyverno erst, dann die ClusterPolicies (letztere brauchen Kyvernos CRDs -
# automated sync + selfHeal holt einen kurzen Wettlauf beim ersten Bootstrap
# von selbst nach, siehe kyverno-policies/README.md)
kubectl apply -f argocd/application-kyverno.yaml
kubectl apply -f argocd/application-kyverno-policies.yaml
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

Im Dashboard erscheinen die separaten Applications: `user-mgmt-service-staging`, `user-mgmt-service-prod`, `kyverno` und `kyverno-policies`.

## GitOps-Workflow testen

1. In `helm/user-mgmt-service/values-staging.yaml` (oder `values.yaml` für beide Umgebungen gleichzeitig) z.B. `backend.replicaCount` ändern.
2. Committen und nach `main` pushen.
3. Im Dashboard (oder `kubectl get application -n argocd -w`) beobachten: die betroffene Application erkennt die Abweichung (`OutOfSync`) und synchronisiert automatisch (`Synced`).
4. Verifizieren: `kubectl get deploy backend -n user-mgmt-staging` zeigt die neue Replica-Zahl.

Kein manueller `helm upgrade`/`kubectl apply` mehr nötig — jede Änderung an `values.yaml`/`values-staging.yaml`/`values-prod.yaml` oder den Templates in diesem Repo wird automatisch übernommen. Der `promote`-Job in `build-and-push.yml` (App-Repo) aktualisiert bei jedem Build automatisch den Image-Tag in `values.yaml` — das betrifft **beide** Umgebungen gleichzeitig, da sie den Tag von dort erben.

## Chart-Dokumentation

Siehe [`helm/user-mgmt-service/README.md`](helm/user-mgmt-service/README.md) für Details zu Konfiguration, Secrets-Handling, Ingress sowie Staging/Prod-Isolation (ResourceQuota, NetworkPolicy).

## Infrastructure as Code

[`terraform/`](terraform/README.md) verwaltet zwei DigitalOcean-Ressourcen deklarativ:

- Den bestehenden Kubernetes Cluster selbst (die Ebene *unterhalb* von ArgoCD/Helm — der Cluster, den `argocd-bootstrap.yml` bisher nur imperativ per `doctl` erwartet), per Config-Driven Import statt Neuerstellung.
- Die Managed PostgreSQL Database (neu, per Terraform **erstellt**, nicht importiert) — ersetzt den vormaligen Postgres-Pod in `helm/user-mgmt-service`.

Siehe die README dort für Details.

## Policy as Code

[`kyverno-policies/`](kyverno-policies/README.md) — vier `ClusterPolicy`-Objekte, deklarativ in diesem Repo, `Enforce` statt nur `Audit`. Installation von Kyverno selbst über [`helm/kyverno/values.yaml`](helm/kyverno/values.yaml). Die README dort dokumentiert auch den tatsächlich durchgeführten Nachweis (Kyverno CLI, offline, ohne Cluster), dass ein absichtlich ungültiges Deployment von allen vier Policies abgelehnt wird, während die echten `backend`/`frontend`-Deployments dieses Charts sauber durchlaufen.
