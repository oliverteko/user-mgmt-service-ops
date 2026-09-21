# Config-driven import (Terraform 1.5+). This brings the existing DOKS
# cluster under Terraform management without recreating it.
#
# Workflow (see README.md for the full checklist):
#   1. Set var.cluster_id to the real cluster's UUID.
#   2. terraform init
#   3. terraform plan -generate-config-out=generated.tf
#      -> Terraform reads the cluster's actual current state from the
#         DigitalOcean API and writes a matching
#         `resource "digitalocean_kubernetes_cluster" "this" { ... }` block
#         into generated.tf.
#   4. Review generated.tf by hand: drop computed-only/redundant attributes,
#      fold anything reusable into variables.tf, move the cleaned-up result
#      into main.tf, then delete generated.tf.
#   5. `terraform plan` against the result should show no changes.
#
# This block can stay in place afterwards - re-applying an already-imported
# resource is a no-op - but is commonly removed once step 5 is green, since
# its only job is the one-time import.
#
# Only while generating config (no resource block yet) does this need an
# explicit `provider = digitalocean` - otherwise Terraform guesses the wrong
# namespace (hashicorp/digitalocean). Once main.tf defines the resource,
# Terraform rejects that argument, so it's gone again.
import {
  to = digitalocean_kubernetes_cluster.this
  id = var.cluster_id
}
