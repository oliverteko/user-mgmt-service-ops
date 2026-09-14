variable "do_token" {
  description = "DigitalOcean API token (needs read/write access to the target cluster). Sensitive - never given a default here, never committed anywhere. Supply via TF_VAR_do_token or a gitignored *.auto.tfvars file."
  type        = string
  sensitive   = true
}

variable "cluster_id" {
  description = "UUID of the existing DOKS cluster to import (`doctl kubernetes cluster list`, or the DigitalOcean control panel URL). Not secret, but specific to this cluster - supply via a gitignored *.auto.tfvars file; see import.tf."
  type        = string
}

# --- DOKS cluster (main.tf) --------------------------------------------------
# Defaults match the real cluster as imported (generated.tf) - changing one
# of these changes the real cluster on the next apply.

variable "cluster_name" {
  description = "DOKS cluster name. Changing it renames the cluster in place."
  type        = string
  default     = "k8s-1-36-3-do-5-fra1-1789986939190"
}

variable "region" {
  description = "DigitalOcean region slug. Changing it forces a new cluster."
  type        = string
  default     = "fra1"
}

variable "kubernetes_version" {
  description = "DOKS version slug (`doctl kubernetes options versions`). Bump to upgrade the control plane."
  type        = string
  default     = "1.36.3-do.5"
}

variable "ha" {
  description = "Highly available control plane (billed extra)."
  type        = bool
  default     = false
}

variable "auto_upgrade" {
  description = "Let DigitalOcean apply patch upgrades during the maintenance window. Off, so kubernetes_version stays the single source of truth."
  type        = bool
  default     = false
}

variable "surge_upgrade" {
  description = "Upgrade nodes by adding a new one before draining an old one."
  type        = bool
  default     = true
}

variable "maintenance_day" {
  description = "Maintenance window day (monday..sunday, or any)."
  type        = string
  default     = "any"
}

variable "maintenance_start_time" {
  description = "Maintenance window start, UTC (HH:MM)."
  type        = string
  default     = "19:00"
}

variable "node_pool_name" {
  description = "Name of the default node pool."
  type        = string
  default     = "pool-lvfj9vjl1"
}

variable "node_size" {
  description = "Droplet size slug for the worker nodes. 1 vCPU / 2 GB turned out too small for this workload (see project notes), hence 2 vCPU / 4 GB."
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "node_min" {
  description = "Cluster autoscaler minimum node count."
  type        = number
  default     = 3
}

variable "node_max" {
  description = "Cluster autoscaler maximum node count."
  type        = number
  default     = 5
}

# --- Managed PostgreSQL (database.tf) ---------------------------------------
# Created by Terraform from scratch (not imported). Lives in the same region
# and VPC as the cluster above so the app reaches it over private networking.

variable "database_cluster_name" {
  description = "Name of the managed PostgreSQL cluster."
  type        = string
  default     = "user-mgmt-postgres"
}

variable "database_version" {
  description = "PostgreSQL major version - matches the previously self-hosted postgres:16-alpine."
  type        = string
  default     = "16"
}

variable "database_size" {
  description = "DigitalOcean managed database size slug. db-s-1vcpu-1gb is the smallest/cheapest tier - fine for a course project, bump for real load."
  type        = string
  default     = "db-s-1vcpu-1gb"
}

variable "staging_database_name" {
  description = "Logical database name for the staging environment, within the shared managed cluster."
  type        = string
  default     = "user_mgmt_staging"
}

variable "prod_database_name" {
  description = "Logical database name for the prod environment, within the shared managed cluster."
  type        = string
  default     = "user_mgmt_prod"
}

variable "database_user_name" {
  description = "Shared DB user for the app, used by both staging and prod. DigitalOcean managed PostgreSQL users aren't scoped to a single database, so staging/prod isolation here comes from separate database names, not separate users - a second managed cluster would be the only way to get real per-environment credential isolation, not worth the extra cost for a course project."
  type        = string
  default     = "user_mgmt_service"
}
