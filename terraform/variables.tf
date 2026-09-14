# More variables (region, node pool sizing, k8s version, ...) get added here
# once generated.tf exists and is analyzed - see the "Nächste Schritte"
# checklist in README.md. Keeping this minimal for now avoids guessing at an
# attribute shape we don't actually know yet.

variable "do_token" {
  description = "DigitalOcean API token (needs read/write access to the target cluster). Sensitive - never given a default here, never committed anywhere. Supply via TF_VAR_do_token or a gitignored *.auto.tfvars file."
  type        = string
  sensitive   = true
}

variable "cluster_id" {
  description = "UUID of the existing DOKS cluster to import (`doctl kubernetes cluster list -o json`, or the DigitalOcean control panel URL). Not secret, but specific to this cluster - fill in before running the import; see import.tf."
  type        = string
}
