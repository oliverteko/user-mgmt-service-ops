# user-mgmt-service Helm Chart

Helm Chart für `user-mgmt-service` (Spring Boot Backend, Next.js Frontend, PostgreSQL). Ersetzt die statischen Manifeste in [`k8s/`](../../k8s) — sämtliche Konfiguration läuft zentral über `values.yaml`, keine Werte sind in den Templates hartcodiert.

## Voraussetzungen

Wie bisher in [`k8s/README.md`](../../k8s/README.md) beschrieben: laufender Kubernetes-Cluster, Traefik installiert (`ingressClassName: traefik`), Images in einer erreichbaren Registry (GHCR).

## Chart-Struktur

```
helm/user-mgmt-service/
  Chart.yaml
  values.yaml          # zentrale Default-Konfiguration (produktionsnah, DOKS)
  values-dev.yaml       # Beispiel-Overlay für eine lokale/dev-Umgebung
  templates/
    _helpers.tpl         # wiederverwendbare Label-/Name-/Image-Helper
    namespace.yaml
    configmap.yaml
    secret.yaml
    postgres-pvc.yaml
    postgres-deployment.yaml
    postgres-service.yaml
    backend-deployment.yaml
    backend-service.yaml
    frontend-deployment.yaml
    frontend-service.yaml
    ingress-frontend.yaml
    NOTES.txt
```

Ressourcennamen (`postgres`, `backend`, `frontend`, `app-config`, `app-secret`) bleiben bewusst literal statt release-präfigiert, da die App-Konfiguration selbst DNS-Namen wie `postgres:5432` referenziert. Details dazu als Kommentar in `_helpers.tpl`.

## Konfiguration

Alle Werte werden über `values.yaml` gesteuert. Wichtige Abschnitte:

- `postgres.*`, `backend.*`, `frontend.*` — Image, Replicas, Resources, Probes je Komponente.
- `config.*` — Werte für die ConfigMap `app-config` (DB-URL, JWT-Settings, etc.).
- `secret.*` — siehe "Secrets" unten.
- `ingress.*` — IngressClass, Enable/Disable.

### Umgebungen

`values.yaml` liefert produktionsnahe Defaults. Für andere Umgebungen ein schlankes Overlay anlegen, das nur Abweichungen enthält (Beispiel: [`values-dev.yaml`](values-dev.yaml)):

```bash
helm upgrade --install user-mgmt-service ./helm/user-mgmt-service \
  --namespace user-mgmt --create-namespace \
  -f helm/user-mgmt-service/values-dev.yaml
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
   Das ist der empfohlene Modus für den bestehenden DOKS-Produktionscluster (siehe [`k8s/README.md`](../../k8s/README.md)).

### Ingress

- `ingress.enabled: false` deaktiviert das Ingress-Objekt vollständig (z.B. für lokales `kubectl port-forward`).
- Die Ingress-Regel hat keinen `host` gesetzt und matched daher jede externe IP direkt — der Backend-Service ist nicht öffentlich exponiert, das Frontend proxied alle Backend-Aufrufe serverseitig über eigene Next.js-API-Routes (`INTERNAL_API_URL`). Es gibt daher keinen Hostname-Bootstrap und keine Traefik-Middleware mehr.

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

# dev-Overlay
helm lint ./helm/user-mgmt-service -f helm/user-mgmt-service/values-dev.yaml
helm template user-mgmt-service ./helm/user-mgmt-service -f helm/user-mgmt-service/values-dev.yaml

# Optional: Client-seitige Schema-Validierung
helm template user-mgmt-service ./helm/user-mgmt-service | kubectl apply --dry-run=client -f -
```

## Deployment

```bash
helm upgrade --install user-mgmt-service ./helm/user-mgmt-service \
  --namespace user-mgmt --create-namespace \
  --set secret.create=false
```

(`secret.create=false`, sofern `app-secret` bereits imperativ im Cluster existiert — siehe "Secrets" oben.)

## Follow-up (nicht Teil des aktuellen Charts)

Die CI (`.github/workflows/build-and-push.yml`) nutzt aktuell weiterhin `kubectl apply -f k8s/*.yaml` gegen die alten statischen Manifeste. Eine Umstellung des `deploy`-Jobs auf `helm upgrade --install` ist als separater Folge-Task vorgesehen.
