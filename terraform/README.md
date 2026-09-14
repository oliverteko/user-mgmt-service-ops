# Terraform: DOKS Cluster Import

Brings the **existing** DigitalOcean Kubernetes cluster (created manually/via `doctl`, see the App-Repo's `argocd-bootstrap.yml`) under Terraform management, without recreating it. Config-driven import (Terraform 1.5+): an [`import`](import.tf) block plus `terraform plan -generate-config-out=generated.tf` generates a starting-point resource definition straight from the cluster's actual current state.

## Status

- [x] DigitalOcean provider configured ([`versions.tf`](versions.tf), [`provider.tf`](provider.tf))
- [x] Import block referencing the cluster by ID ([`import.tf`](import.tf))
- [x] `terraform fmt` / `terraform init` / `terraform validate` pass on this scaffold (verified without real credentials - see "Validated so far" below)
- [ ] **Not yet run**: `terraform plan -generate-config-out=generated.tf` against the real cluster (needs a real `do_token` + `cluster_id` - see "Prerequisites")
- [ ] `generated.tf` analyzed, cleaned up, folded into `main.tf`
- [ ] Reusable values (region, node pool size/count, k8s version, ...) pulled into `variables.tf`
- [ ] `generated.tf` deleted once its content lives in `main.tf`
- [ ] Final `terraform fmt` / `validate` / `plan` (no unintended changes) against the real cluster

## Prerequisites

- Terraform >= 1.7 (`terraform version`).
- A DigitalOcean API token with read access to the cluster (Applications & API → Tokens in the DO control panel, or reuse whatever `doctl auth init` already has locally - **do not** paste it into a committed file). Supply it as an environment variable, never a file:
  ```bash
  export TF_VAR_do_token="dop_v1_..."
  ```
- The cluster's UUID:
  ```bash
  doctl kubernetes cluster list -o json | jq -r '.[] | "\(.name)\t\(.id)"'
  ```
  Put it in a **gitignored** `*.auto.tfvars` (e.g. `local.auto.tfvars`, see [`terraform.tfvars.example`](terraform.tfvars.example) for the shape) - the ID itself isn't secret, but it's specific to this cluster and doesn't belong hardcoded into `import.tf`.

## Running the import

```bash
cd terraform
terraform init
terraform plan -generate-config-out=generated.tf
```

This reads the cluster's real current state from the DigitalOcean API and writes a matching `resource "digitalocean_kubernetes_cluster" "this" { ... }` block into `generated.tf`. That file is a **starting point**, not the end result - it typically includes computed/read-only attributes (IDs, endpoints, timestamps, status fields) that don't belong in a hand-maintained resource block.

Next:

1. Diff `generated.tf` against the [DigitalOcean provider docs for `digitalocean_kubernetes_cluster`](https://registry.terraform.io/providers/digitalocean/digitalocean/latest/docs/resources/kubernetes_cluster) and strip anything computed-only (`id`, `endpoint`, `kube_config`, `created_at`, `urn`, `status`, `node_pool[].nodes`, etc. - Terraform tracks these in state regardless of whether they're in config).
2. Move whatever should be tunable per environment (region, `version`, node pool `size`/`min_nodes`/`max_nodes`, `auto_upgrade`, tags, ...) into `variables.tf`, and reference `var.*` from the cleaned-up resource block.
3. Put the cleaned-up block in `main.tf`; delete `generated.tf`.
4. `terraform fmt && terraform validate`.
5. `terraform plan` - expect **no changes** (`No changes. Your infrastructure matches the configuration.`). If it proposes changes, that means a value in config doesn't match the cluster's real state (e.g. a default that differs) - fix config to match reality, never let `plan` "fix" a real cluster by surprise.

Once `plan` is clean, the `import` block in `import.tf` can be deleted (its job is done - the resource is in state) or left in place (re-applying it is a no-op).

## Validated so far

Without real credentials, from this environment: `terraform fmt -check`, `terraform init`, and `terraform validate` all pass. `terraform plan -generate-config-out=...` was smoke-tested with a placeholder token/ID to confirm the import block, provider wiring and DigitalOcean API call all fire correctly - it fails only on `401 Unable to authenticate you`, as expected without a real token. One thing worth knowing if you touch `import.tf`: without an explicit `provider = digitalocean` argument on the `import` block, Terraform's implied-provider resolution falls back to `hashicorp/digitalocean` (wrong namespace) instead of consulting `required_providers`, when there's no matching `resource` block yet to anchor it - the explicit `provider` argument works around that.

## Secrets

`var.do_token` has no default and is marked `sensitive`. Supply it via `TF_VAR_do_token` (preferred) or an untracked `*.auto.tfvars` file - both are excluded from git (see the repo's [`.gitignore`](../.gitignore)). Never put it in `versions.tf`, `provider.tf`, or any committed `.tf`/`.tfvars` file.
