# The existing DOKS cluster, imported via import.tf. Started from
# `terraform plan -generate-config-out=generated.tf`, then cleaned up
# (see README.md, "Bereinigung von generated.tf"):
#   - null attributes and empty tags/labels dropped (provider defaults)
#   - all GPU/plugin blocks dropped: every one was `enabled = false`, i.e.
#     the default, and the generated set even conflicted with itself
#     (nvidia/amd device_plugin vs. dra_driver are mutually exclusive)
#   - node_pool.node_count dropped: with auto_scale the autoscaler owns the
#     node count, min_nodes/max_nodes are what's actually configured
#   - computed network attributes (vpc_uuid, cluster_subnet, service_subnet,
#     worker_subnet_uuid) dropped: DigitalOcean assigned them at creation
#     and they can't change without recreating the cluster, so pinning them
#     here only adds noise
#   - everything reusable/tunable moved into variables.tf
resource "digitalocean_kubernetes_cluster" "this" {
  name          = var.cluster_name
  region        = var.region
  version       = var.kubernetes_version
  ha            = var.ha
  auto_upgrade  = var.auto_upgrade
  surge_upgrade = var.surge_upgrade

  maintenance_policy {
    day        = var.maintenance_day
    start_time = var.maintenance_start_time
  }

  node_pool {
    name       = var.node_pool_name
    size       = var.node_size
    auto_scale = true
    min_nodes  = var.node_min
    max_nodes  = var.node_max
  }
}
