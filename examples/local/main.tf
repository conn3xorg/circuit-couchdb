variable "port" {
  type    = number
  default = 2222
}

# Pass it at run time, such as with TF_VAR_admin_password.
variable "admin_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

# CI sets this to install an older CouchDB first, then upgrades to the
# circuit's own pin by applying again without it.
variable "couchdb_version" {
  type    = string
  default = null
}

module "couchdb" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  admin_password    = var.admin_password
  obsidian_livesync = true
  couchdb_version   = var.couchdb_version
}

output "url" {
  value = module.couchdb.url
}
