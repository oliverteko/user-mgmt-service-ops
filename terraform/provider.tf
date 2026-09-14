# Token comes from var.do_token only - never hardcode it here. See
# variables.tf and README.md for how to supply it (TF_VAR_do_token or a
# gitignored *.auto.tfvars), never as a literal in any committed file.
provider "digitalocean" {
  token = var.do_token
}
