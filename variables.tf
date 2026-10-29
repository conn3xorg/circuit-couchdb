variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux or rhel. Apache doesn't publish CouchDB packages for Fedora."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "couchdb_version" {
  type        = string
  default     = "3.5.3"
  description = "CouchDB release to install, such as \"3.5.3\". Raising it upgrades CouchDB in place."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(\\.[0-9]+)?$", var.couchdb_version))
    error_message = "couchdb_version must be a full release, such as \"3.5.3\"."
  }
}

variable "admin_username" {
  type        = string
  default     = "admin"
  description = "Name of CouchDB's server admin."

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]*$", var.admin_username))
    error_message = "admin_username may use letters, digits, ., - and _, and must start with a letter or digit."
  }
}

variable "admin_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Password for CouchDB's server admin. Pass it at run time with -var or TF_VAR_admin_password; it never reaches state or the plan."

  # CouchDB reads it from an ini file, where ; starts a comment, and the
  # circuit passes it to curl. Leaving out quotes, backslashes, ; and
  # whitespace keeps it the same through both.
  validation {
    condition     = length(var.admin_password) >= 8 && !can(regex("[\"\\\\';\\s]", var.admin_password))
    error_message = "admin_password must be at least 8 characters, with no quotes, backslashes, semicolons or spaces."
  }
}

variable "bind_address" {
  type        = string
  default     = "127.0.0.1"
  description = "IP address CouchDB listens on, its [chttpd] bind_address. \"0.0.0.0\" listens on every IPv4 address, \"::\" on every address."

  validation {
    condition     = can(cidrhost("${var.bind_address}/${strcontains(var.bind_address, ":") ? 128 : 32}", 0))
    error_message = "bind_address must be an IPv4 or IPv6 address, such as \"127.0.0.1\", \"10.0.0.5\" or \"0.0.0.0\"."
  }
}

variable "port" {
  type        = number
  default     = 5984
  description = "Port CouchDB listens on, its [chttpd] port."

  validation {
    condition     = var.port >= 1 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be a port number from 1 to 65535."
  }
}

variable "require_valid_user" {
  type        = bool
  default     = false
  description = "Refuse every request that doesn't log in, even GET /. obsidian_livesync turns it on."
}

variable "cors_origins" {
  type        = list(string)
  default     = []
  description = "Origins allowed to call CouchDB from a browser, such as [\"https://app.example.com\"], or [\"*\"] for any. Empty turns CORS off, unless obsidian_livesync is on."

  validation {
    condition     = alltrue([for o in var.cors_origins : o == "*" || can(regex("^[a-z][a-z0-9+.-]*://[^\\s,/]+$", o))])
    error_message = "Each of cors_origins must be \"*\" or a scheme and host with no path, such as \"https://app.example.com\" or \"app://obsidian.md\"."
  }
}

variable "cors_credentials" {
  type        = bool
  default     = false
  description = "Let browsers send cookies and Authorization headers with cross-origin requests. CouchDB doesn't allow it with the \"*\" origin."
}

variable "cors_headers" {
  type        = list(string)
  default     = []
  description = "Request headers allowed on cross-origin requests. When empty, CouchDB's default: accept, authorization, content-type, origin and referer."

  validation {
    condition     = alltrue([for h in var.cors_headers : can(regex("^[A-Za-z0-9-]+$", h))])
    error_message = "Each of cors_headers must be a header name, such as \"x-custom-header\"."
  }
}

variable "obsidian_livesync" {
  type        = bool
  default     = false
  description = "Apply the settings the Self-hosted LiveSync plugin for Obsidian asks for: require_valid_user, CORS for the Obsidian apps with credentials, and larger request and document limits."
}

variable "settings" {
  type        = map(map(string))
  default     = {}
  description = "More CouchDB ini settings, by section, such as { couchdb = { max_dbs_open = \"1000\" } }. The circuit's own settings win over the same keys here."

  validation {
    condition     = !contains(keys(var.settings), "admins")
    error_message = "settings can't have an [admins] section. Use admin_username and admin_password."
  }

  validation {
    condition     = alltrue(flatten([for s, kv in var.settings : [for k, v in kv : can(regex("^[A-Za-z0-9_.-]+$", s)) && can(regex("^[A-Za-z0-9_./-]+$", k)) && !strcontains(v, "\n")]]))
    error_message = "Section and key names may use letters, digits, ., /, - and _, and values can't contain newlines."
  }
}
