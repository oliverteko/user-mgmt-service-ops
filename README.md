# user-mgmt-service-ops

Ops Repository für `user-mgmt-service` — GitOps-Deployment via [ArgoCD](https://argo-cd.readthedocs.io/). Enthält den Helm Chart (`helm/user-mgmt-service/`, verschoben aus dem [App-Repo](https://github.com/oliverteko/user_mgmt_service)) und das ArgoCD Application Manifest (`argocd/application.yaml`).

Dieses Repo ist die **einzige Quelle der Wahrheit** für den Cluster-Zustand von `user-mgmt-service`: ArgoCD beobachtet `main` und gleicht den Cluster automatisch mit dem hier deklarierten Zustand ab (`syncPolicy.automated` mit `prune` + `selfHeal`).

## Architektur

- **Namespace `argocd`**: ArgoCD selbst (Controller, Server, Repo-Server, Dashboard).
- **Namespace `user-mgmt`**: die eigentliche App (Backend, Frontend, Postgres) — von ArgoCD über den Helm Chart in `helm/user-mgmt-service/` gerendert und angewendet, komplett getrennt vom ArgoCD-Namespace.
- **`app-secret`** wird bewusst **nicht** von ArgoCD verwaltet (`secret.create: false` in `argocd/application.yaml`) — echte Zugangsdaten landen nie in Git. Das Secret wird imperativ im Cluster gehalten (siehe App-Repo, `argocd-bootstrap.yml`-Workflow).

## Einmaliges Setup (Cluster-Bootstrap)

Im App-Repo automatisiert als `workflow_dispatch`-Workflow `argocd-bootstrap.yml` (installiert Traefik + ArgoCD, legt `app-secret` an, wendet `argocd/application.yaml` an). Manuell entspricht das:

```bash
# ArgoCD installieren (eigener Namespace, getrennt von der App)
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace

# Application anwenden — ArgoCD übernimmt ab hier das Deployment von user-mgmt-service
kubectl apply -f argocd/application.yaml
```

Voraussetzung: `app-secret` existiert bereits im Namespace `user-mgmt` (siehe App-Repo `k8s/README.md` / `helm/user-mgmt-service/README.md`, Abschnitt "Secrets").

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

## GitOps-Workflow testen

1. In `helm/user-mgmt-service/values.yaml` z.B. `backend.replicaCount` ändern.
2. Committen und nach `main` pushen.
3. Im Dashboard (oder `kubectl get application user-mgmt-service -n argocd -w`) beobachten: ArgoCD erkennt die Abweichung (`OutOfSync`) und synchronisiert automatisch (`Synced`).
4. Verifizieren: `kubectl get deploy backend -n user-mgmt` zeigt die neue Replica-Zahl.

Kein manueller `helm upgrade`/`kubectl apply` mehr nötig — jede Änderung an `values.yaml` oder den Templates in diesem Repo wird automatisch übernommen.

## Chart-Dokumentation

Siehe [`helm/user-mgmt-service/README.md`](helm/user-mgmt-service/README.md) für Details zu Konfiguration, Secrets-Handling und Ingress.
