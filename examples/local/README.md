# Local example

Applies circuit-couchdb, with `obsidian_livesync` on, to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman.

```sh
./up.sh
export TF_VAR_admin_password=$(openssl rand -hex 12)
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` CouchDB listens on `127.0.0.1:5984` inside the container, and refuses anyone who doesn't log in. To ask it for its welcome message as the admin:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 \
  "curl -s -u admin:$TF_VAR_admin_password http://127.0.0.1:5984/"
```

To use Fauxton, CouchDB's web interface, from your browser, forward the port over SSH, open `http://localhost:5984/_utils` and sign in as `admin`:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts -L 5984:127.0.0.1:5984 -N root@127.0.0.1
```

Set a new `TF_VAR_admin_password` and apply again to change the admin's password.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
