# Facts give each host's distribution and release, which pick Apache's apt
# suite or yum repository.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }

    postcondition {
      condition     = self.os_family == "debian" ? contains(keys(local.codenames), "${self.os_id} ${self.os_version}") : contains(["rocky", "almalinux", "rhel"], self.os_id) && split(".", self.os_version)[0] == "10"
      error_message = "Host ${each.key} runs ${self.os_id} ${self.os_version}. Apache publishes CouchDB packages for Ubuntu 22.04, 24.04 and 26.04, Debian 12 and 13, and Rocky Linux, AlmaLinux and RHEL 10."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  family = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) ? "debian" : "redhat" }

  apt_hosts = { for name, h in var.hosts : name => h if local.family[name] == "debian" }
  rpm_hosts = { for name, h in var.hosts : name => h if local.family[name] == "redhat" }

  # Apache keeps one apt suite per release, and names each .deb's version
  # after it, such as 3.5.3~noble.
  codenames = {
    "ubuntu 22.04" = "jammy"
    "ubuntu 24.04" = "noble"
    "ubuntu 26.04" = "resolute"
    "debian 12"    = "bookworm"
    "debian 13"    = "trixie"
  }
  codename = { for name, f in data.conn3x_host.facts : name => lookup(local.codenames, "${f.os_id} ${f.os_version}", "") }

  etc       = "/opt/couchdb/etc"
  config    = "${local.etc}/local.d/10-conn3x.ini"
  admins    = "${local.etc}/local.d/zz-admins.ini"
  dropin    = "/etc/systemd/system/couchdb.service.d/conn3x.conf"
  passwords = "/etc/conn3x/couchdb"

  # The settings the Self-hosted LiveSync plugin's own provisioning script,
  # utils/couchdb/provision.ts, applies through CouchDB's config API.
  livesync_origins = ["app://obsidian.md", "capacitor://localhost", "http://localhost"]
  livesync = {
    couchdb = { max_document_size = "50000000" }
    chttpd  = { max_http_request_size = "4294967296" }
  }

  require_valid_user = var.require_valid_user || var.obsidian_livesync
  cors_origins       = distinct(concat(var.obsidian_livesync ? local.livesync_origins : [], var.cors_origins))
  cors               = length(local.cors_origins) > 0

  # The circuit's own settings win over the same keys in var.settings and
  # the LiveSync preset. single_node makes CouchDB create _users and
  # _replicator itself on start, and n = 1 keeps one copy of each shard, the
  # most a single node can hold.
  own = {
    couchdb = { single_node = "true" }
    cluster = { n = "1" }
    chttpd = {
      bind_address       = var.bind_address
      port               = tostring(var.port)
      require_valid_user = tostring(local.require_valid_user)
      enable_cors        = tostring(local.cors)
    }
    chttpd_auth = { require_valid_user = tostring(local.require_valid_user) }
    httpd = merge(
      { enable_cors = tostring(local.cors) },
      local.require_valid_user ? { WWW-Authenticate = "Basic realm=\"couchdb\"" } : {},
    )
    cors = local.cors ? merge(
      { origins = join(", ", local.cors_origins), credentials = tostring(var.cors_credentials || var.obsidian_livesync) },
      length(var.cors_headers) > 0 ? { headers = join(", ", var.cors_headers) } : {},
    ) : {}
  }
  base     = { for s in distinct(concat(keys(var.settings), keys(local.livesync))) : s => merge(lookup(var.settings, s, {}), var.obsidian_livesync ? lookup(local.livesync, s, {}) : {}) }
  sections = merge(local.base, { for s, kv in local.own : s => merge(lookup(local.base, s, {}), kv) if length(kv) > 0 })
  ini = join("\n", concat(
    ["# Written by Conn3x. Changes here are overwritten on the next apply.\n# CouchDB writes the admin's hashed password, and anything set through\n# its config API, to zz-admins.ini instead.\n"],
    [for s, kv in local.sections : join("", concat(["[${s}]\n"], [for k, v in kv : "${k} = ${v}\n"])) if length(kv) > 0],
  ))

  # Where the circuit itself talks to CouchDB. 0.0.0.0 and :: listen on
  # loopback too.
  check_host = lookup({ "0.0.0.0" = "127.0.0.1", "::" = "[::1]" }, var.bind_address, strcontains(var.bind_address, ":") ? "[${var.bind_address}]" : var.bind_address)
  url        = "http://${local.check_host}:${var.port}"

  # The password reaches curl on stdin, so it never shows in ps.
  login = "printf 'user = \"%s:%s\"\\n' ${var.admin_username} \"$(cat ${local.passwords}/admin-password)\" | curl -sf -K- ${local.url}/_session | grep -q '\"name\":\"${var.admin_username}\"'"
}

# Apache's apt repository. The debconf answer keeps the package from
# configuring CouchDB itself, so both families end up configured the same
# way, by the steps below.
circuit "couchdb_apt" {
  hosts = local.apt_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Signs the suites' Release files. The key has no expiry date.
  step "repo" {
    repository {
      name   = "couchdb"
      url    = "https://apache.jfrog.io/artifactory/couchdb-deb"
      key    = file("${path.module}/files/couchdb-deb.asc")
      suites = [local.codename[each.key]]
    }
  }

  step "preseed" {
    command {
      command = "printf 'couchdb couchdb/mode select none\\ncouchdb couchdb/mode seen true\\n' | debconf-set-selections"
      unless  = "echo 'get couchdb/mode' | DEBIAN_FRONTEND=noninteractive debconf-communicate couchdb 2>/dev/null | grep -qx '0 none'"
    }
  }
}

# Apache's yum repository, one per EL major release.
circuit "couchdb_rpm" {
  hosts = local.rpm_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Signs the packages. The key expires on 2 January 2039.
  step "repo" {
    repository {
      name = "couchdb"
      url  = "https://apache.jfrog.io/artifactory/couchdb-rpm/el$releasever/$basearch/"
      key  = file("${path.module}/files/couchdb-rpm.asc")
    }
  }
}

circuit "couchdb" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # The checks below talk to CouchDB with curl.
  step "curl" {
    package {
      name = "curl"
    }
  }

  # apt wants the full version, dnf takes the leading part of it.
  step "package" {
    depends_on = [conn3x_repository.couchdb_apt__repo, conn3x_command.couchdb_apt__preseed, conn3x_repository.couchdb_rpm__repo]
    package {
      name    = "couchdb"
      version = local.family[each.key] == "debian" ? "${var.couchdb_version}~${local.codename[each.key]}" : var.couchdb_version
    }
  }

  # CouchDB reads every *.ini in local.d after local.ini, in name order.
  step "config" {
    file {
      path    = local.config
      content = local.ini
      owner   = "couchdb"
      group   = "couchdb"
      mode    = "0640"
    }
  }

  # epmd, which CouchDB starts, otherwise listens on every address. A single
  # node never needs it reachable from outside.
  step "epmd" {
    file {
      path    = local.dropin
      content = "# Written by Conn3x.\n[Service]\nEnvironment=ERL_EPMD_ADDRESS=127.0.0.1\n"
    }
  }

  # The Red Hat package makes a random Erlang cookie when it installs. The
  # Debian package leaves it empty when told not to configure CouchDB, so
  # one is made here, on the host, and never leaves it.
  step "cookie" {
    command {
      command = "c=$(LC_ALL=C tr -dc A-Za-z0-9 < /dev/urandom | head -c 48) && sed -i '/^[# ]*-setcookie/d' ${local.etc}/vm.args && printf -- \"-setcookie '%s'\\n\" \"$c\" >> ${local.etc}/vm.args"
      unless  = "grep -Eq \"^-setcookie '?[A-Za-z0-9]{16,}\" ${local.etc}/vm.args"
    }
  }

  step "password_dir" {
    directory {
      path = local.passwords
      mode = "0700"
    }
  }

  # The password lands in a root-only file, never in state or the plan.
  step "admin_password" {
    file {
      path       = "${local.passwords}/admin-password"
      content_wo = var.admin_password
    }
  }

  # CouchDB replaces a plain password in [admins] with its PBKDF2 hash when
  # it starts, and writes the hash, its uuid and anything set through its
  # config API to the last ini file it reads, zz-admins.ini. Since CouchDB
  # rewrites it, the circuit doesn't manage this file whole: when the
  # password or name changes, it swaps the [admins] section and leaves the
  # rest. The restart below hashes it.
  step "admin" {
    command {
      command = <<-EOT
        set -e
        f=${local.admins}
        touch $f
        { awk '/^\[/ { skip = ($0 == "[admins]") } !skip' $f; printf '\n[admins]\n%s = %s\n' ${var.admin_username} "$(cat ${local.passwords}/admin-password)"; } > $f.new
        chown couchdb:couchdb $f.new
        chmod 600 $f.new
        mv $f.new $f
      EOT
      triggers = {
        password = conn3x_file.couchdb__admin_password[each.key].revision
        username = var.admin_username
      }
    }
  }

  # CouchDB reads its ini files only at start. It runs here rather than in
  # a handler so the steps below find it running with the new settings.
  step "restart" {
    command {
      command = "systemctl daemon-reload && systemctl restart couchdb"
      triggers = {
        package = conn3x_package.couchdb__package[each.key].revision
        config  = conn3x_file.couchdb__config[each.key].revision
        epmd    = conn3x_file.couchdb__epmd[each.key].revision
        cookie  = conn3x_command.couchdb__cookie[each.key].revision
        admin   = conn3x_command.couchdb__admin[each.key].revision
      }
    }
  }

  step "running" {
    service {
      name    = "couchdb"
      state   = "started"
      enabled = true
    }
  }

  # CouchDB answers a moment before it has hashed the admin's password,
  # and a login before then fails. It locks a user out for a while after a
  # few failed logins, so the check waits for the hash in the file and logs
  # in once.
  step "ready" {
    command {
      command  = "for _ in $(seq 60); do curl -s -o /dev/null ${local.url}/ && grep -q '^${var.admin_username} = -pbkdf2' ${local.admins} && break; sleep 2; done; ${local.login} || { echo 'CouchDB did not answer on ${local.url}, or did not accept the admin password. See journalctl -u couchdb.' >&2; exit 1; }"
      triggers = { restart = conn3x_command.couchdb__restart[each.key].revision }
    }
  }
}
