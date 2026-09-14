# Non-sensitive outputs feed helm/user-mgmt-service's values.yaml/values-*.yaml
# `database.*` block. Sensitive ones feed the `app-secret` Kubernetes Secret,
# created imperatively via argocd-bootstrap.yml in the App-Repo (same
# never-touches-git pattern as the JWT secret) - never put these into a
# committed values file directly.

output "database_host" {
  description = "Private (VPC-internal) hostname - use this for database.host, not the public `host` attribute, since the cluster connects over private networking (see private_network_uuid in database.tf)."
  value       = digitalocean_database_cluster.postgres.private_host
}

output "database_port" {
  description = "database.port in values.yaml."
  value       = digitalocean_database_cluster.postgres.port
}

output "database_user" {
  description = "Shared app DB user name - app-secret's DB_USERNAME."
  value       = digitalocean_database_user.app.name
}

output "database_password" {
  description = "Auto-generated password for the app DB user - app-secret's DB_PASSWORD. Not shown by default; run `terraform output -raw database_password` deliberately when you need it."
  value       = digitalocean_database_user.app.password
  sensitive   = true
}

output "staging_database_name" {
  description = "values-staging.yaml's database.name."
  value       = digitalocean_database_db.staging.name
}

output "prod_database_name" {
  description = "values.yaml's database.name (prod is the base default, staging overrides it - see helm/user-mgmt-service/values.yaml)."
  value       = digitalocean_database_db.prod.name
}
