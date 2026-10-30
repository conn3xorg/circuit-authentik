# Local example

Applies circuit-authentik to a throwaway Rocky Linux 10 container with systemd, with [circuit-postgres](https://github.com/conn3xorg/circuit-postgres) on the same host. You need Conn3x, Podman, and about 2 GB of memory free for the container.

authentik runs under Podman inside that container, so the host container is privileged, which is simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The first apply takes a few minutes: it installs PostgreSQL and Podman and pulls the image. The second plan says `No changes.` The example's passwords and token are defaults in `main.tf`, which you'd never keep on a real host.

authentik carries on setting itself up for a minute or two after the apply, so give it a moment. Then run the same check CI runs, inside the server container, where Python is:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 \
  podman exec -i -e AK_TOKEN=example-token-not-secret -e AK_PASSWORD=tracing-paper-kite \
  authentik-server python3 - < check.py
```

It logs in with the token and the password, makes an OIDC provider and gets a signed token from it, makes a SAML provider and reads its metadata, and checks that an ordinary user is refused. The last line is `All checks passed.` You can run it as often as you like; it reuses the objects it made.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
