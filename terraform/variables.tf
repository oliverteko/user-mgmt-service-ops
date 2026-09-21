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
