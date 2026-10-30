variable "port" {
  type    = number
  default = 2222
}

# Example passwords and tokens only. Pass your own with -var or TF_VAR_ on a
# real host.
variable "db_password" {
  type      = string
  default   = "correct-horse-battery"
  ephemeral = true
  sensitive = true
}

variable "bootstrap_password" {
  type      = string
  default   = "tracing-paper-kite"
  ephemeral = true
  sensitive = true
}

variable "bootstrap_token" {
  type      = string
  default   = "example-token-not-secret"
  ephemeral = true
  sensitive = true
}

locals {
  host = { box = "127.0.0.1" }
}

# PostgreSQL on the same host, listening only on localhost.
module "postgres" {
  source = "github.com/conn3xorg/circuit-postgres?ref=v0.2.0"

  hosts                = local.host
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  users          = ["authentik"]
  user_passwords = { authentik = var.db_password }
  databases      = { authentik = "authentik" }
}

module "authentik" {
  source = "../.."

  depends_on = [module.postgres]

  hosts                = local.host
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  public_url         = "http://localhost:9000"
  postgres_password  = var.db_password
  bootstrap_password = var.bootstrap_password
  bootstrap_token    = var.bootstrap_token
  bootstrap_email    = "admin@example.com"
}
