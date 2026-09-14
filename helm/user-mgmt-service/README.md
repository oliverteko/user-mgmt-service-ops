# user-mgmt-service Helm Chart

Helm Chart für `user-mgmt-service` (Spring Boot Backend, Next.js Frontend, PostgreSQL). Ersetzt die statischen Manifeste in [`k8s/`](../../k8s) — sämtliche Konfiguration läuft zentral über `values.yaml`, keine Werte sind in den Templates hartcodiert.

## Voraussetzungen

Wie bisher in [`k8s/README.md`](../../k8s/README.md) beschrieben: laufender Kubernetes-Cluster, Traefik installiert (`ingressClassName: traefik`), Images in einer erreichbaren Registry (GHCR).

## Chart-Struktur

```
helm/user-mgmt-service/
  Chart.yaml
  values.yaml           # zentrale Default-Konfiguration (produktionsnah, DOKS)
  values-dev.yaml        # Beispiel-Overlay für eine lokale/dev-Umgebung
  values-staging.yaml    # Overlay für die Staging-Umgebung (eigener Namespace)
  values-prod.yaml       # Overlay für die Prod-Umgebung (eigener Namespace)
  templates/
    _helpers.tpl         # wiederverwendbare Label-/Name-/Image-Helper
    namespace.yaml
    configmap.yaml
    secret.yaml
    resourcequota.yaml
    networkpolicy.yaml
    hpa.yaml
    pdb.yaml
    postgres-pvc.yaml
    postgres-deployment.yaml
    postgres-service.yaml
    backend-deployment.yaml
    backend-service.yaml
    frontend-deployment.yaml
    frontend-service.yaml
    ingress-frontend.yaml
    servicemonitor.yaml
    prometheusrule.yaml
    NOTES.txt
```

Ressourcennamen (`postgres`, `backend`, `frontend`, `app-config`, `app-secret`) bleiben bewusst literal statt release-präfigiert, da die App-Konfiguration selbst DNS-Namen wie `postgres:5432` referenziert. Details dazu als Kommentar in `_helpers.tpl`.

## Konfiguration

Alle Werte werden über `values.yaml` gesteuert. Wichtige Abschnitte:

- `postgres.*`, `backend.*`, `frontend.*` — Image, Replicas, Resources, Probes je Komponente.
- `config.*` — Werte für die ConfigMap `app-config` (DB-URL, JWT-Settings, etc.).
- `secret.*` — siehe "Secrets" unten.
- `ingress.*` — IngressClass, Enable/Disable, optionaler `host`.
- `resourceQuota.*` — harte CPU-/Memory-Obergrenzen für den gesamten Namespace (siehe "Staging vs. Prod" unten).
- `networkPolicy.*` — Netzwerk-Isolation zwischen Namespaces (siehe "Staging vs. Prod" unten).
- `backend.autoscaling.*`, `backend.pdb.*`, `frontend.pdb.*` — Autoscaling und Pod Disruption Budgets (siehe "Hochverfügbarkeit & Autoscaling" unten).
- `monitoring.*` — ServiceMonitor/PrometheusRule für den Backend (siehe "Monitoring" unten).

### Umgebungen

`values.yaml` liefert produktionsnahe Defaults. Für andere Umgebungen ein schlankes Overlay anlegen, das nur Abweichungen enthält (Beispiel: [`values-dev.yaml`](values-dev.yaml)):

```bash
helm upgrade --install user-mgmt-service ./helm/user-mgmt-service \
  --namespace user-mgmt --create-namespace \
  -f helm/user-mgmt-service/values-dev.yaml
```

### Staging vs. Prod

`values-staging.yaml` und `values-prod.yaml` deployen dieselbe Anwendung parallel im selben Cluster, jede in ihrem eigenen Namespace (`user-mgmt-staging` / `user-mgmt-prod`) — verwaltet über zwei getrennte ArgoCD Applications ([`argocd/application-staging.yaml`](../../argocd/application-staging.yaml), [`argocd/application-prod.yaml`](../../argocd/application-prod.yaml)). Drei Mechanismen sorgen für die Trennung:

1. **Namespace** — jedes Overlay setzt ein eigenes `namespace:`, alle Ressourcennamen bleiben zwar literal (siehe oben), kollidieren aber nicht, da sie in unterschiedlichen Namespaces liegen.
2. **`resourceQuota`** — jeder Namespace bekommt ein hartes CPU-/Memory-Limit (`requests.cpu/memory`, `limits.cpu/memory`), damit eine Umgebung die andere nicht durch Ressourcenverbrauch beeinträchtigen kann. Staging ist bewusst enger limitiert als Prod.
3. **`networkPolicy`** — jeder Namespace bekommt eine `NetworkPolicy`, die eingehenden Traffic auf Pods im selben Namespace sowie auf den Ingress-Controller (`networkPolicy.ingressNamespace`, Default `traefik`) beschränkt. Da beide Umgebungen dieselbe Policy erhalten, blockiert das den Zugriff in beide Richtungen — Staging kann nicht auf Prod-Pods zugreifen und umgekehrt.
4. **`ingress.host`** — da beide Umgebungen denselben Traefik-Controller teilen, braucht mindestens eine Umgebung einen expliziten Host, damit sich die Ingress-Regeln nicht überschneiden. Staging nutzt `staging.user-mgmt.local`, Prod bleibt hostless (heutiges Verhalten).

Testen der Isolation nach dem Deployment (temporärer Test-Pod, da die App-Container kein `wget`/`curl` enthalten). Der Pod braucht **explizite `resources`**, sonst lehnt die `ResourceQuota` ihn ab (`must specify limits.cpu for: ...`) — das ist Standard-Kubernetes-Verhalten, sobald eine ResourceQuota `requests`/`limits` im Namespace vorschreibt:
```bash
kubectl run netpol-test --rm -i --restart=Never -n user-mgmt-staging --image=busybox:1.36 \
  --overrides='{"spec":{"containers":[{"name":"netpol-test","image":"busybox:1.36","command":["sh","-c","wget -qO- --timeout=3 http://frontend.user-mgmt-prod.svc.cluster.local:3000; echo prod exit: $?; wget -qO- --timeout=3 http://frontend.user-mgmt-staging.svc.cluster.local:3000 >/dev/null; echo staging exit: $?"],"resources":{"requests":{"cpu":"10m","memory":"16Mi"},"limits":{"cpu":"50m","memory":"32Mi"}}}]}}'
# Erwartung: "prod exit: 1" (Timeout, blockiert), "staging exit: 0" (funktioniert)
```

### Secrets

`values.yaml` enthält **nur Platzhalter** (`REPLACE_ME`) — es dürfen nie echte Secret-Werte committet werden. Zwei Modi über `secret.create`:

1. **Chart-managed (Default, `secret.create: true`)**: echte Werte zur Install-/Upgrade-Zeit übergeben, z.B.:
   ```bash
   helm upgrade --install user-mgmt-service ./helm/user-mgmt-service \
     --set secret.dbUsername=postgres \
     --set secret.dbPassword="$DB_PASSWORD" \
     --set secret.jwtSecret="$JWT_SECRET"
   ```
   Alternativ eine **gitignorte** `values-secret.yaml` mit den echten Werten anlegen und per `-f values-secret.yaml` übergeben.
2. **Extern verwaltet (`secret.create: false`)**: Chart rendert kein Secret-Objekt; erwartet ein bereits im Cluster vorhandenes Secret (Name über `secret.name`), z.B. imperativ angelegt:
   ```bash
   kubectl create secret generic app-secret -n user-mgmt \
     --from-literal=DB_USERNAME=postgres \
     --from-literal=DB_PASSWORD='<echtes-passwort>' \
     --from-literal=JWT_SECRET='<echtes-jwt-secret>'
   ```
   Das ist der Modus, den `argocd/application-staging.yaml` und `argocd/application-prod.yaml` setzen — die echten Werte kommen über den `argocd-bootstrap.yml`-Workflow im App-Repo (`kubectl create secret`, aus GitHub Secrets, je Namespace).

### Ingress

- `ingress.enabled: false` deaktiviert das Ingress-Objekt vollständig (z.B. für lokales `kubectl port-forward`).
- `ingress.host` leer (Default): Die Ingress-Regel hat keinen `host` gesetzt und matched daher jeden eingehenden Host-Header — praktisch für eine einzelne Umgebung ohne bekannten Hostnamen. Der Backend-Service ist ohnehin nicht öffentlich exponiert, das Frontend proxied alle Backend-Aufrufe serverseitig über eigene Next.js-API-Routes (`INTERNAL_API_URL`).
- Sobald mehrere Umgebungen denselben Ingress-Controller teilen (siehe "Staging vs. Prod"), braucht mindestens eine davon einen expliziten `ingress.host`, damit sich die Regeln nicht überschneiden.

## Monitoring

`monitoring.enabled` (Default `true`) rendert für den Backend:

- **`templates/servicemonitor.yaml`** — lässt Prometheus (kube-prometheus-stack, separat installiert über [`helm/kube-prometheus-stack`](../kube-prometheus-stack) + [`argocd/application-monitoring.yaml`](../../argocd/application-monitoring.yaml)) `/actuator/prometheus` auf dem `backend`-Service (Port `http`) scrapen. Voraussetzung im App-Repo: `spring-boot-starter-actuator` + `micrometer-registry-prometheus` auf dem Classpath, `management.endpoints.web.exposure.include=health,prometheus`, sowie `permitAll()` für `/actuator/health/**` und `/actuator/prometheus` in `WebSecurityConfig`.
- **`templates/prometheusrule.yaml`** — Alert `BackendHighErrorRate`: feuert, wenn der Anteil an 5xx-Antworten über `monitoring.errorRate.threshold` (Default 5%) liegt, gemessen über `monitoring.errorRate.window` (Default 5m), für mindestens `monitoring.errorRate.for` (Default 5m) am Stück.
- **`networkpolicy.yaml`** lässt zusätzlich Ingress-Traffic aus dem `monitoring`-Namespace zu (`monitoring.namespace`) — ohne diese Ausnahme würde `deny-cross-namespace` die Scrapes blockieren, da ServiceMonitor-Scrapes die Pods direkt (nicht über den Service) ansprechen.

kube-prometheus-stack selbst (Prometheus, Grafana, Alertmanager) läuft als eigene ArgoCD Application im dedizierten Namespace `monitoring`, konfiguriert über eine eigene `values.yaml` — siehe [`helm/kube-prometheus-stack/`](../kube-prometheus-stack).

## Hochverfügbarkeit & Autoscaling

- **`backend.autoscaling`** — ein `HorizontalPodAutoscaler` (`templates/hpa.yaml`) skaliert `backend` zwischen `minReplicas` und `maxReplicas` anhand von CPU-Auslastung (`targetCPUUtilizationPercentage`). Braucht `metrics-server` im Cluster (installiert von `argocd-bootstrap.yml`). Nur in Prod aktiv (`values.yaml`) — in Staging deaktiviert (`values-staging.yaml`), da dort nur eine Replica läuft und Autoscaling keinen Sinn ergäbe. Solange `backend.autoscaling.enabled: true` ist, lässt das Deployment-Template `spec.replicas` bewusst weg, damit Helm dem HPA nicht ständig den Wert zurücksetzt; `argocd/application-prod.yaml` ignoriert dieses Feld zusätzlich explizit (`ignoreDifferences`), damit ArgoCDs `selfHeal` die Skalierung nicht revertiert.
- **`backend.pdb` / `frontend.pdb`** — je ein `PodDisruptionBudget` garantiert bei Node-Wartung/-Drain eine Mindestanzahl (`minAvailable`) laufender Replicas. Nur sinnvoll bei >1 Replica — in Staging (1 Replica je Komponente) deaktiviert, sonst würde die PDB jede freiwillige Disruption blockieren.
- **RollingUpdate** — `backend`- und `frontend`-Deployment setzen explizit `strategy.type: RollingUpdate` mit `maxUnavailable: 0, maxSurge: 1`: bei einem Update entsteht immer erst der neue Pod, bevor der alte terminiert wird, nie weniger bereite Replicas als vorher — keine Service-Unterbrechung während Rollouts.
- **Requests/Limits + Probes** — Voraussetzung für alles oben: jede Komponente (auch Postgres) deklariert `resources.requests`/`limits` (siehe `values.yaml`) sowie `readinessProbe`/`livenessProbe` (siehe jeweiliges `*-deployment.yaml`). Der HPA braucht `requests.cpu` als Berechnungsgrundlage; die `ResourceQuota` erzwingt zusätzlich, dass *jeder* Pod im Namespace Requests/Limits angibt (siehe "Staging vs. Prod").
- **Load Balancing** — keine zusätzliche Konfiguration nötig: der `frontend`/`backend`-Service verteilt Traffic bereits per Round Robin auf alle Pods, deren `readinessProbe` grün ist (Standard-Kubernetes-Service-Verhalten); Traefik routet über den Service, nicht direkt auf Pods, übernimmt also automatisch dieselbe Ready-Filterung.

Skalierung beobachten:
```bash
kubectl get hpa backend -n user-mgmt-prod -w
kubectl get pdb -n user-mgmt-prod
```

## Verifikation

```bash
# Lint (muss ohne Fehler durchlaufen)
helm lint ./helm/user-mgmt-service
helm lint ./helm/user-mgmt-service --strict

# Rendering prüfen (Default-Werte)
helm template user-mgmt-service ./helm/user-mgmt-service

# Gating-Kombinationen einzeln durchspielen
helm template user-mgmt-service ./helm/user-mgmt-service --set secret.create=false
helm template user-mgmt-service ./helm/user-mgmt-service --set ingress.enabled=false

# dev/staging/prod-Overlays
helm lint ./helm/user-mgmt-service -f helm/user-mgmt-service/values-dev.yaml
helm lint ./helm/user-mgmt-service -f helm/user-mgmt-service/values-staging.yaml
helm lint ./helm/user-mgmt-service -f helm/user-mgmt-service/values-prod.yaml
helm template user-mgmt-service ./helm/user-mgmt-service -f helm/user-mgmt-service/values-staging.yaml

# Optional: Client-seitige Schema-Validierung
helm template user-mgmt-service ./helm/user-mgmt-service | kubectl apply --dry-run=client -f -
```

## Deployment

In der Praxis übernimmt das ArgoCD (siehe `argocd/application-staging.yaml` / `argocd/application-prod.yaml` und `argocd-bootstrap.yml` im App-Repo). Manuell/lokal äquivalent:

```bash
helm upgrade --install user-mgmt-service ./helm/user-mgmt-service \
  -f helm/user-mgmt-service/values-staging.yaml \
  --namespace user-mgmt-staging --create-namespace \
  --set secret.create=false
```

(`secret.create=false`, sofern `app-secret` bereits imperativ im Cluster existiert — siehe "Secrets" oben.)
