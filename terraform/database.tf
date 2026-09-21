# Replaces the self-hosted Postgres pod (helm/user-mgmt-service - postgres
# Deployment/Service/PVC, now removed from that chart) with a DigitalOcean
# Managed PostgreSQL cluster. One cluster, two databases (staging/prod), one
# shared app user: DO's managed Postgres users aren't scoped to a single
# database, so a second cluster would be the only way to get real
# per-environment credential isolation - not worth ~doubling the monthly
# cost for a course project. Staging/prod stay isolated at the Kubernetes
# layer (namespaces, NetworkPolicy, ResourceQuota) exactly as before; this
# only replaces where Postgres itself runs.

resource "digitalocean_database_cluster" "postgres" {
  name       = var.database_cluster_name
  engine     = "pg"
  version    = var.database_version
  size       = var.database_size
  region     = digitalocean_kubernetes_cluster.this.region
  node_count = 1

  # Same VPC as the DOKS cluster (main.tf), so the app talks to the database
  # over private networking.
  private_network_uuid = digitalocean_kubernetes_cluster.this.vpc_uuid
}

resource "digitalocean_database_db" "staging" {
  cluster_id = digitalocean_database_cluster.postgres.id
  name       = var.staging_database_name
}

resource "digitalocean_database_db" "prod" {
  cluster_id = digitalocean_database_cluster.postgres.id
  name       = var.prod_database_name
}

resource "digitalocean_database_user" "app" {
  cluster_id = digitalocean_database_cluster.postgres.id
  name       = var.database_user_name

  # DigitalOcean fills in a default `settings` block after creation that the
  # config never sets, so every plan would otherwise show a spurious in-place
  # "remove settings" change on this user.
  lifecycle {
    ignore_changes = [settings]
  }
}

# DO denies all connections to a managed database until trusted sources are
# added. Trusting the DOKS cluster by ID (type "k8s") covers every node in
# it automatically - no IP list to keep in sync as the cluster/HPA scales.
resource "digitalocean_database_firewall" "postgres" {
  cluster_id = digitalocean_database_cluster.postgres.id

  rule {
    type  = "k8s"
    value = digitalocean_kubernetes_cluster.this.id
  }
}
