# circuit-couchdb

[![Conn3x grade](https://conn3x.org/circuits/couchdb/grade.svg)](https://conn3x.org/circuits/couchdb/grade)

A Conn3x circuit that installs Apache CouchDB as a single node, from Apache's own apt and yum repositories, with an admin, a fresh Erlang cookie and the system databases in place, so the first thing you do with it is use it.

The usual reason to want one at home is the [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) plugin for Obsidian, which syncs your vault through a CouchDB you run. It's a community plugin, written by vorotamoroz, not Obsidian's own Obsidian Sync. Set `obsidian_livesync = true` and the circuit applies the CouchDB settings the plugin's setup asks for; put [circuit-caddy](https://github.com/conn3xorg/circuit-caddy) in front for the HTTPS the mobile apps need.

The awkward part of configuring CouchDB with a tool is the admin password. You write it into an ini file in plain text, and on its next start CouchDB swaps it for a PBKDF2 hash, in the same file. A tool that owns that file sees it change behind its back and puts the plain password back on every run. This circuit keeps the password out of state, hands it to CouchDB once per change, and leaves the hashed file to CouchDB, so the second plan is clean.

## Usage

```hcl
variable "couchdb_admin_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "couchdb" {
  source = "github.com/conn3xorg/circuit-couchdb?ref=v0.1.3"

  hosts                = { notes = "192.168.1.60" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  admin_password    = var.couchdb_admin_password
  obsidian_livesync = true
}
```

Then run `conn3x init` and `conn3x apply` with the password in the environment:

```sh
export TF_VAR_couchdb_admin_password='...'
conn3x apply
```

A second `conn3x plan` says `No changes.` Every plan needs the password too, since Conn3x checks the file on the host against it.

CouchDB listens on `127.0.0.1:5984` unless you set `bind_address`. That's the right place for it behind a proxy on the same host, as below. To reach it straight from other machines, set `bind_address = "0.0.0.0"` or the host's private address, and keep port 5984 off the internet with a firewall, such as [circuit-firewall](https://github.com/conn3xorg/circuit-firewall).

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too: the circuit picks its repository by distribution, and Conn3x can't ask a host that doesn't exist yet. If `os` turns out not to match the host, Conn3x stops before configuring it. Set `os` as well when you put `depends_on` on this module: `depends_on` holds back reading the hosts until the apply, so without `os` the plan fails with `Invalid for_each argument`.

```hcl
hosts = {
  for name, d in digitalocean_droplet.notes : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

### Obsidian Self-hosted LiveSync

`obsidian_livesync = true` writes the settings that the plugin's own provisioning script, [`utils/couchdb/provision.ts`](https://github.com/vrtmrz/obsidian-livesync/blob/main/utils/couchdb/provision.ts), sets through CouchDB's config API, with the CORS origins from its [server setup guide](https://github.com/vrtmrz/obsidian-livesync/blob/main/docs/setup_own_server.md):

| Section | Key | Value |
| --- | --- | --- |
| `chttpd` | `require_valid_user` | `true` |
| `chttpd_auth` | `require_valid_user` | `true` |
| `httpd` | `WWW-Authenticate` | `Basic realm="couchdb"` |
| `httpd`, `chttpd` | `enable_cors` | `true` |
| `chttpd` | `max_http_request_size` | `4294967296` |
| `couchdb` | `max_document_size` | `50000000` |
| `cors` | `credentials` | `true` |
| `cors` | `origins` | `app://obsidian.md, capacitor://localhost, http://localhost` |

`app://obsidian.md` is the desktop app, and `capacitor://localhost` and `http://localhost` are the iOS and Android apps. Anything in `cors_origins` is added to the list. If you add a custom header in the plugin, add it to `cors_headers` too, along with CouchDB's defaults: `["accept", "authorization", "content-type", "origin", "referer", "x-custom-header"]`.

With `require_valid_user` on, CouchDB refuses every request that doesn't log in, even `GET /`, so nobody can list or read your databases anonymously.

The plugin needs a database to sync into. Create one with the admin, or a user of its own if you'd rather not hand the plugin the admin password:

```sh
curl -u admin -X PUT http://127.0.0.1:5984/obsidiannotes
```

Then, in the plugin, give the URL CouchDB is reached at, the user, the password and `obsidiannotes`.

### HTTPS with circuit-caddy

Obsidian on iOS and Android only talks to CouchDB over HTTPS with a certificate the phone trusts. [circuit-caddy](https://github.com/conn3xorg/circuit-caddy) gets one from Let's Encrypt on its own. With CouchDB on `127.0.0.1` and Caddy on the same host:

```hcl
module "couchdb" {
  source = "github.com/conn3xorg/circuit-couchdb?ref=v0.1.3"

  hosts                = { notes = "203.0.113.20" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  admin_password    = var.couchdb_admin_password
  obsidian_livesync = true
}

module "caddy" {
  source = "github.com/conn3xorg/circuit-caddy?ref=v0.3.0"

  hosts                = { notes = "203.0.113.20" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  email = "you@example.com"
  sites = {
    "couchdb.example.com" = { reverse_proxy = ["127.0.0.1:5984"] }
  }
}
```

Point `couchdb.example.com` at the host and open ports 80 and 443, and the plugin's URL is `https://couchdb.example.com`. CouchDB itself stays on loopback. Caddy streams requests and responses through without buffering them and sets no limit on the size of a request, which are the two things the plugin's guide warns about with nginx (`proxy_buffering` and `client_max_body_size`).

The plugin's guide has more ways to reach a home server from outside, such as a Cloudflare Tunnel, and what to watch out for with each.

### The admin password

`admin_password` reaches the host in `/etc/conn3x/couchdb/admin-password`, readable by root only, and never through state or the plan. When it changes, or `admin_username` does, the circuit writes the plain password into the `[admins]` section of `/opt/couchdb/etc/local.d/zz-admins.ini` and restarts CouchDB, which replaces it there with its PBKDF2 hash as it starts. The circuit then waits for the hash to appear and logs in once to check.

CouchDB writes anything it changes about its own configuration to the last ini file it reads, and `zz-admins.ini` sorts last on purpose: the hashed password, the node's `uuid`, and whatever you set through `/_node/_local/_config` all land there. That's why the circuit doesn't manage this file as a whole. When the password changes, it swaps the `[admins]` section and leaves the rest of the file alone. A setting you change through the config API overrides the circuit's own until you take it out of `zz-admins.ini` again.

A plan compares the password file with `admin_password`, not the password with CouchDB, so a password changed through CouchDB's API goes unnoticed until `admin_password` changes too.

It has to be at least 8 characters, with no quotes, backslashes, semicolons or spaces, so it passes through the ini file and `curl` unchanged.

## What it does

On each host, in order:

1. Adds Apache's CouchDB repository with its signing key. On Debian and Ubuntu that's `https://apache.jfrog.io/artifactory/couchdb-deb`, with the release's codename as the suite. Its key, in `files/couchdb-deb.asc`, has no expiry date. On Rocky Linux, AlmaLinux and RHEL it's `https://apache.jfrog.io/artifactory/couchdb-rpm/el$releasever/$basearch/`, whose packages are signed with the key in `files/couchdb-rpm.asc`, which expires on 2 January 2039.
2. On Debian and Ubuntu, tells the package through debconf not to configure CouchDB itself (`couchdb/mode` `none`), so it doesn't ask questions and both families end up configured the same way.
3. Installs `curl`, then `couchdb` at `couchdb_version`. A higher version upgrades it in place.
4. Writes `/opt/couchdb/etc/local.d/10-conn3x.ini` with `[couchdb] single_node = true`, `[cluster] n = 1`, the bind address and port, `require_valid_user`, CORS, the LiveSync settings when they're on, and your `settings`. CouchDB reads it after `default.ini` and `local.ini`, so it wins over both.
5. Adds a systemd drop-in that makes epmd, the Erlang port mapper CouchDB starts, listen on `127.0.0.1` only. vm.args already keeps Erlang distribution on loopback.
6. Makes a random 48-character Erlang cookie on the host and puts it in `/opt/couchdb/etc/vm.args`, unless one is there already. The Red Hat package makes one when it installs; the Debian package leaves it empty when it isn't configuring CouchDB.
7. Writes the admin password, as above, and restarts CouchDB when the package, the ini file, the drop-in, the cookie or the admin changed. Starts it at boot.
8. Waits up to two minutes for CouchDB to answer and hash the password, then logs in as the admin.

`single_node = true` makes CouchDB create the `_users` and `_replicator` system databases on start when they're missing, which the Debian package's own standalone setup does with `curl`.

### What it doesn't do

- It sets up one node. Clustering needs a node name, a cookie shared across nodes and Erlang distribution open between them, and none of that is here.
- It doesn't set up TLS in CouchDB itself. Put a proxy in front, as above.
- It doesn't create databases or users other than the admin. Use CouchDB's HTTP API for those.
- It doesn't open a firewall port or touch firewalld or ufw.
- It doesn't install `couchdb-nouveau`, the full-text search add-on, which needs Java.
- Deleting the module leaves CouchDB installed and running with the last settings.

### Distributions

Apache publishes packages for Ubuntu 22.04, 24.04 and 26.04, Debian 12 and 13, and Enterprise Linux 10, and the circuit takes any of those. CouchDB's [install guide](https://docs.couchdb.org/en/stable/install/unix.html) lists Debian 12 as the newest Debian, but the repository has a `trixie` suite with the same releases, and Debian 13 is what this was tested on.

Fedora isn't supported. Apache doesn't build CouchDB for it, and its yum repository has only `el7` to `el10` directories, so `$releasever` on Fedora points at one that doesn't exist. The circuit stops with an error naming the host rather than try.

Enterprise Linux 9 is left out too: its packages need EPEL and a separate SpiderMonkey package, and this circuit only sets up what EL10 needs.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan needs. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `admin_password` | string | Required | Password for CouchDB's server admin. Ephemeral and sensitive: pass it with `-var` or `TF_VAR_`. At least 8 characters, with no quotes, backslashes, semicolons or spaces. |
| `admin_username` | string | `"admin"` | Name of the server admin. Changing it replaces the old admin. |
| `couchdb_version` | string | `"3.5.3"` | CouchDB release to install. Raising it upgrades in place. |
| `bind_address` | string | `"127.0.0.1"` | IP address CouchDB listens on. `"0.0.0.0"` listens on every IPv4 address, `"::"` on every address. |
| `port` | number | `5984` | Port CouchDB listens on. |
| `require_valid_user` | bool | `false` | Refuse every request that doesn't log in, even `GET /`. `obsidian_livesync` turns it on. |
| `cors_origins` | list(string) | `[]` | Origins allowed to call CouchDB from a browser, such as `["https://app.example.com"]`, or `["*"]` for any. Empty turns CORS off, unless `obsidian_livesync` is on. |
| `cors_credentials` | bool | `false` | Let browsers send cookies and `Authorization` headers with cross-origin requests. `obsidian_livesync` turns it on. |
| `cors_headers` | list(string) | `[]` | Request headers allowed on cross-origin requests. When empty, CouchDB's default. |
| `obsidian_livesync` | bool | `false` | Apply the settings the Self-hosted LiveSync plugin asks for, as in the table above. |
| `settings` | map(map(string)) | `{}` | More CouchDB ini settings, by section, such as `{ couchdb = { max_dbs_open = "1000" } }`. The circuit's own settings win over the same keys here. No `[admins]` section. |

## Outputs

| Name | Description |
| --- | --- |
| `url` | URL the circuit checks CouchDB on, from each host itself, such as `http://127.0.0.1:5984`. |
| `config_file` | Path of the ini file the circuit writes, `/opt/couchdb/etc/local.d/10-conn3x.ini`. |

## Requirements

Requires Conn3x v0.6.9 or later and systemd on each host, with outbound HTTPS to apache.jfrog.io. The droplets it was tested on had 1 GB of memory. amd64 and arm64.

## Tested on

Rocky Linux 10, Ubuntu 24.04 and Debian 13, with CouchDB 3.5.3. [examples/local](examples/local), which turns on `obsidian_livesync`, was applied to each on arm64, and the second plan had no changes. On each, the admin got the welcome JSON from `GET /` and logged in on `/_session`, an anonymous request and a wrong password got 401, `_users` and `_replicator` were there, CouchDB reported the LiveSync settings and answered an `app://obsidian.md` origin with CORS headers, the ini files held only the password's hash, and epmd listened on loopback only. A database and a document survived a restart of CouchDB and of the container. Then the admin password changed: the new one worked, the old one got 401, and the plan after that was clean too. CI runs the same checks on amd64, and that a link beside the admin file leaves what it points to unchanged. On a fresh container it also installs CouchDB 3.5.2.1 and writes a document, then applies the circuit's own pin over it, and checks the second plan is empty, 3.5.3 is running, the document is still there and the checks above pass.

On an Ubuntu 24.04 droplet and a Rocky Linux 10 droplet with SELinux enforcing, both `s-1vcpu-1gb`, the circuit applied with `bind_address = "0.0.0.0"` and a CORS origin. From another machine, `GET /` answered anonymously with the welcome JSON, the admin logged in, a database and document were created, CORS headers came back for the origin, and port 4369 was closed. Both came back after a reboot with CouchDB running, the document there and the plan clean. On Rocky Linux CouchDB runs as `unconfined_service_t`, and the audit log had no denials.

The circuit-caddy setup above wasn't part of these tests, and neither was the plugin itself.

## License

MPL-2.0. See [LICENSE](LICENSE). CouchDB itself is Apache-2.0.
