# Terraform

Two independent pieces of DigitalOcean infrastructure managed from this directory, sharing one provider config ([`versions.tf`](versions.tf), [`provider.tf`](provider.tf)):

1. **[Cluster import](#cluster-import)** — brings the **existing** DOKS cluster (created manually/via `doctl`) under Terraform management, without recreating it.
2. **[Managed PostgreSQL database](#managed-postgresql-database)** — replaces the self-hosted Postgres pod (formerly `helm/user-mgmt-service` - `postgres-deployment.yaml`/`postgres-service.yaml`/`postgres-pvc.yaml`, now removed) with a real DigitalOcean Managed Database, created (not imported) by Terraform.

## Status

- [x] DigitalOcean provider configured ([`versions.tf`](versions.tf), [`provider.tf`](provider.tf))
- [x] Import block referencing the cluster by ID ([`import.tf`](import.tf))
- [x] `terraform plan -generate-config-out=generated.tf` run against the real cluster - raw output kept as [`docs/generated.tf.orig`](docs/generated.tf.orig)
- [x] `generated.tf` analyzed and cleaned up into [`main.tf`](main.tf) (see "Bereinigung von generated.tf" below), `generated.tf` deleted
- [x] Reusable values (name, region, version, node pool size/min/max, maintenance window, ...) in [`variables.tf`](variables.tf)
- [x] `terraform fmt` / `validate` pass; import applied (state only); `terraform plan` → `No changes. Your infrastructure matches the configuration.`
- [ ] Managed PostgreSQL (database.tf) created via `terraform apply`, chart + `app-secret` pointed at it

## Bereinigung von generated.tf

Was `-generate-config-out` erzeugt hat ([`docs/generated.tf.orig`](docs/generated.tf.orig)) und was davon in [`main.tf`](main.tf) übrig blieb:

| Generiert | Entscheidung | Grund |
|---|---|---|
| `destroy_all_associated_resources`, `kubeconfig_expire_seconds`, `registry_integration`, `gpu_partition_mode` = `null` | entfernt | nicht gesetzt = Provider-Default |
| `tags = []`, `labels = {}`, `isolated_workers = false` | entfernt | leer/Default |
| alle GPU-/Plugin-Blöcke (`amd_gpu_*`, `nvidia_gpu_*`, `p2p_oci_registry_plugin`, `rdma_shared_device_plugin`, `routing_agent`, `coredns_autoscaler`) | entfernt | alle auf Default; `*_device_plugin` und `*_dra_driver` schliessen sich zudem gegenseitig aus - mit ihnen scheitert `validate` ("Conflicting configuration arguments") |
| `node_pool.node_count = 0` | entfernt | bei `auto_scale = true` bestimmt der Autoscaler die Anzahl, konfiguriert sind nur `min_nodes`/`max_nodes` |
| `vpc_uuid`, `cluster_subnet`, `service_subnet`, `worker_subnet_uuid` | entfernt | von DigitalOcean bei der Erstellung vergeben (computed), nur per Neuerstellung änderbar |
| `name`, `region`, `version`, `ha`, `auto_upgrade`, `surge_upgrade`, `maintenance_policy`, `node_pool.{name,size,min_nodes,max_nodes}` | behalten, als Variablen | das ist die eigentliche, bewusst gewählte Konfiguration |

Nach der Bereinigung: `Plan: 1 to import, 0 to add, 0 to change, 0 to destroy`, nach dem Import-Apply `No changes`.

## Prerequisites

- Terraform >= 1.7 (`terraform version`).
- A DigitalOcean API token (Applications & API → Tokens in the DO control panel, or reuse whatever `doctl auth init` already has locally - **do not** paste it into a committed file). Supply it as an environment variable, never a file:
  ```bash
  export TF_VAR_do_token="dop_v1_..."
  ```
- The cluster's UUID and region:
  ```bash
  doctl kubernetes cluster list -o json | jq -r '.[] | "\(.name)\t\(.id)\t\(.region)"'
  ```
  Put `cluster_id` and `region` in a **gitignored** `*.auto.tfvars` (e.g. `local.auto.tfvars`, see [`terraform.tfvars.example`](terraform.tfvars.example) for the shape) - neither is secret, but both are specific to this cluster and don't belong hardcoded into `.tf` files.

## Cluster import

Config-driven import (Terraform 1.5+): [`import.tf`](import.tf) plus `terraform plan -generate-config-out=generated.tf` generates a starting-point resource definition straight from the cluster's actual current state.

```bash
cd terraform
terraform init
terraform plan -generate-config-out=generated.tf
```

This reads the cluster's real current state from the DigitalOcean API and writes a matching `resource "digitalocean_kubernetes_cluster" "this" { ... }` block into `generated.tf`. That file is a **starting point**, not the end result - it typically includes computed/read-only attributes (IDs, endpoints, timestamps, status fields) that don't belong in a hand-maintained resource block.

Next:

1. Diff `generated.tf` against the [DigitalOcean provider docs for `digitalocean_kubernetes_cluster`](https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs/resources/kubernetes_cluster) and strip anything computed-only (`id`, `endpoint`, `kube_config`, `created_at`, `urn`, `status`, `node_pool[].nodes`, etc. - Terraform tracks these in state regardless of whether they're in config).
2. Move whatever should be tunable per environment (`version`, node pool `size`/`min_nodes`/`max_nodes`, `auto_upgrade`, tags, ...) into `variables.tf`, and reference `var.*` from the cleaned-up resource block. (`region` is already a shared variable, used by `database.tf` too.)
3. Put the cleaned-up block in `main.tf`; delete `generated.tf`.
4. `terraform fmt && terraform validate`.
5. `terraform plan` - expect **no changes** (`No changes. Your infrastructure matches the configuration.`). If it proposes changes, that means a value in config doesn't match the cluster's real state (e.g. a default that differs) - fix config to match reality, never let `plan` "fix" a real cluster by surprise.

Once `plan` is clean, the `import` block in `import.tf` can be deleted (its job is done - the resource is in state) or left in place (re-applying it is a no-op).

## Managed PostgreSQL database

Unlike the cluster, this is **created** by Terraform, not imported - it didn't exist before. [`database.tf`](database.tf):

- One `digitalocean_database_cluster` (engine `pg`, version matching the old `postgres:16-alpine`, smallest/cheapest size by default), in the imported DOKS cluster's region and VPC (referenced directly from `main.tf` - private networking, no public-internet hop).
- Two `digitalocean_database_db`s - `user_mgmt_staging` and `user_mgmt_prod` - one shared cluster instead of two, since a second cluster would roughly double the monthly cost for a course project.
- One `digitalocean_database_user` shared by both databases - DigitalOcean managed Postgres users aren't scoped to a single database, so this doesn't weaken isolation beyond what the shared-cluster decision above already implies. Staging/prod still don't share data (separate databases) or network access (Kubernetes-layer NetworkPolicy, unchanged).
- One `digitalocean_database_firewall` trusting only the DOKS cluster itself (rule type `k8s`, the cluster's UUID) - nothing else can reach it.

```bash
cd terraform
terraform init
terraform apply
```

After it exists:

1. `terraform output database_host` / `database_port` → `helm/user-mgmt-service/values.yaml` `database.host`/`database.port` (shared across environments).
2. `terraform output staging_database_name` / `prod_database_name` should already match `values-staging.yaml`/`values.yaml`'s `database.name` (they're the same literal defaults on both sides - only re-check if you changed `variables.tf`).
3. `terraform output database_user` and `terraform output -raw database_password` → the `app-secret` Kubernetes Secret's `DB_USERNAME`/`DB_PASSWORD` (see `argocd-bootstrap.yml` in the App-Repo, and "Secrets" in `helm/user-mgmt-service/README.md`) - never into a committed file.
4. `helm lint`/`helm template` the chart again once `database.host` is a real value (not the `REPLACE_ME` placeholder) to confirm the rendered `SPRING_DATASOURCE_URL` looks right.

## Validated so far (scaffold phase, before real credentials)

Without real credentials, from this environment: `terraform fmt -check`, `terraform init`, and `terraform validate` all pass for both the cluster import and the database resources. `terraform plan` (with dummy `do_token`/`cluster_id`/`region`) was smoke-tested to confirm the resource graph, provider wiring, and DigitalOcean API calls all fire correctly - the VPC data source lookup reaches a real `401 Unable to authenticate you`, exactly as expected without a real token; the cluster import still reports "Configuration for import target does not exist" as expected (that's the cluster-import step not yet run, unrelated to the database resources being correct).

One gotcha worth knowing if you touch `import.tf`: without an explicit `provider = digitalocean` argument on the `import` block, Terraform's implied-provider resolution falls back to `hashicorp/digitalocean` (wrong namespace) instead of consulting `required_providers`, when there's no matching `resource` block yet to anchor it - the explicit `provider` argument works around that.

## Secrets

`var.do_token` has no default and is marked `sensitive`. Supply it via `TF_VAR_do_token` (preferred) or an untracked `*.auto.tfvars` file - both are excluded from git (see the repo's [`.gitignore`](../.gitignore)). Never put it in `versions.tf`, `provider.tf`, or any committed `.tf`/`.tfvars` file. The managed database's auto-generated password (`outputs.tf` - `database_password`) is marked `sensitive` too and is never printed by a plain `terraform output`.
