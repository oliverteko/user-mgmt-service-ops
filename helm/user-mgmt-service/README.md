# user-mgmt-service Helm Chart

Helm Chart für `user-mgmt-service` (Spring Boot Backend, Next.js Frontend). Ersetzt die statischen Manifeste in [`k8s/`](../../k8s) — sämtliche Konfiguration läuft zentral über `values.yaml`, keine Werte sind in den Templates hartcodiert. PostgreSQL läuft **nicht** mehr als Pod in diesem Chart, sondern als DigitalOcean Managed Database — siehe [`../../terraform/database.tf`](../../terraform/database.tf) und den Abschnitt "Managed Database" unten.

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
    backend-deployment.yaml
    backend-service.yaml
    frontend-deployment.yaml
    frontend-service.yaml
    ingress-frontend.yaml
    servicemonitor.yaml
    prometheusrule.yaml
    NOTES.txt
```

Ressourcennamen (`backend`, `frontend`, `app-config`, `app-secret`) bleiben bewusst literal statt release-präfigiert, da die App-Konfiguration selbst den DNS-Namen `http://backend:8080` referenziert. Details dazu als Kommentar in `_helpers.tpl`.

## Konfiguration

Alle Werte werden über `values.yaml` gesteuert. Wichtige Abschnitte:

- `backend.*`, `frontend.*` — Image, Replicas, Resources, Probes je Komponente.
- `database.*` — Verbindungsdaten zur Managed PostgreSQL Database, siehe "Managed Database" unten.
- `config.*` — restliche Werte für die ConfigMap `app-config` (JWT-Settings, etc.).
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
     --set secret.dbUsername="$(terraform -chdir=../../terraform output -raw database_user)" \
     --set secret.dbPassword="$(terraform -chdir=../../terraform output -raw database_password)" \
     --set secret.jwtSecret="$JWT_SECRET"
   ```
   Alternativ eine **gitignorte** `values-secret.yaml` mit den echten Werten anlegen und per `-f values-secret.yaml` übergeben.
2. **Extern verwaltet (`secret.create: false`)**: Chart rendert kein Secret-Objekt; erwartet ein bereits im Cluster vorhandenes Secret (Name über `secret.name`), z.B. imperativ angelegt:
   ```bash
   kubectl create secret generic app-secret -n user-mgmt \
     --from-literal=DB_USERNAME="$(terraform -chdir=../../terraform output -raw database_user)" \
     --from-literal=DB_PASSWORD="$(terraform -chdir=../../terraform output -raw database_password)" \
     --from-literal=JWT_SECRET='<echtes-jwt-secret>'
   ```
   Das ist der Modus, den `argocd/application-staging.yaml` und `argocd/application-prod.yaml` setzen — die echten Werte kommen über den `argocd-bootstrap.yml`-Workflow im App-Repo (`kubectl create secret`, aus GitHub Secrets, je Namespace). `DB_USERNAME`/`DB_PASSWORD` sind seit der Migration auf Managed PostgreSQL die von Terraform erzeugten Zugangsdaten des App-Users (siehe "Managed Database" unten), nicht mehr ein selbst gewähltes Passwort.

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

## Managed Database

PostgreSQL läuft als [DigitalOcean Managed Database](https://www.digitalocean.com/products/managed-databases-postgresql) statt als Pod in diesem Chart — provisioniert über Terraform ([`../../terraform/database.tf`](../../terraform/database.tf)), nicht über diesen Chart. Ein gemeinsamer Cluster für Staging und Prod, mit zwei getrennten logischen Datenbanken (`user_mgmt_staging` / `user_mgmt_prod`) und einem gemeinsamen App-User — Details und Begründung (Kosten vs. Isolation) im Kommentar dort.

- `database.host` / `database.port` / `database.sslMode` — kommen aus `terraform output database_host` / `database_port` (Managed Database erzwingt TLS, daher `sslmode=require`). Gemeinsam für alle Umgebungen (ein Cluster), Default in `values.yaml` ist ein Platzhalter (`REPLACE_ME.db.ondigitalocean.com`) bis die Datenbank tatsächlich provisioniert ist.
- `database.name` — die logische Datenbank innerhalb des Clusters, je Umgebung unterschiedlich (`values.yaml` = `user_mgmt_prod`, `values-staging.yaml` überschreibt auf `user_mgmt_staging`, analog zu `ingress.host`).
- `secret.dbUsername` / `secret.dbPassword` (bzw. `DB_USERNAME` / `DB_PASSWORD` im extern verwalteten `app-secret`) — kommen aus `terraform output database_user` / `database_password`, nicht mehr selbst gewählt (siehe "Secrets" oben).
- Erreichbarkeit: die Managed Database erlaubt per Firewall (`digitalocean_database_firewall` in `database.tf`) ausschliesslich Verbindungen vom DOKS-Cluster selbst (Rule-Type `k8s`, referenziert per Cluster-UUID) — kein `NetworkPolicy`-Eintrag in diesem Chart nötig, da `templates/networkpolicy.yaml` nur *Ingress* einschränkt, nicht *Egress*.
- `postgres-deployment.yaml`, `postgres-service.yaml`, `postgres-pvc.yaml` sowie der komplette `postgres.*`-Values-Block existieren nicht mehr in diesem Chart.

## Module Service (Aufgabe 6)

`moduleService.*` deployt den Python-`module_service` (Image aus dem App-Repo, `module_service/`) mit eigener DigitalOcean Managed MySQL ([`../../terraform/mysql.tf`](../../terraform/mysql.tf)):

- **`templates/module-service-deployment.yaml`** — Deployment, Service `module-service`, CA-Zertifikat der MySQL als ConfigMap (TLS mit Zertifikatsprüfung), PDB (nur Prod). Probes auf `/health/live` bzw. `/health/ready` (letztere prüft die DB-Verbindung). Non-root (UID 10001), erfüllt alle Kyverno-Policies.
- **Credentials** — nur dieses Deployment liest das Secret `module-service-secret` (`DB_PASSWORD`, von `argocd-bootstrap.yml` angelegt). Der Backend-Pod hat keine MySQL-Zugangsdaten und zusätzlich per NetworkPolicy `backend-egress` keinen Netzwerkzugang zur MySQL (`networkPolicy.backendEgressDenyCidrs`).
- **Nur das Backend darf den module_service aufrufen** — NetworkPolicy `module-service-ingress` (plus Prometheus). Das Backend ruft ihn synchron via REST über den Service `http://module-service:8080` auf, mit Timeout, Retry und Circuit Breaker (App-Repo, `ModuleServiceClient`).
- **Monitoring** — ServiceMonitor `module-service` scrapt `/metrics`; Grafana-Dashboard "user-mgmt-service / Module Service" (Request Rate, Response Time, Error Rate, CPU/Memory vs. Limits, Circuit Breaker, Retries).
- **Vertikale Skalierung** — `moduleService.resources` (1 CPU / 256Mi Limit) sind aus einem k6-Lasttest abgeleitet, siehe [`../../loadtest/README.md`](../../loadtest/README.md#module-service-load-test-task-6-vertical-scaling).

## Hochverfügbarkeit & Autoscaling

- **`backend.autoscaling`** — ein `HorizontalPodAutoscaler` (`templates/hpa.yaml`) skaliert `backend` zwischen `minReplicas` und `maxReplicas` anhand von CPU-Auslastung (`targetCPUUtilizationPercentage`). Braucht `metrics-server` im Cluster (installiert von `argocd-bootstrap.yml`). In Prod `2→4` Replicas, in Staging `1→3` — in Staging bewusst aktiviert (nicht deaktiviert wie ursprünglich), damit der [k6 Load Test](../../loadtest/README.md) dort tatsächlich etwas zu skalieren hat, ohne künstliche Last gegen Prod zu erzeugen. Solange `backend.autoscaling.enabled: true` ist, lässt das Deployment-Template `spec.replicas` bewusst weg, damit Helm dem HPA nicht ständig den Wert zurücksetzt; sowohl `argocd/application-staging.yaml` als auch `argocd/application-prod.yaml` ignorieren dieses Feld zusätzlich explizit (`ignoreDifferences`), damit ArgoCDs `selfHeal` die Skalierung nicht revertiert.
- **`backend.pdb` / `frontend.pdb`** — je ein `PodDisruptionBudget` garantiert bei Node-Wartung/-Drain eine Mindestanzahl (`minAvailable`) laufender Replicas. Nur sinnvoll bei >1 fest eingeplanter Replica — in Staging weiterhin deaktiviert (`minReplicas: 1`), sonst würde die PDB jede freiwillige Disruption blockieren.
- **RollingUpdate** — `backend`- und `frontend`-Deployment setzen explizit `strategy.type: RollingUpdate` mit `maxUnavailable: 0, maxSurge: 1`: bei einem Update entsteht immer erst der neue Pod, bevor der alte terminiert wird, nie weniger bereite Replicas als vorher — keine Service-Unterbrechung während Rollouts.
- **Requests/Limits + Probes** — Voraussetzung für alles oben: jede Komponente deklariert `resources.requests`/`limits` (siehe `values.yaml`) sowie `readinessProbe`/`livenessProbe` (siehe jeweiliges `*-deployment.yaml`). Der HPA braucht `requests.cpu` als Berechnungsgrundlage; die `ResourceQuota` erzwingt zusätzlich, dass *jeder* Pod im Namespace Requests/Limits angibt (siehe "Staging vs. Prod").
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
