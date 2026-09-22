# DigitalOcean Managed MySQL for the module_service - its own database
# cluster, separate from the user_mgmt_service's PostgreSQL (database.tf).
# Same shape as database.tf: one cluster, one logical database per
# environment, one app user, reachable only from the DOKS cluster over the
# VPC. Only the module_service gets these credentials (Kubernetes Secret
# module-service-secret); the user_mgmt_service backend talks to the
# module_service's REST API instead and has no access to this database.

resource "digitalocean_database_cluster" "mysql" {
  name       = var.module_database_cluster_name
  engine     = "mysql"
  version    = var.module_database_version
  size       = var.module_database_size
  region     = digitalocean_kubernetes_cluster.this.region
  node_count = 1

  private_network_uuid = digitalocean_kubernetes_cluster.this.vpc_uuid
}

resource "digitalocean_database_db" "module_staging" {
  cluster_id = digitalocean_database_cluster.mysql.id
  name       = var.module_staging_database_name
}

resource "digitalocean_database_db" "module_prod" {
  cluster_id = digitalocean_database_cluster.mysql.id
  name       = var.module_prod_database_name
}

resource "digitalocean_database_user" "module_service" {
  cluster_id = digitalocean_database_cluster.mysql.id
  name       = var.module_database_user_name

  # Same spurious settings drift as the PostgreSQL user (database.tf).
  lifecycle {
    ignore_changes = [settings]
  }
}

resource "digitalocean_database_firewall" "mysql" {
  cluster_id = digitalocean_database_cluster.mysql.id

  rule {
    type  = "k8s"
    value = digitalocean_kubernetes_cluster.this.id
  }
}

# CA certificate the module_service verifies the (TLS-only) MySQL
# connection against. Public, not a secret.
data "digitalocean_database_ca" "mysql" {
  cluster_id = digitalocean_database_cluster.mysql.id
}
